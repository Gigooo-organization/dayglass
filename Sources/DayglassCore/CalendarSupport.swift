import Foundation

public enum DayglassCalendar {
    public static var local: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}
