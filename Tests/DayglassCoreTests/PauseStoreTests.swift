import Foundation
import Testing
@testable import DayglassCore

@Suite struct PauseStoreTests {
    @Test func storesOnlyAnExpiringPauseWindow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PauseStore(url: url)
        let now = Date(timeIntervalSince1970: 100)

        let window = try store.pause(for: 3_600, from: now)

        #expect(window.until == Date(timeIntervalSince1970: 3_700))
        #expect(try store.current(at: now)?.until == window.until)
        #expect(try store.current(at: Date(timeIntervalSince1970: 3_700)) == nil)
    }

    @Test(arguments: [("15m", 900.0), ("2h", 7_200.0), ("1d", 86_400.0)])
    func parsesSimpleDurations(value: String, seconds: Double) {
        #expect(PauseStore.parseDuration(value) == seconds)
    }
}
