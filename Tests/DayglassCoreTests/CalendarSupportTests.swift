import Foundation
import Testing
@testable import DayglassCore

@Suite struct CalendarSupportTests {
    @Test func buildsGregorianDaysWhateverTheSystemCalendarIs() {
        let calendar = DayglassCalendar.gregorian(in: .gmt)

        #expect(calendar.identifier == .gregorian)
        #expect(calendar.timeZone == .gmt)
    }

    // Running the code cannot catch a reintroduction: the era only diverges on
    // a machine set to a non-Gregorian system calendar, and CI runners are
    // Gregorian. So this reads the source instead, and keeps calendar
    // construction confined to the one file that gets it right.
    @Test func noSourceFileBuildsItsOwnCalendar() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let banned = ["Calendar.current", "Calendar.autoupdatingCurrent", "Calendar(identifier:"]

        var offenders: [String] = []
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            guard url.lastPathComponent != "CalendarSupport.swift" else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, line) in lines.enumerated() where banned.contains(where: line.contains) {
                offenders.append("\(url.lastPathComponent):\(offset + 1)")
            }
        }

        #expect(offenders.isEmpty, "build calendars through DayglassCalendar instead: \(offenders)")
    }
}
