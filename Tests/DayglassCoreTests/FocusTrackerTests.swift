import Foundation
import Testing
@testable import DayglassCore

@Suite struct FocusTrackerTests {
    @Test func closesAFocusSpanWhenAnyWindowFieldChanges() throws {
        var tracker = FocusTracker()
        let first = FocusSnapshot(appBundleID: "com.apple.Terminal", appName: "Terminal", title: "repo-a")
        let second = FocusSnapshot(appBundleID: "com.apple.Terminal", appName: "Terminal", title: "repo-b")
        let start = date("2026-09-14T09:00:00Z")

        #expect(tracker.update(first, at: start).isEmpty)
        let closed = tracker.update(second, at: start.addingTimeInterval(600))

        let span = try #require(closed.first)
        #expect(span.name == "focus")
        #expect(span.start == start)
        #expect(span.end == start.addingTimeInterval(600))
        #expect(span.attributes["window.title"] == "repo-a")
    }

    @Test func closesFocusAtAfkAndDoesNotLoseTheNextWindow() throws {
        var tracker = FocusTracker()
        let snapshot = FocusSnapshot(appBundleID: "com.apple.Terminal", appName: "Terminal", title: "repo")
        let start = date("2026-09-14T09:00:00Z")
        _ = tracker.update(snapshot, at: start)

        let afk = try #require(tracker.afkStarted(at: start.addingTimeInterval(300)).first)
        #expect(afk.start == start)
        #expect(afk.end == start.addingTimeInterval(300))
        #expect(tracker.update(snapshot, at: start.addingTimeInterval(600)).isEmpty)
        let finished = try #require(tracker.close(at: start.addingTimeInterval(900)).first)
        #expect(finished.start == start.addingTimeInterval(600))
        #expect(finished.end == start.addingTimeInterval(900))
    }
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
