import Foundation
import Testing
@testable import Core

private func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vera-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ bytes: Int, to relativePath: String, under root: URL) {
    let url = root.appending(path: relativePath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
}

@Test func foldersAreSummedRecursivelyWithFileCounts() {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    write(1_000, to: "Tape/2026-11-18/14.wav", under: root)
    write(500, to: "Tape/2026-11-18/15.wav", under: root)
    write(300, to: "Journal/a.jsonl", under: root)

    let tape = StorageUsage.folder(.tape, under: root)
    #expect(tape.bytes == 1_500 && tape.files == 2)
    let journal = StorageUsage.folder(.journal, under: root)
    #expect(journal.bytes == 300 && journal.files == 1)
}

@Test func missingFolderIsEmptyNotAnError() {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = StorageUsage.folder(.logs, under: root)
    #expect(logs.bytes == 0 && logs.files == 0)
}

@Test func trashIsCountedSeparatelyFromWorkspace() {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    write(100, to: "Workspace/notes.txt", under: root)
    write(40, to: "Workspace/.trash/old.txt", under: root)

    let workspace = StorageUsage.folder(.workspace, under: root)
    #expect(workspace.bytes == 100 && workspace.files == 1)
    let trash = StorageUsage.folder(.workspaceTrash, under: root)
    #expect(trash.bytes == 40 && trash.files == 1)
}

@Test func symlinksAreNotFollowedOrCounted() throws {
    let root = tempRoot()
    let outside = tempRoot()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    write(10_000, to: "big.bin", under: outside)
    write(200, to: "Notes/own.txt", under: root)
    try FileManager.default.createSymbolicLink(at: root.appending(path: "Notes/link.bin"),
                                               withDestinationURL: outside.appending(path: "big.bin"))
    try FileManager.default.createSymbolicLink(at: root.appending(path: "Notes/linked-dir"), withDestinationURL: outside)

    let notes = StorageUsage.folder(.notes, under: root)
    #expect(notes.bytes == 200 && notes.files == 1)
}

@Test func snapshotCoversEveryAreaAndReportsVolume() {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    write(64, to: "Memory/facts.jsonl", under: root)

    let snapshot = StorageUsage.snapshot(root: root)
    #expect(snapshot.folders.count == StorageUsage.Area.allCases.count)
    #expect(snapshot.folder(.memory)?.bytes == 64)
    let free = snapshot.freeBytes, total = snapshot.totalBytes
    #expect(free != nil && total != nil)
    #expect((free ?? 0) <= (total ?? 0) && (total ?? 0) > 0)
}
