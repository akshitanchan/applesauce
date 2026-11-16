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
