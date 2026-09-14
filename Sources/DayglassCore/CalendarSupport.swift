import Foundation

/// The one place a `Calendar` is built.
///
/// Day boundaries in dayglass are always Gregorian; only the time zone varies,
/// so the time zone is the only thing callers may choose. Accepting a whole
/// `Calendar` would let `Calendar.current` through, and on a Mac set to the
/// Japanese calendar that reports Reiwa years — stamping 2026-09-14 as
/// 0008-09-14 and breaking every YYYY-MM match downstream.
public enum DayglassCalendar {
    public static func gregorian(in timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public static var local: Calendar { gregorian() }
}
