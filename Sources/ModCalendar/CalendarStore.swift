import AppleSauceCore
import Foundation

struct CalendarInfo: Encodable, Sendable, Equatable, Identified {
    let id: String
    let title: String
    /// local, caldav, exchange, subscription, birthday
    let type: String
    let source: String?
    let writable: Bool
}

struct EventInfo: Encodable, Sendable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
    let notes: String?
    let url: String?
    let calendar: String
    let calendarId: String
    let recurring: Bool
    /// True when the calendar does not allow changes (for example a subscribed calendar).
    let readOnly: Bool
    /// Alerts as minutes before the start, from the earliest alert to the latest. Empty when there are none.
    var alerts: [Int] = []
    /// The repeat rule of a recurring event.
    var `repeat`: RepeatRule?
}

enum RepeatFrequency: String, Encodable, Sendable {
    case daily, weekly, monthly, yearly

    var unit: String {
        switch self {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        }
    }
}

enum Weekday: String, Encodable, Sendable, CaseIterable {
    case mon, tue, wed, thu, fri, sat, sun
}

/// How an event repeats. `end` and `count` are never both set. With neither, the event repeats without end.
struct RepeatRule: Encodable, Sendable, Equatable {
    var frequency: RepeatFrequency
    var interval = 1
    /// The last moment in which an occurrence can start.
    var end: Date?
    var count: Int?
    /// Only for weekly rules.
    var days: [Weekday] = []

    /// A short text, for example `every 2 weeks on mon, wed until 2026-12-31T23:59:59Z`.
    var text: String {
        var text = interval == 1 ? "every \(frequency.unit)" : "every \(interval) \(frequency.unit)s"
        if !days.isEmpty { text += " on " + days.map(\.rawValue).joined(separator: ", ") }
        if let end { text += " until \(ISODate.string(end))" }
        if let count { text += ", \(count) times" }
        return text
    }
}

/// A change of the repeat rule in `update_event`.
enum RepeatChange: Sendable, Equatable {
    case set(RepeatRule)
    /// Make the event not recurring.
    case clear
}

enum EventSpan: String, Sendable {
    /// Only this occurrence of a recurring event.
    case this
    /// This occurrence and all later ones.
    case future
}

struct NewEvent: Sendable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    /// Nil means the default calendar for new events.
    var calendarId: String?
    var location: String?
    var notes: String?
    var url: String?
    /// Minutes before the start.
    var alerts: [Int] = []
    var `repeat`: RepeatRule?
}

/// Changes for `update_event`. A nil field stays as it is. For text fields an empty string clears the value.
struct EventPatch: Sendable, Equatable {
    var title: String?
    var start: Date?
    var end: Date?
    var allDay: Bool?
    var location: String?
    var notes: String?
    var url: String?
    /// Minutes before the start. Replaces all alerts. An empty array removes them.
    var alerts: [Int]?
    var `repeat`: RepeatChange?
    /// Moves the event to this calendar.
    var calendarId: String?
}

/// An event id as the tools show it.
///
/// EventKit gives every occurrence of a recurring event the same `calendarItemIdentifier`.
/// So for a recurring event the tool id is `<identifier>@<start of the occurrence>`
/// (for example `ABC-123@2026-11-12T09:00:00+01:00`). update_event and delete_event then
/// hit the occurrence the model chose and not the whole series by mistake.
/// A plain event has no `@` part. The id is split at the last `@`, and the part after it
/// counts only when it is a valid date with a time.
struct EventRef: Sendable, Equatable {
    let identifier: String
    let occurrence: Date?

    var string: String {
        guard let occurrence else { return identifier }
        return "\(identifier)@\(ISODate.string(occurrence))"
    }

    /// For a change (update or delete) with a bare id of a recurring event.
    static let bareRecurringError = ToolError.invalidInput(
        "This is a recurring event. Use the id with its @occurrence part from list_events or search_events.")

    static func parse(_ text: String) throws -> EventRef {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw ToolError.invalidInput("'id' is required.") }
        if let at = text.lastIndex(of: "@"),
            let parsed = ISODate.parse(String(text[text.index(after: at)...])), !parsed.dateOnly
        {
            let identifier = String(text[..<at])
            guard !identifier.isEmpty else { throw ToolError.invalidInput("'id' is not a valid event id.") }
            return EventRef(identifier: identifier, occurrence: parsed.date)
        }
        return EventRef(identifier: text, occurrence: nil)
    }
}

/// The only way the calendar module reaches the calendar data.
/// The real store uses EventKit. Tests use a fake. No EventKit object leaves a store.
protocol CalendarStore: Sendable {
    func accessState() -> PermissionState
    func requestAccess() async throws -> Bool
    func calendars() async throws -> [CalendarInfo]
    /// Occurrences that overlap the range. An empty `calendarIds` means all calendars.
    func events(start: Date, end: Date, calendarIds: [String]) async throws -> [EventInfo]
    func event(_ ref: EventRef) async throws -> EventInfo?
    func create(_ event: NewEvent) async throws -> EventInfo
    func update(_ ref: EventRef, _ patch: EventPatch, span: EventSpan) async throws -> EventInfo
    func delete(_ ref: EventRef, span: EventSpan) async throws
}
