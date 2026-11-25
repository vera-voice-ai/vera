import Foundation
import Network
import Observation
import PhoneWire

/// Vera's door for the iPhone sensor: a WebSocket server on loopback (`127.0.0.1:8765`). The world reaches it only
/// through the owner's tunnel (its host is the owner's setting, `local.json`). A connection must pair (one-time code) or say hello with
/// its token within a few seconds, or it is closed; nothing else is read before that. Runs on the main queue.
@MainActor @Observable
public final class PhoneServer {
    public struct Peer: Equatable, Sendable { public let id: Int; public let device: String }

    @ObservationIgnored public let book: DeviceBook
    @ObservationIgnored public let port: UInt16
    /// Messages from paired phones (never `pair`/`hello`, those are handled here).
    @ObservationIgnored public var onMessage: ((Int, PhoneToVera) -> Void)?
    /// Voice frames from paired phones.
    @ObservationIgnored public var onAudio: ((Int, Data) -> Void)?
    /// A phone joined or left; a new one should get the current conversation.
    @ObservationIgnored public var onPeersChanged: ((_ joined: Int?) -> Void)?

    public private(set) var listening = false
    public private(set) var problem: String?
    public var peers: [Peer] { conns.compactMap { id, c in c.device.map { Peer(id: id, device: $0) } }.sorted { $0.id < $1.id } }

    static let authTimeout: Duration = .seconds(10)
    static let maxConnections = 6
    static let maxFrame = 4 * 1024 * 1024

    private struct Conn { let c: NWConnection; var device: String? }
    private var conns: [Int: Conn] = [:]
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var listener: NWListener?

    public init(book: DeviceBook, port: UInt16 = PhoneWire.port) {
        self.book = book; self.port = port
    }

    public func start() {
        guard listener == nil else { return }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maxFrame
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.accept(c) } }
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.listening = true; self?.problem = nil
                    case .failed(let e): self?.listening = false; self?.problem = "порт \(self?.port ?? 0): \(e.localizedDescription)"
                    case .cancelled: self?.listening = false
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            problem = "порт \(port): \(error.localizedDescription)"
        }
    }

    public func stop() {
        listener?.cancel(); listener = nil
        for id in Array(conns.keys) { close(id) }
    }

    public func send(_ id: Int, _ message: VeraToPhone) {
        guard let c = conns[id] else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "vera", metadata: [meta])
        c.c.send(content: PhoneWire.encode(message), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// To every paired phone.
    public func broadcast(_ message: VeraToPhone) {
        for p in peers { send(p.id, message) }
    }

    public func disconnect(device: String) {
        for (id, c) in conns where c.device == device { close(id) }
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        guard conns.count < Self.maxConnections else { c.cancel(); return }
        let id = nextId; nextId += 1
        conns[id] = Conn(c: c, device: nil)
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.dropped(id)
                default: break
                }
            }
        }
        c.start(queue: .main)
        receive(id)
        Task { [weak self] in
            try? await Task.sleep(for: Self.authTimeout)
            if let self, let conn = self.conns[id], conn.device == nil { self.close(id) }
        }
    }

    private func receive(_ id: Int) {
        guard let c = conns[id]?.c else { return }
        c.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if error != nil { self.close(id); return }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                switch meta?.opcode {
                case .text?: if let data { self.text(id, data) }
                case .binary?: if let data, self.conns[id]?.device != nil { self.onAudio?(id, data) }
                case .close?: self.close(id); return
                default: break
                }
                if self.conns[id] != nil { self.receive(id) }
            }
        }
    }

    private func text(_ id: Int, _ data: Data) {
        guard let message = PhoneWire.decode(PhoneToVera.self, data) else { return }
        let authed = conns[id]?.device != nil
        switch message {
        case .pair(let code, let device):
            guard !authed else { return }
            if let token = book.pair(code: code, device: device) {
                conns[id]?.device = DeviceBook.cleanName(device)
                send(id, .paired(token: token))
                onPeersChanged?(id)
            } else {
                send(id, .refused(reason: "код не подошёл или устарел — возьми новый QR на плитке «iPhone»"))
                closeSoon(id)
            }
        case .hello(let token, _):
            guard !authed else { return }
            if let d = book.check(token: token) {
                conns[id]?.device = d.name
                onPeersChanged?(id)
            } else {
                send(id, .refused(reason: "телефон не сопряжён с этой Верой — отсканируй QR заново"))
                closeSoon(id)
            }
        default:
            if authed { onMessage?(id, message) } else { close(id) }
        }
    }

    private func closeSoon(_ id: Int) {
        Task { [weak self] in try? await Task.sleep(for: .milliseconds(300)); self?.close(id) }
    }

    private func close(_ id: Int) {
        guard let c = conns[id] else { return }
        c.c.cancel()
        dropped(id)
    }

    private func dropped(_ id: Int) {
        guard let c = conns.removeValue(forKey: id) else { return }
        if c.device != nil { onPeersChanged?(nil) }
    }
}
