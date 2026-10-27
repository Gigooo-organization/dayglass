import Testing
@testable import DayglassCore

@Test func versionIsPresent() {
    #expect(!DayglassCore.version.isEmpty)
}

@Test func buildWithoutGitUsesReleaseVersion() {
    #expect(resolveVersion(release: "0.5.1", gitDescribe: nil) == "0.5.1")
}

@Test func cleanTaggedBuildMatchesTag() {
    #expect(resolveVersion(release: "0.5.1", gitDescribe: "v0.5.1") == "0.5.1")
}

@Test func buildAfterTagShowsCommitsSinceAndDirtyState() {
    #expect(resolveVersion(release: "0.5.1", gitDescribe: "v0.5.1-2-gabc1234-dirty") == "0.5.1-2-gabc1234-dirty")
}

@Test func buildWithoutReachableTagAppendsCommit() {
    #expect(resolveVersion(release: "0.5.1", gitDescribe: "abc1234") == "0.5.1+abc1234")
}
