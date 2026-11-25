import AppKit
import CoreImage.CIFilterBuiltins
import HermesBridge
import PhoneGate
import PhoneWire
import SwiftUI

/// The iPhone channel in «Разговоры» (ours — dashed, pink): its own pinned Hermes session; the phone app talks to Vera's
/// phone door (127.0.0.1:8765, from outside through the owner's tunnel, `phone_tunnel` in local.json). Shows who is connected, the last
/// replies of that session and whether the door is open; «QR» pairs a phone.
struct PhoneChannelCard: View {
    let phone: PhoneModel
    @State private var pairing = false
    static let shownLines = 4

    var body: some View {
        let peers = phone.server.peers
        let running = phone.chat.transcript.running
        let state: (String, Color) = {
            if !phone.server.listening { return ("дверь закрыта", Theme.warn) }
            if running { return ("думает", Theme.llm) }
            if phone.transcribing { return ("слушаю голосовое", Theme.human) }
            if let p = peers.first { return ("на связи · \(p.device)\(peers.count > 1 ? " +\(peers.count - 1)" : "")", Theme.ok) }
            return (phone.server.book.devices.isEmpty ? "не сопряжён" : "телефон не на связи", .white.opacity(0.55))
        }()
        let lines = TelegramChannelCard.lines(phone.chat.transcript).suffix(Self.shownLines)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ChannelHeader(icon: "iphone", title: "iPhone", tag: "сессия Hermes · через адаптер", color: Theme.vera,
                              state: state.0, stateColor: state.1)
                Button { phone.newCode(); pairing = true } label: {
                    Text("QR").font(.mono(8.5, .semibold)).foregroundStyle(Theme.vera)
                        .padding(.horizontal, 7).padding(.vertical, 2).overlay(Capsule().stroke(Theme.vera.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Сопрячь телефон: открой Веру на iPhone и наведи камеру на код")
                .sheet(isPresented: $pairing) { PhonePairing(phone: phone, done: { pairing = false }) }
            }
            if lines.isEmpty {
                Text(phone.server.book.devices.isEmpty ? "сопряги телефон кнопкой QR — его разговор будет здесь"
                     : "переписки с телефона ещё нет").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(l.who == "бот" ? "Hermes" : l.who).font(.mono(9, .semibold)).foregroundStyle(l.color).frame(width: 44, alignment: .leading)
                    Text(l.text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(footer).font(.mono(8)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.vera.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: Theme.ourDash)))
    }

    private var footer: String {
        let tunnel = phone.tunnelURL?.host() ?? "туннель не задан"
        var parts = [phone.server.listening ? "\(tunnel) → :\(PhoneWire.port)" : (phone.server.problem ?? "дверь не открыта")]
        parts.append("сопряжено \(phone.server.book.devices.count)")
        if let last = phone.lastFromPhone {
            parts.append("\(last.voice ? "голосом" : "текстом") \(Format.ago(last.at.timeIntervalSince1970, now: Date()))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Pairing a phone: the QR with the address and a one-time code (five minutes), the code in letters for typing,
/// and the phones paired so far, each one can be forgotten (its token stops working).
struct PhonePairing: View {
    let phone: PhoneModel
    var done: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let code = phone.code
            VStack(alignment: .leading, spacing: 12) {
                Text("Сопряжение iPhone").font(.system(size: 14, weight: .semibold))
                Text("В приложении Вера на телефоне нажми «Сопрячь» и наведи камеру на код. Код одноразовый и живёт 5 минут.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    if let code, let url = phone.tunnelURL, let img = Self.qr(PhoneWire.pairingLink(url: url, code: code).absoluteString) {
                        Image(nsImage: img).interpolation(.none).resizable().frame(width: 200, height: 200)
                            .background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)).frame(width: 200, height: 200)
                            .overlay(Text(phone.tunnelURL == nil ? "нет адреса туннеля:\nphone_tunnel в local.json" : "код истёк")
                                .font(.mono(10)).foregroundStyle(.secondary).multilineTextAlignment(.center))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if let code {
                            Text(code).font(.system(size: 22, weight: .semibold, design: .monospaced)).tracking(3).textSelection(.enabled)
                            if let until = phone.server.book.code?.until {
                                Text("ещё \(max(0, Int(until.timeIntervalSince(ctx.date))) / 60):" + String(format: "%02d", max(0, Int(until.timeIntervalSince(ctx.date))) % 60))
                                    .font(.mono(10)).foregroundStyle(.secondary)
                            }
                        }
                        Button("Новый код") { phone.newCode() }
                        Text(phone.tunnelURL?.absoluteString ?? "адрес туннеля не задан").font(.mono(9)).foregroundStyle(.secondary)
                    }
                }
                if !phone.server.book.devices.isEmpty {
                    Divider()
                    Text("Сопряжённые телефоны").font(.system(size: 12, weight: .semibold))
                    ForEach(phone.server.book.devices, id: \.name) { d in
                        HStack {
                            Circle().fill(phone.server.peers.contains { $0.device == d.name } ? Theme.ok : .white.opacity(0.3)).frame(width: 6, height: 6)
                            Text(d.name).font(.system(size: 12))
                            Text(d.lastSeen.map { "был " + Format.ago($0.timeIntervalSince1970, now: ctx.date) } ?? "").font(.mono(9)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Забыть") { phone.forget(d.name) }
                        }
                    }
                }
                HStack { Spacer(); Button("Готово") { done() }.keyboardShortcut(.defaultAction) }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
