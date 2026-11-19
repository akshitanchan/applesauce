import AppleSauceCore
import Foundation
import MCP

/// Calendar tools. The data comes from a `CalendarStore` (EventKit in the real binary).
public struct CalendarModule: Module {
    public static let moduleName = "calendar"
    public var name: String { Self.moduleName }
    public static let requiredPermissions: [Permission] = [.calendars]
    public var permissions: [Permission] { Self.requiredPermissions }

    let store: any CalendarStore
    let permissionTimeout: Double
    let backendTimeout: Double

    /// The real module, backed by EventKit.
    #if os(macOS)
    public init() {
        self.init(store: EventKitCalendarStore())
    }
    #endif

    init(store: any CalendarStore, permissionTimeout: Double = 120, backendTimeout: Double = 30) {
        self.store = store
        self.permissionTimeout = permissionTimeout
        self.backendTimeout = backendTimeout
    }

    // MARK: tools

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static let dateNote = "ISO 8601, for example 2026-11-12 or 2026-11-12T09:30:00+01:00"
    private static let idNote =
        "Event id from list_events, search_events or get_event. Recurring events have an id with an @ part. Use it as given."
    private static let limitProperty = property("integer", "Most results to return. Default 50, maximum 500.")
    private static let spanProperty: Value = [
        "type": "string", "enum": ["this", "future"],
        "description":
            "For a recurring event: 'this' changes only this occurrence (default), 'future' changes this and all later ones.",
    ]

    private static let alertsNote =
        "Minutes before the start, 0 to 40320, at most 5. For example [10, 1440] is an alert 10 minutes before and one day before."
    private static let repeatProperty: Value = [
        "type": "object",
        "description":
            "How the event repeats. Set 'frequency'. 'interval' (1 to 99, default 1) is the gap between repeats. Give 'end' (a date, the last day a repeat can start) or 'count' (1 to 999 occurrences), not both. Without them the event repeats forever. 'days' is only for 'weekly'. Frequency 'none' or null removes the rule.",
        "properties": [
            "frequency": [
                "type": "string", "enum": ["daily", "weekly", "monthly", "yearly", "none"],
                "description": "How often the event repeats.",
            ],
            "interval": property("integer", "Every n days, weeks, months or years. 1 to 99. Default 1."),
            "end": property("string", "Last day a repeat can start. \(dateNote)"),
            "count": property("integer", "Number of occurrences in total, 1 to 999."),
            "days": [
                "type": "array",
                "items": ["type": "string", "enum": Value.array(Weekday.allCases.map { .string($0.rawValue) })],
                "description": "Weekdays for a weekly rule, for example [\"mon\", \"wed\"].",
            ],
        ],
        "required": ["frequency"],
    ]

    public var tools: [ToolSpec] { Self.toolSpecs }

