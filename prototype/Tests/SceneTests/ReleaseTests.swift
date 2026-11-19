import Testing
@testable import SignalBus

@Suite struct ReleaseTests {
    @Test func versionIsSemantic() {
        let parts = VeraRelease.version.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
        #expect(VeraRelease.build >= 1)
    }
}
