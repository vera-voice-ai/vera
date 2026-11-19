import Foundation
import Darwin
import Testing
@testable import Core

private func sandboxTempDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vera-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Runs a shell command under the sandbox profile for `workspace` (with the given fake home and scratch folders).
private func sandboxed(_ command: String, workspace: URL, home: URL, scratch: URL) -> ShellResult {
    let profile = SandboxProfile.make(workspace: workspace, home: home, scratch: scratch)
    return ShellRunner.exec("/usr/bin/sandbox-exec", ["-p", profile, "/bin/zsh", "-c", command], in: workspace)
}

@Test func sandboxWritesInsideTheWorkspaceOnly() throws {
    let root = try sandboxTempDirectory("sandbox-write"); defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appending(path: "ws", directoryHint: .isDirectory)
    let outside = root.appending(path: "outside.txt")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let scratch = root.appending(path: "vera-sandbox", directoryHint: .isDirectory)
    let home = root.appending(path: "home", directoryHint: .isDirectory)

    let inside = sandboxed("echo hello > inside.txt && echo WROTE", workspace: workspace, home: home, scratch: scratch)
    #expect(inside.code == 0 && inside.output.contains("WROTE"))
    #expect(FileManager.default.fileExists(atPath: workspace.appending(path: "inside.txt").path))

    let escape = sandboxed("echo x > '\(outside.path)'", workspace: workspace, home: home, scratch: scratch)
    #expect(escape.code != 0)
    #expect(!FileManager.default.fileExists(atPath: outside.path))
}

@Test func sandboxReadsFilesOutsideTheWorkspaceButNotSecretFolders() throws {
    let root = try sandboxTempDirectory("sandbox-read"); defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appending(path: "ws", directoryHint: .isDirectory)
    let scratch = root.appending(path: "vera-sandbox", directoryHint: .isDirectory)
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    // An ordinary file outside the workspace stays readable.
    let ordinary = root.appending(path: "notes.txt")
    try "обычный текст".write(to: ordinary, atomically: true, encoding: .utf8)
    let read = sandboxed("cat '\(ordinary.path)'", workspace: workspace, home: home, scratch: scratch)
    #expect(read.code == 0 && read.output.contains("обычный текст"))

    // A fake ~/.ssh inside the fake home is denied.
    let ssh = home.appending(path: ".ssh", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
    try "PRIVATE-KEY-MARKER".write(to: ssh.appending(path: "id_test"), atomically: true, encoding: .utf8)
    let denied = sandboxed("cat '\(ssh.path)/id_test'", workspace: workspace, home: home, scratch: scratch)
    #expect(denied.code != 0 && !denied.output.contains("PRIVATE-KEY-MARKER"))

    // Denied single files, such as ~/.netrc.
    try "machine x login y password PASS-MARKER".write(to: home.appending(path: ".netrc"), atomically: true, encoding: .utf8)
    let netrc = sandboxed("cat '\(home.path)/.netrc'", workspace: workspace, home: home, scratch: scratch)
    #expect(netrc.code != 0 && !netrc.output.contains("PASS-MARKER"))

    // The Vera data folder is denied, except the workspace when the workspace is inside it.
    let appSupport = home.appending(path: "Library/Application Support/VeraSensorPrototype", directoryHint: .isDirectory)
    let inWorkspace = appSupport.appending(path: "Workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inWorkspace, withIntermediateDirectories: true)
    try "TAPE-MARKER".write(to: appSupport.appending(path: "speaker-references.json"), atomically: true, encoding: .utf8)
    try "WORKSPACE-MARKER".write(to: inWorkspace.appending(path: "mine.txt"), atomically: true, encoding: .utf8)
    let data = sandboxed("cat '\(appSupport.path)/speaker-references.json'", workspace: inWorkspace, home: home, scratch: scratch)
    #expect(data.code != 0 && !data.output.contains("TAPE-MARKER"))
    let mine = sandboxed("cat mine.txt", workspace: inWorkspace, home: home, scratch: scratch)
    #expect(mine.code == 0 && mine.output.contains("WORKSPACE-MARKER"))
}

@Test func sandboxBlocksNetworkAccess() throws {
    // A loopback listener opened by the test: no traffic leaves the machine.
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }
    #expect(bound == 0 && listen(fd, 1) == 0)
    var named = sockaddr_in()
    var namedSize = size
    _ = withUnsafeMutablePointer(to: &named) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &namedSize) }
    }
    let port = UInt16(bigEndian: named.sin_port)

    let directory = try sandboxTempDirectory("sandbox-net"); defer { try? FileManager.default.removeItem(at: directory) }
    // Control: without the sandbox the connection succeeds, so the failure below is the sandbox's doing.
    #expect(ShellRunner.run("/usr/bin/nc -z -w 1 127.0.0.1 \(port)", in: directory).code == 0)
    let blocked = ShellRunner.run("/usr/bin/nc -z -w 1 127.0.0.1 \(port)", in: directory, sandboxed: true)
    #expect(blocked.code != 0)
}

@Test func sandboxedSafeCommandsStillWork() throws {
    let root = try sandboxTempDirectory("sandbox-safe"); defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appending(path: "ws", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try "содержимое файла".write(to: workspace.appending(path: "doc.txt"), atomically: true, encoding: .utf8)

    let listing = ShellRunner.run("ls", in: workspace, sandboxed: true)
    #expect(listing.code == 0 && listing.output.contains("doc.txt"))
    let cat = ShellRunner.run("cat doc.txt", in: workspace, sandboxed: true)
    #expect(cat.code == 0 && cat.output.contains("содержимое файла"))
}

@Test func sandboxFailsClosedWhenSandboxExecIsMissing() throws {
    let directory = try sandboxTempDirectory("sandbox-missing"); defer { try? FileManager.default.removeItem(at: directory) }
    let result = ShellRunner.run("echo ran > marker.txt", in: directory, sandboxed: true,
                                 sandboxExecutable: directory.appending(path: "no-such-sandbox-exec").path)
    #expect(result.code != 0)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "marker.txt").path))
}

@Test func profilePathsAreEscaped() throws {
    let root = try sandboxTempDirectory("sandbox-escape"); defer { try? FileManager.default.removeItem(at: root) }
    // A folder name with a quote and a backslash must not break the profile text.
    let workspace = root.appending(path: "ws \"q\" \\b", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let profile = SandboxProfile.make(workspace: workspace, home: root, scratch: root.appending(path: "scratch"))
    #expect(profile.contains(#"ws \"q\" \\b"#))
    #expect(profile.hasPrefix("(version 1)\n(deny default)"))
    #expect(profile.contains("(deny network*)"))

    let result = ShellRunner.run("echo ok > made.txt", in: workspace, sandboxed: true)
    #expect(result.code == 0 && FileManager.default.fileExists(atPath: workspace.appending(path: "made.txt").path))
}
