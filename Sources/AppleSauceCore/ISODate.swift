import Foundation

/// A date from a tool argument. `dateOnly` is true for input like `2026-11-12` (no time).
public struct ParsedDate: Sendable, Equatable {
    public let date: Date
    public let dateOnly: Bool

    public init(date: Date, dateOnly: Bool) {
        self.date = date
        self.dateOnly = dateOnly
    }
}

/// ISO 8601 dates for tool input and output.
/// In: `2026-11-12` (local midnight), `2026-11-12T09:30:00` (local time), or with an offset (`Z`, `+01:00`).
/// Out: always date and time with an offset.
public enum ISODate {
    public static let example = "2026-11-12, 2026-11-12T09:30:00 or 2026-11-12T09:30:00+01:00"

    /// Returns nil when the text is not a valid date. It rejects dates that do not exist (2026-02-30).
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> ParsedDate? {
        // A Regex value is not Sendable, so it is built here and not stored in a static property.
        let pattern =
            #/^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|z|[+-]\d{2}(?::?\d{2})?)?)?$/#
        guard let match = try? pattern.wholeMatch(in: text.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        guard let year = Int(match.1), let month = Int(match.2), let day = Int(match.3) else { return nil }
        let dateOnly = match.4 == nil

        var zone = timeZone
        if let offset = match.7 {
            guard let seconds = offsetSeconds(String(offset)), let fixed = TimeZone(secondsFromGMT: seconds) else {
                return nil
            }
            zone = fixed
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        var parts = DateComponents(year: year, month: month, day: day)
        var checked: Set<Calendar.Component> = [.year, .month, .day]
        if let hourText = match.4, let minuteText = match.5, let hour = Int(hourText), let minute = Int(minuteText) {
            parts.hour = hour
            parts.minute = minute
            parts.second = match.6.flatMap { Int($0) } ?? 0
            checked.formUnion([.hour, .minute, .second])
        }
        guard let date = calendar.date(from: parts) else { return nil }
        // The calendar rolls bad values over (month 13, day 30 of February). Reading them back catches that.
        let back = calendar.dateComponents(checked, from: date)
        for component in checked where back.value(for: component) != parts.value(for: component) { return nil }
        return ParsedDate(date: date, dateOnly: dateOnly)
    }

    private static func offsetSeconds(_ text: String) -> Int? {
        if text.uppercased() == "Z" { return 0 }
        let sign = text.hasPrefix("-") ? -1 : 1
        let digits = text.dropFirst().filter(\.isNumber)
        guard let hours = Int(digits.prefix(2)), hours <= 23 else { return nil }
        let minutes = digits.count > 2 ? Int(digits.dropFirst(2)) ?? 99 : 0
        guard minutes <= 59 else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    /// `2026-11-12T09:30:00+01:00`. Uses `Z` when the zone is UTC.
    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(
                dateSeparator: .dash, dateTimeSeparator: .standard, timeSeparator: .colon,
                timeZoneSeparator: .colon, includingFractionalSeconds: false, timeZone: timeZone))
    }

    public static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    /// The last second of the day. An all-day event ends here.
    public static func endOfDay(_ date: Date) -> Date {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay(date)) ?? date
        return next.addingTimeInterval(-1)
    }

    /// The first moment after the end. A date-only end includes its whole day, so this is the next midnight.
    public static func exclusiveEnd(_ end: ParsedDate) -> Date {
        guard end.dateOnly else { return end.date }
        return Calendar.current.date(byAdding: .day, value: 1, to: end.date) ?? end.date
    }

    /// A range from `start` to `end`. A date-only `end` includes the whole day.
    /// Throws `INVALID_INPUT` when the end is not after the start, or the range is longer than `maxDays`.
    public static func range(
        start: ParsedDate, end: ParsedDate, maxDays: Int? = nil
    ) throws -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let last = exclusiveEnd(end)
        guard last > start.date else {
            throw ToolError(
                .invalidInput, "'end' must be after 'start'.",
                fix: "Use an end that is later than start. A date-only end includes that whole day.")
        }
        if let maxDays, let limit = calendar.date(byAdding: .day, value: maxDays, to: start.date), last > limit {
            throw ToolError(
                .invalidInput, "The range is longer than \(maxDays) days.",
                fix: "Use a shorter range, or make several calls.")
        }
        return (start.date, last)
    }
}

extension Arguments {
    /// An ISO 8601 date argument, or nil when it is missing.
    public func date(_ key: String) throws -> ParsedDate? {
        guard let text = try string(key) else { return nil }
        guard let parsed = ISODate.parse(text) else {
            throw ToolError(
                .invalidInput, "'\(key)' is not a valid date: '\(text)'.",
                fix: "Use ISO 8601, for example \(ISODate.example).")
        }
        return parsed
    }

    public func requiredDate(_ key: String) throws -> ParsedDate {
        guard let parsed = try date(key) else { throw ToolError.invalidInput("'\(key)' is required.") }
        return parsed
    }
}
