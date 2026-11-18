import Foundation
import Observation
import SignalBus

@MainActor
@Observable
final class BusMonitorModel {
    private(set) var messages: [SignalMessage] = []

    func consume(_ bus: SignalBus) async {
        let stream = await bus.subscribe()
        for await message in stream {
            messages.insert(message, at: 0)
            if messages.count > 300 { messages.removeLast(messages.count - 300) }
        }
    }
}
