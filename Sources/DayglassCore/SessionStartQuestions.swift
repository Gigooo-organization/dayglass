import Foundation

/// Counts unanswered `report --questions` rows in a short trailing window and
/// formats the one-line SessionStart payload.
///
/// SessionStart has to finish before the agent reads `additionalContext`, so
/// callers keep the synchronous evaluation inside `defaultDays` instead of a
/// whole month. Codex receives the same stdout bytes as Claude; whether Codex
/// honors `additionalContext` is up to that client.
public enum SessionStartQuestions {
    public static let defaultDays = 7

    /// Inclusive local days ending on `now`, oldest first. `yyyy-MM-dd` matches
    /// the daily observation folders.
    public static func dayFolderNames(days: Int, endingAt now: Date, calendar: Calendar) -> [String] {
        let count = max(days, 0)
        let endDay = calendar.startOfDay(for: now)
        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -(count - 1 - offset), to: endDay) else { return nil }
            return dayFolderName(day, calendar: calendar)
        }
    }

    /// Questions whose start falls on one of the trailing `days` local days,
    /// including the day of `now`.
    public static func filter(
        _ questions: [ReportQuestion],
        days: Int,
        endingAt now: Date,
        calendar: Calendar
    ) -> [ReportQuestion] {
        let allowed = Set(dayFolderNames(days: days, endingAt: now, calendar: calendar))
        return questions.filter { allowed.contains(dayFolderName($0.start, calendar: calendar)) }
    }

    /// Nil when there is nothing to tell the session. One calendar day uses the
    /// date itself; several days name the first and last.
    public static func additionalContext(for questions: [ReportQuestion], calendar: Calendar) -> String? {
        guard !questions.isEmpty else { return nil }
        let days = questions.map { dayFolderName($0.start, calendar: calendar) }.sorted()
        guard let first = days.first, let last = days.last else { return nil }
        let when = first == last ? first : "\(first) から \(last)"
        let count = questions.count
        let minutes = minutes(from: questions.reduce(0) { $0 + $1.seconds })
        return "dayglass: \(when) に未確定の時間帯が \(count) 件（\(minutes) 分）あります。「dayglass」と言えば確認できます"
    }

    /// One JSON line Claude's SessionStart hook reads, or nil when `questions`
    /// in the trailing window is empty. Nothing else is printed in that case.
    public static func stdout(
        questions: [ReportQuestion],
        now: Date,
        days: Int = defaultDays,
        calendar: Calendar
    ) -> String? {
        let included = filter(questions, days: days, endingAt: now, calendar: calendar)
        guard let context = additionalContext(for: included, calendar: calendar) else { return nil }
        return #"{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":\#(jsonString(context))}}"#
    }

    private static func dayFolderName(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func minutes(from seconds: Int) -> Int {
        let rounded = Int((Double(seconds) / 60.0).rounded())
        if seconds > 0 && rounded == 0 { return 1 }
        return rounded
    }

    private static func jsonString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        escaped += "\""
        return escaped
    }
}
