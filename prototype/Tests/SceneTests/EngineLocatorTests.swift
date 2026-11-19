import Foundation
import Testing
@testable import Core

@Suite struct EngineLocatorTests {
    @Test func veraCopyIsPreferredOverTheSystemPath() throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        let system = fake.base.appending(path: "system-bin", directoryHint: .isDirectory)
        fake.install("codex", in: system)
        let copy = fake.install("codex")

        let location = EngineLocator(root: fake.root, searchDirectories: [system]).locate(.codex)
        #expect(location?.source == .veraCopy)
        #expect(location?.executable.path == copy.path)
    }

    @Test func fallsBackToTheSystemPathWhenVeraHasNoCopy() throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        let system = fake.base.appending(path: "system-bin", directoryHint: .isDirectory)
        let installed = fake.install("claude", in: system)

        let location = EngineLocator(root: fake.root, searchDirectories: [system]).locate(.claude)
        #expect(location?.source == .systemPath)
        #expect(location?.executable.path == installed.path)
    }

    @Test func reportsNothingWhenNeitherCopyNorSystemCopyExists() throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        #expect(EngineLocator(root: fake.root, searchDirectories: []).locate(.codex) == nil)
        #expect(EngineLocator(root: fake.root, searchDirectories: []).locate(.claude) == nil)
    }

    @Test func aFileThatIsNotExecutableIsNotAnEngine() throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        let copy = fake.install("codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        #expect(EngineLocator(root: fake.root, searchDirectories: []).locate(.codex) == nil)
    }

    @Test func configHomesAreSeparatePerCLIAndCreatedOwnerOnly() throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        let locator = fake.locator
        try locator.prepareHomes()

        #expect(locator.configHome(.codex).path == fake.root.path + "/agents/home/codex")
        #expect(locator.configHome(.claude).path == fake.root.path + "/agents/home/claude")
        for kind in EngineKind.allCases {
            let attributes = try FileManager.default.attributesOfItem(atPath: locator.configHome(kind).path)
            #expect(attributes[.posixPermissions] as? Int == 0o700)
        }
    }

    @Test func childEnvironmentIsMinimalAndPointsAtVeraOwnConfig() throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        let locator = fake.locator
        let location = EngineLocation(executable: locator.veraCopy(.codex), source: .veraCopy)

        let codex = locator.environment(for: location, kind: .codex)
        #expect(Set(codex.keys) == ["PATH", "HOME", "LANG", "TERM", "CODEX_HOME"])
        #expect(codex["CODEX_HOME"] == locator.configHome(.codex).path)
        #expect(codex["PATH"]?.hasPrefix(fake.bin.path) == true)

        let claude = locator.environment(for: location, kind: .claude)
        #expect(Set(claude.keys) == ["PATH", "HOME", "LANG", "TERM", "CLAUDE_CONFIG_DIR"])
        #expect(claude["CLAUDE_CONFIG_DIR"] == locator.configHome(.claude).path)
    }
}
