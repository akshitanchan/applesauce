import Foundation

/// The date windows that `delete_calendar` searches for events.
///
/// EventKit answers a date predicate for about 4 years at most, so the span is cut into chunks of 1400 days
/// (a little under 4 years). The code counts days, not calendar years, so the windows do not depend on the time zone.
enum CalendarEmptiness {
    /// Years searched back and ahead of the check time.
    static let years = 10
    static let chunkDays = 1400
    private static let day: TimeInterval = 86_400

    /// The whole span: from `years` years (365.25 days each) before `now` to the same time after it.
    static func span(now: Date) -> (start: Date, end: Date) {
        let half = Double(years) * 365.25 * day
        return (now.addingTimeInterval(-half), now.addingTimeInterval(half))
    }

    /// Consecutive windows that cover the span with no gap. None is longer than `chunkDays`.
    static func windows(now: Date) -> [(start: Date, end: Date)] {
        let whole = span(now: now)
        var result: [(start: Date, end: Date)] = []
        var start = whole.start
        while start < whole.end {
            let end = min(start.addingTimeInterval(Double(chunkDays) * day), whole.end)
            result.append((start, end))
            start = end
        }
        return result
    }
}
