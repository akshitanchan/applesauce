import AppleSauceCore
import Foundation
import MCP

/// Input checks for the `alerts` and `repeat` arguments of `create_event` and `update_event`.
extension Arguments {
    static let maxAlerts = 5
    static let alertMinutes = 0...40320

    /// Minutes before the start. Nil when the argument is missing. An empty array is valid (update removes all alerts).
    /// Repeated values are kept once.
    func alerts() throws -> [Int]? {
        guard let value = raw["alerts"], !value.isNull else { return nil }
        guard let items = value.arrayValue else {
            throw ToolError.invalidInput("'alerts' must be an array of whole numbers (minutes before the start).")
        }
        guard items.count <= Self.maxAlerts else {
            throw ToolError.invalidInput("'alerts' can have at most \(Self.maxAlerts) values.")
        }
        var minutes: [Int] = []
        for item in items {
            let number: Int
            if let whole = item.intValue {
                number = whole
            } else if let decimal = item.doubleValue, decimal.rounded() == decimal, abs(decimal) < 1e9 {
                number = Int(decimal)
            } else {
                throw ToolError.invalidInput("'alerts' must be an array of whole numbers (minutes before the start).")
            }
            guard Self.alertMinutes.contains(number) else {
                throw ToolError(
                    .invalidInput,
                    "Each value in 'alerts' must be between \(Self.alertMinutes.lowerBound) and \(Self.alertMinutes.upperBound) minutes.",
                    fix: "40320 minutes are 4 weeks. Use 0 for an alert at the start.")
            }
            if !minutes.contains(number) { minutes.append(number) }
        }
        return minutes.sorted(by: >)
    }

    /// The `repeat` object. Nil when the argument is missing. `null` or the frequency `none` mean `.clear`.
    func repeatChange() throws -> RepeatChange? {
        guard let value = raw["repeat"] else { return nil }
        if value.isNull { return .clear }
        guard let object = value.objectValue else {
            throw ToolError(
                .invalidInput, "'repeat' must be an object.",
                fix: "Use for example {\"frequency\": \"weekly\", \"interval\": 2, \"days\": [\"mon\"], \"count\": 10}."
            )
        }
        let inner = Arguments(object)
        let name = try inner.requiredString("frequency").lowercased()
        if name == "none" { return .clear }
        guard let frequency = RepeatFrequency(rawValue: name) else {
            throw ToolError.invalidInput(
                "'repeat.frequency' must be 'daily', 'weekly', 'monthly', 'yearly' or 'none'.")
        }
        var rule = RepeatRule(frequency: frequency)
        rule.interval = try inner.int("interval", default: 1, range: 1...99)

        let end = try inner.date("end")
        let count = try inner.int("count")
        if end != nil && count != nil {
            throw ToolError(
                .invalidInput, "'repeat' can have 'end' or 'count', not both.",
                fix: "Remove one of them. Without both, the event repeats without end.")
        }
        if let end { rule.end = end.dateOnly ? ISODate.endOfDay(end.date) : end.date }
        if let count {
            guard (1...999).contains(count) else {
                throw ToolError.invalidInput("'repeat.count' must be between 1 and 999.")
            }
            rule.count = count
        }

        if let names = try inner.stringArray("days") {
            guard frequency == .weekly else {
                throw ToolError.invalidInput("'repeat.days' is only for the frequency 'weekly'.")
            }
            let days = try names.map { text -> Weekday in
                guard let day = Weekday(rawValue: text.lowercased()) else {
                    throw ToolError.invalidInput("'repeat.days' must use mon, tue, wed, thu, fri, sat or sun.")
                }
                return day
            }
            rule.days = Weekday.allCases.filter { days.contains($0) }
        }
        return .set(rule)
    }
}

extension RepeatRule {
    /// The end of the rule must be after the start of the first occurrence.
    func checkEnd(after start: Date) throws {
        if let end, end <= start {
            throw ToolError(
                .invalidInput, "'repeat.end' must be after the start of the event.",
                fix: "Use a later end date, or use 'count'.")
        }
    }
}
