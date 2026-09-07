import Testing
@testable import DayglassCore

@Test func versionIsPresent() {
    #expect(!DayglassCore.version.isEmpty)
}