    public static var toolSpecs: [ToolSpec] {
        let calendar = Self.property("string", "Calendar name or id. Names ignore case.")
        return [
            ToolSpec(
                name: "list_calendars",
                description: "List all calendars with their id, type, source and whether they allow changes."),
            ToolSpec(
                name: "list_events",
                description:
                    "List events between 'start' and 'end', sorted by start time, from one calendar or all. Dates are \(Self.dateNote). A date-only 'end' includes that whole day. The range is at most 366 days.",
                properties: [
                    "start": Self.property("string", "Start of the range. \(Self.dateNote)"),
                    "end": Self.property("string", "End of the range. \(Self.dateNote)"),
                    "calendar": calendar,
                    "limit": Self.limitProperty,
                ],
                required: ["start", "end"]),
            ToolSpec(
                name: "search_events",
                description:
                    "Find events whose title, location or notes contain the query (ignores case). Without 'start' and 'end' it looks 30 days back and 30 days ahead. Dates are \(Self.dateNote). The range is at most 366 days.",
                properties: [
                    "query": Self.property("string", "Text to look for."),
                    "start": Self.property("string", "Start of the range. Give both 'start' and 'end', or neither."),
                    "end": Self.property("string", "End of the range. A date-only end includes that whole day."),
                    "limit": Self.limitProperty,
                ],
                required: ["query"]),
            ToolSpec(
                name: "get_event",
                description: "Get one event with all its details. Dates are returned in ISO 8601 with an offset.",
                properties: ["id": Self.property("string", Self.idNote)],
                required: ["id"]),
            ToolSpec(
                name: "create_event",
                description:
                    "Create an event. Dates are \(Self.dateNote). With date-only 'start' and 'end', or 'all_day' true, it is an all-day event and 'end' is the last day. 'alerts' and 'repeat' are optional.",
                properties: [
                    "title": Self.property("string", "Event title."),
                    "start": Self.property("string", "Start. \(Self.dateNote)"),
                    "end": Self.property("string", "End, after 'start'. \(Self.dateNote)"),
                    "calendar": Self.property("string", "Calendar name or id. Default: the default calendar."),
                    "location": Self.property("string", "Location."),
                    "notes": Self.property("string", "Notes."),
                    "all_day": Self.property("boolean", "All-day event."),
                    "url": Self.property("string", "A URL, for example https://example.com."),
                    "alerts": [
                        "type": "array", "items": ["type": "integer"], "description": .string(Self.alertsNote),
                    ],
                    "repeat": Self.repeatProperty,
                ],
                required: ["title", "start", "end"], write: true),
            ToolSpec(
                name: "update_event",
                description:
                    "Change fields of an event. Send only the fields to change. An empty string clears 'location', 'notes' or 'url'. Dates are \(Self.dateNote). 'alerts' replaces all alerts, and [] removes them. 'calendar' moves the event to another calendar. Calendar may refuse to move an event to a calendar of another account. For a recurring event, 'span' 'future' changes this and all later occurrences, and it needs 'confirm' true. Changing 'repeat' needs 'span' 'future' (null or frequency 'none' removes the rule). Moving a recurring event to another calendar also needs 'span' 'future'.",
                properties: [
                    "id": Self.property("string", Self.idNote),
                    "title": Self.property("string", "New title."),
                    "start": Self.property("string", "New start. \(Self.dateNote)"),
                    "end": Self.property("string", "New end, after 'start'. \(Self.dateNote)"),
                    "location": Self.property("string", "New location. Empty string clears it."),
                    "notes": Self.property("string", "New notes. Empty string clears them."),
                    "all_day": Self.property("boolean", "Make the event all-day or not."),
                    "url": Self.property("string", "New URL. Empty string clears it."),
                    "calendar": Self.property(
                        "string", "Move the event to this calendar (name or id). Names ignore case."),
                    "alerts": [
                        "type": "array", "items": ["type": "integer"],
                        "description": .string(
                            "New alerts, replacing all old ones. [] removes all. \(Self.alertsNote)"),
                    ],
                    "repeat": Self.repeatProperty,
                    "span": Self.spanProperty,
                    "confirm": Self.property(
                        "boolean",
                        "Must be true to change a recurring event with 'span' 'future'. It changes all later occurrences."
                    ),
                ],
                required: ["id"], write: true, idempotent: true),
            ToolSpec(
                name: "delete_event",
                description:
                    "Delete an event. For a recurring event, 'span' chooses one occurrence or all later ones. The result has a copy of the event, so create_event can put it back. Deleting all later occurrences needs 'confirm' true.",
                properties: [
                    "id": Self.property("string", Self.idNote), "span": Self.spanProperty,
                    "confirm": Self.property(
                        "boolean",
                        "Must be true to delete a recurring event with 'span' 'future'. It cannot be undone."),
                ],
                required: ["id"], destructive: true, idempotent: true),
            ToolSpec(
                name: "delete_calendar",
                description:
                    "Delete an empty calendar. It is refused when the calendar has any event from 10 years back to 10 years ahead, when it is read-only, subscribed or a birthday calendar, and for the default calendar for new events. Events outside that range are not checked. It needs 'confirm' true, also for an empty calendar. Without it, nothing is deleted. The result says what was checked.",
                properties: [
                    "calendar": Self.property("string", "Calendar name or id. Names ignore case."),
                    "confirm": Self.property(
                        "boolean", "Must be true to delete the calendar. Without it, nothing is deleted."),
                ],
                required: ["calendar"], destructive: true, idempotent: true),
        ]
    }

