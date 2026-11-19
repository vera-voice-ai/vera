import Foundation

/// A first-in, first-out gate with a fixed number of places. A waiter that is cancelled leaves the line and takes no place.
actor Lane {
    private let capacity: Int
    private var used = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(capacity: Int) { self.capacity = capacity }

    /// Takes a place, waiting in line when all are taken. Returns false when the wait was cancelled: no place was taken.
    func acquire() async -> Bool {
        if Swift.Task.isCancelled { return false }
        if used < capacity { used += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Swift.Task.isCancelled { continuation.resume(returning: false); return }
                waiting.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Swift.Task { await self.cancelWaiter(id) }
        }
    }

    /// Gives a place back: the first in line takes it over, or it becomes free.
    func release() {
        if waiting.isEmpty {
            used -= 1
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}
