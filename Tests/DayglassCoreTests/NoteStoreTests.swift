import Foundation
import Testing
@testable import DayglassCore

@Suite struct NoteStoreTests {
    @Test func appendsAndReloadsTimeNotesAndDailySummaries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(root: root)
        let start = date("2026-09-14T09:00:00Z")

        try store.append(
            NoteRecord(start: start, end: start.addingTimeInterval(900), project: "PJ-A", category: "meeting"),
            month: "2026-09"
        )
        try store.append(NoteRecord(summary: "Confirmed work"), month: "2026-09")

        let notes = try store.load(month: "2026-09")
        #expect(notes.count == 2)
        #expect(notes[0].project == "PJ-A")
        #expect(notes[1].summary == "Confirmed work")
    }
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
