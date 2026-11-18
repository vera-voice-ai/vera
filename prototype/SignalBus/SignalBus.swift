import Foundation

public actor SignalBus {
    private var subscribers: [UUID: AsyncStream<SignalMessage>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<SignalMessage> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2_000)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    public func publish(_ message: SignalMessage) {
        for continuation in subscribers.values {
            continuation.yield(message)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
