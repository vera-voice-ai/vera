import Testing
@testable import SignalBus
import Core

@Suite struct ReleaseTests {
    @Test func versionIsSemantic() {
        let parts = VeraRelease.version.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
        #expect(VeraRelease.build >= 1)
    }
}

@Test func theChangelogInHerContextIsInStepWithTheReleaseAndStaysShort() {
    // The newest entry is the version being built or the one just after it (a release in progress), never an old one.
    let newest = VeraChangelog.entries[0].version
    let released = VeraRelease.version.split(separator: ".").compactMap { Int($0) }
    let listed = newest.split(separator: ".").compactMap { Int($0) }
    #expect(listed.count == 3 && released.count == 3 && listed[0] == released[0] && listed[1] == released[1] && listed[2] >= released[2],
            "add the new release to VeraChangelog.entries")
    #expect(VeraChangelog.contextText().count < 1_800)
    #expect(Set(VeraChangelog.entries.map(\.version)).count == VeraChangelog.entries.count)
}
