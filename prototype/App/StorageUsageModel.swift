import Foundation
import Observation
import Core

/// Keeps the Storage panel's sizes current. The scan runs on a background task, never on the main actor.
@MainActor
@Observable
final class StorageUsageModel {
    private(set) var snapshot: StorageUsage.Snapshot?
    private let root: URL
    private var loop: Task<Void, Never>?

    init(root: URL) {
        self.root = root
    }

    /// Scans now and then every 60 seconds.
    func start() {
        guard loop == nil else { return }
        let root = root
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let next = await Task.detached(priority: .utility) { StorageUsage.snapshot(root: root) }.value
                self?.snapshot = next
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// "1,5 ГБ · 1 204 файла" for one panel line; nil until the first scan finishes.
    func sizeText(_ area: StorageUsage.Area) -> String? {
        guard let folder = snapshot?.folder(area) else { return nil }
        return "\(Self.bytesText(folder.bytes)) · \(folder.files) \(Self.filesWord(folder.files))"
    }

    static func bytesText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "ru_RU")))
    }

    static func filesWord(_ count: Int) -> String {
        let last = count % 10, tens = count % 100
        if last == 1 && tens != 11 { return "файл" }
        if (2...4).contains(last) && !(12...14).contains(tens) { return "файла" }
        return "файлов"
    }
}