    // MARK: routing

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        switch tool {
        case "list_calendars": return try await listCalendars()
        case "list_events": return try await listEvents(args)
        case "search_events": return try await searchEvents(args)
        case "get_event": return try await getEvent(args)
        case "create_event": return try await createEvent(args)
        case "update_event": return try await updateEvent(args)
        case "delete_event": return try await deleteEvent(args)
        case "delete_calendar": return try await deleteCalendar(args)
        default:
            throw ToolError(.unknownTool, "The calendar module has no tool named '\(tool)'.")
        }
    }

    // MARK: backend access

    /// Checks the permission (it may show the macOS prompt). Call it after the input checks.
    private func access() async throws {
        let store = store
        try await ensureAccess(
            .calendars, state: { store.accessState() }, request: { try await store.requestAccess() },
            timeout: permissionTimeout)
    }

    /// One backend call with the 30 second limit.
    private func backend<T: Sendable>(_ operation: @escaping @Sendable (any CalendarStore) async throws -> T)
        async throws -> T
    {
        let store = store
        return try await withTimeout(seconds: backendTimeout) { try await operation(store) }
    }

    private func calendar(named query: String?, writable: Bool = false) async throws -> CalendarInfo? {
        guard let query else { return nil }
        let all = try await backend { try await $0.calendars() }
        let found = try resolveByIdOrName(query, kind: "calendar", in: all)
        if writable && !found.writable { throw Self.readOnlyCalendar(found.title) }
        return found
    }

    private static func readOnlyCalendar(_ name: String) -> ToolError {
        ToolError.invalidInput(
            "Calendar '\(name)' does not allow changes (for example a subscribed or birthday calendar).")
    }

    // MARK: output

    private struct CalendarList: Encodable { let calendars: [CalendarInfo] }
    private struct EventList: Encodable {
        let events: [EventInfo]
        let total: Int
        let truncated: Bool
    }
    private struct Deleted: Encodable {
        let deleted: String
        /// The event as it was, so create_event can make it again.
        let event: EventInfo
    }
    private struct ConfirmNeeded: Encodable {
        let confirmRequired = true
        let event: EventInfo
    }

    /// What `delete_calendar` looked at.
    private struct Checked: Encodable {
        let from: Date
        let to: Date
        /// Events found in the range. It is 0, or the call would have been refused.
        let eventCount: Int
    }
    private struct CalendarConfirmNeeded: Encodable {
        let confirmRequired = true
        let calendar: CalendarInfo
        let checked: Checked
    }
    private struct CalendarDeleted: Encodable {
        let deleted: String
        let calendar: CalendarInfo
        let checked: Checked
    }

    static func describe(_ event: EventInfo) -> String {
        var parts = [event.title]
        let range = "\(ISODate.string(event.start)) to \(ISODate.string(event.end))"
        parts.append(event.allDay ? "\(range) (all day)" : range)
        parts.append(event.calendar)
        if let location = event.location, !location.isEmpty { parts.append("at \(location)") }
        if let rule = event.repeat { parts.append("repeats \(rule.text)") }
        if !event.alerts.isEmpty {
            parts.append("alerts \(event.alerts.map(String.init).joined(separator: ", ")) min before")
        }
        parts.append("id: \(event.id)")
        return parts.joined(separator: " | ")
    }

    private func eventList(_ events: [EventInfo], limit: Int) throws -> ToolOutput {
        let sorted = events.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        let shown = Array(sorted.prefix(limit))
        let truncated = sorted.count > shown.count
        var lines = [
            truncated
                ? "Showing \(shown.count) of \(sorted.count) events. Raise 'limit' (maximum 500) or use a shorter range."
                : "\(shown.count) events."
        ]
        lines += shown.map { "- " + Self.describe($0) }
        return try ToolOutput(
            text: lines.joined(separator: "\n"),
            payload: EventList(events: shown, total: sorted.count, truncated: truncated))
    }

    // MARK: read tools

    private func listCalendars() async throws -> ToolOutput {
        try await access()
        let calendars = try await backend { try await $0.calendars() }.sorted { $0.title < $1.title }
        var lines = ["\(calendars.count) calendars."]
        lines += calendars.map {
            "- \($0.title) | \($0.type)\($0.source.map { " | \($0)" } ?? "") | \($0.writable ? "writable" : "read-only") | id: \($0.id)"
        }
        return try ToolOutput(text: lines.joined(separator: "\n"), payload: CalendarList(calendars: calendars))
    }

    private func listEvents(_ args: Arguments) async throws -> ToolOutput {
        let start = try args.requiredDate("start")
        let end = try args.requiredDate("end")
        let calendarName = try args.string("calendar")
        let limit = try args.int("limit", default: 50, range: 1...500)
        let range = try ISODate.range(start: start, end: end, maxDays: 366)

        try await access()
        let ids = try await calendar(named: calendarName).map { [$0.id] } ?? []
        let events = try await backend { try await $0.events(start: range.start, end: range.end, calendarIds: ids) }
        return try eventList(events, limit: limit)
    }

    private func searchEvents(_ args: Arguments) async throws -> ToolOutput {
        let query = try args.requiredString("query")
        let start = try args.date("start")
        let end = try args.date("end")
        let limit = try args.int("limit", default: 50, range: 1...500)
        let range: (start: Date, end: Date)
        switch (start, end) {
        case (nil, nil):
            let now = Date()
            let day: TimeInterval = 86_400
            range = (now.addingTimeInterval(-30 * day), now.addingTimeInterval(30 * day))
        case (let start?, let end?):
            range = try ISODate.range(start: start, end: end, maxDays: 366)
        default:
            throw ToolError.invalidInput("Give both 'start' and 'end', or neither.")
        }

        try await access()
        let events = try await backend { try await $0.events(start: range.start, end: range.end, calendarIds: []) }
        let hits = events.filter { event in
            [event.title, event.location, event.notes].contains {
                $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return try eventList(hits, limit: limit)
    }

    private func getEvent(_ args: Arguments) async throws -> ToolOutput {
        let ref = try EventRef.parse(try args.requiredString("id"))
        try await access()
        let event = try await existing(ref)
        return try ToolOutput(text: Self.describe(event), payload: event)
    }

    private func existing(_ ref: EventRef) async throws -> EventInfo {
        guard let event = try await backend({ try await $0.event(ref) }) else {
            throw ToolError(
                .notFound, "No event has the id '\(ref.string)'.",
                fix: "Use an id from list_events or search_events. The event may have been deleted.")
        }
        return event
    }

    // MARK: write tools

    /// Works out the final start, end and all-day flag, and checks them.
    /// All-day: the event runs from the start of the first day to the end of the last day, so `end` is the last day.
    /// Other events: end must be after start. A nil start or end comes from `existing` (an update).
    static func resolveTimes(
        start: ParsedDate?, end: ParsedDate?, allDay: Bool?, existing: EventInfo?
    ) throws -> (start: Date, end: Date, allDay: Bool) {
        let isAllDay = allDay ?? existing?.allDay ?? ((start?.dateOnly ?? false) && (end?.dateOnly ?? false))
        guard let startDate = start?.date ?? existing?.start, let endDate = end?.date ?? existing?.end else {
            throw ToolError.invalidInput("'start' and 'end' are required.")
        }
        let first = isAllDay ? ISODate.startOfDay(startDate) : startDate
        let last = isAllDay ? ISODate.endOfDay(endDate) : endDate
        guard last > first else {
            throw ToolError(
                .invalidInput, "'end' must be after 'start'.",
                fix: existing == nil
                    ? "Use an end that is later than start."
                    : "Use an end that is later than start. When you move the start, send a new end too.")
        }
        return (first, last, isAllDay)
    }

    private func createEvent(_ args: Arguments) async throws -> ToolOutput {
        let title = try args.requiredString("title")
        let start = try args.requiredDate("start")
        let end = try args.requiredDate("end")
        let calendarName = try args.string("calendar")
        let location = try args.string("location")
        let notes = try args.string("notes")
        let allDay = try args.bool("all_day")
        let url = try args.url("url")
        let alerts = try args.alerts() ?? []
        var rule: RepeatRule?
        if case .set(let given)? = try args.repeatChange() { rule = given }
        let times = try Self.resolveTimes(start: start, end: end, allDay: allDay, existing: nil)
        try rule?.checkEnd(after: times.start)

        try await access()
        let calendar = try await calendar(named: calendarName, writable: true)
        let draft = NewEvent(
            title: title, start: times.start, end: times.end, allDay: times.allDay, calendarId: calendar?.id,
            location: location, notes: notes, url: url?.isEmpty == true ? nil : url, alerts: alerts, repeat: rule)
        let event = try await backend { try await $0.create(draft) }
        return try ToolOutput(text: "Created event: " + Self.describe(event), payload: event)
    }

    private func spanArgument(_ args: Arguments) throws -> EventSpan {
        guard let text = try args.string("span") else { return .this }
        guard let span = EventSpan(rawValue: text) else {
            throw ToolError.invalidInput("'span' must be 'this' or 'future'.")
        }
        return span
    }

    private func updateEvent(_ args: Arguments) async throws -> ToolOutput {
        let ref = try EventRef.parse(try args.requiredString("id"))
        let span = try spanArgument(args)
        let confirmed = try args.bool("confirm") == true
        let title = try args.string("title")
        if title?.isEmpty == true { throw ToolError.invalidInput("'title' must not be empty.") }
        let start = try args.date("start")
        let end = try args.date("end")
        let allDay = try args.bool("all_day")
        let location = try args.string("location")
        let notes = try args.string("notes")
        let url = try args.url("url")
        let calendarName = try args.string("calendar")
        let alerts = try args.alerts()
        let repeatChange = try args.repeatChange()
        var patch = EventPatch(
            title: title, location: location, notes: notes, url: url, alerts: alerts, repeat: repeatChange)
        let changesTime = start != nil || end != nil || allDay != nil
        guard
            changesTime || title != nil || location != nil || notes != nil || url != nil || calendarName != nil
                || alerts != nil || repeatChange != nil
        else {
            throw ToolError.invalidInput("Give at least one field to change.")
        }

        try await access()
        let current = try await existing(ref)
        if current.recurring && ref.occurrence == nil { throw EventRef.bareRecurringError }
        if current.readOnly { throw Self.readOnlyCalendar(current.calendar) }
        if current.recurring && span != .future {
            if repeatChange != nil {
                throw ToolError(
                    .invalidInput, "Changing 'repeat' of a recurring event needs 'span' 'future'.",
                    fix:
                        "Call again with 'span' 'future' and 'confirm' true. The rule then changes for this and all later occurrences."
                )
            }
            if calendarName != nil {
                throw ToolError(
                    .invalidInput, "Moving a recurring event to another calendar needs 'span' 'future'.",
                    fix: "Call again with 'span' 'future' and 'confirm' true."
                )
            }
        }
        if let calendarName {
            patch.calendarId = try await calendar(named: calendarName, writable: true)?.id
        }
        var newTimes = (start: current.start, end: current.end)
        if changesTime {
            let times = try Self.resolveTimes(start: start, end: end, allDay: allDay, existing: current)
            patch.start = times.start
            patch.end = times.end
            patch.allDay = times.allDay
            newTimes = (times.start, times.end)
        }
        if case .set(let rule)? = repeatChange { try rule.checkEnd(after: newTimes.start) }
        if current.recurring && span == .future && !confirmed {
            return try ToolOutput(
                text:
                    "Nothing changed. This changes this and all later occurrences of '\(current.title)'. Call again with 'confirm' true.",
                payload: ConfirmNeeded(event: current))
        }
        let changes = patch
        let event = try await backend { try await $0.update(ref, changes, span: span) }
        return try ToolOutput(text: "Updated event: " + Self.describe(event), payload: event)
    }

    private func deleteEvent(_ args: Arguments) async throws -> ToolOutput {
        let ref = try EventRef.parse(try args.requiredString("id"))
        let span = try spanArgument(args)
        let confirmed = try args.bool("confirm") == true

        try await access()
        let current = try await existing(ref)
        if current.recurring && ref.occurrence == nil { throw EventRef.bareRecurringError }
        if current.readOnly { throw Self.readOnlyCalendar(current.calendar) }
        if current.recurring && span == .future && !confirmed {
            return try ToolOutput(
                text:
                    "Nothing deleted. This deletes this and all later occurrences of '\(current.title)', and it cannot be undone. Call again with 'confirm' true.",
                payload: ConfirmNeeded(event: current))
        }
        try await backend { try await $0.delete(ref, span: span) }
        return try ToolOutput(
            text: "Deleted event: \(Self.describe(current)). To undo, call create_event with the fields in 'event'.",
            payload: Deleted(deleted: current.id, event: current))
    }

    private func deleteCalendar(_ args: Arguments) async throws -> ToolOutput {
        let query = try args.requiredString("calendar")
        let confirmed = try args.bool("confirm") == true

        try await access()
        guard let found = try await calendar(named: query, writable: true) else {
            throw ToolError.invalidInput("'calendar' is required.")
        }
        if found.type == "subscription" || found.type == "birthday" {
            throw ToolError(
                .invalidInput, "'\(found.title)' is a \(found.type) calendar. Nothing was deleted.",
                fix: "Remove a subscribed or birthday calendar in the Calendar app.")
        }
        if found.isDefault {
            throw ToolError(
                .invalidInput, "'\(found.title)' is the default calendar for new events. Nothing was deleted.",
                fix: "Make another calendar the default in the Calendar app first, or keep this calendar.")
        }
        let now = Date()
        let windows = CalendarEmptiness.windows(now: now)
        let id = found.id
        var identifiers = Set<String>()
        for window in windows {
            let events = try await backend {
                try await $0.events(start: window.start, end: window.end, calendarIds: [id])
            }
            identifiers.formUnion(events.map { (try? EventRef.parse($0.id).identifier) ?? $0.id })
        }
        let span = CalendarEmptiness.span(now: now)
        let checked = Checked(from: span.start, to: span.end, eventCount: identifiers.count)
        let range = "from \(ISODate.string(span.start)) to \(ISODate.string(span.end))"
        if !identifiers.isEmpty {
            throw ToolError(
                .invalidInput,
                "'\(found.title)' has \(identifiers.count) events \(range). Nothing was deleted.",
                fix: "Only an empty calendar can be deleted. Move or delete the events first.")
        }
        if !confirmed {
            return try ToolOutput(
                text:
                    "Nothing deleted. The calendar '\(found.title)' has no events \(range). Events outside that range are not checked. Ask the user, then call again with 'confirm' true.",
                payload: CalendarConfirmNeeded(calendar: found, checked: checked))
        }
        try await backend { try await $0.deleteCalendar(id: id) }
        return try ToolOutput(
            text:
                "Deleted calendar '\(found.title)'. It had no events \(range). Events outside that range were not checked.",
            payload: CalendarDeleted(deleted: found.id, calendar: found, checked: checked))
    }
}
