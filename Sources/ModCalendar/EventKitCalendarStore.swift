// The real calendar store. EventKit exists on macOS only.
#if os(macOS)
import AppleSauceCore
import EventKit
import Foundation

/// The real calendar store. It is the only code that touches EventKit.
/// EventKit objects stay inside this actor. Only plain structs leave it.
actor EventKitCalendarStore: CalendarStore {
    private let store = EKEventStore()

    nonisolated func accessState() -> PermissionState {
        SystemPermissionChecker().state(of: .calendars)
    }

    /// Uses the completion handler form. The async form sends the store out of this actor, which Swift 6.1 rejects.
    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func calendars() async throws -> [CalendarInfo] {
        store.calendars(for: .event).map(Self.info)
    }

    func events(start: Date, end: Date, calendarIds: [String]) async throws -> [EventInfo] {
        var selected: [EKCalendar]?
        if !calendarIds.isEmpty {
            selected = calendarIds.compactMap { store.calendar(withIdentifier: $0) }
            if selected?.isEmpty == true { return [] }
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        return store.events(matching: predicate).map(Self.info)
    }

    func event(_ ref: EventRef) async throws -> EventInfo? {
        try locate(ref).map(Self.info)
    }

    func create(_ draft: NewEvent) async throws -> EventInfo {
        let event = EKEvent(eventStore: store)
        if let id = draft.calendarId {
            event.calendar = store.calendar(withIdentifier: id)
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }
        guard event.calendar != nil else {
            throw ToolError(
                .notFound, "There is no default calendar for new events.",
                fix: "Set a default calendar in the Calendar app, or pass 'calendar'.")
        }
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.allDay
        event.location = draft.location
        event.notes = draft.notes
        event.url = draft.url.flatMap { URL(string: $0) }
        try save(event, span: .thisEvent)
        return Self.info(event)
    }

    func update(_ ref: EventRef, _ patch: EventPatch, span: EventSpan) async throws -> EventInfo {
        guard let event = try locate(ref) else { throw Self.missing(ref) }
        try Self.requireOccurrence(event, ref)
        if let title = patch.title { event.title = title }
        if let allDay = patch.allDay { event.isAllDay = allDay }
        if let start = patch.start { event.startDate = start }
        if let end = patch.end { event.endDate = end }
        if let location = patch.location { event.location = location.isEmpty ? nil : location }
        if let notes = patch.notes { event.notes = notes.isEmpty ? nil : notes }
        if let url = patch.url { event.url = url.isEmpty ? nil : URL(string: url) }
        try save(event, span: Self.ekSpan(span))
        return Self.info(event)
    }

    func delete(_ ref: EventRef, span: EventSpan) async throws {
        guard let event = try locate(ref) else { throw Self.missing(ref) }
        try Self.requireOccurrence(event, ref)
        do {
            try store.remove(event, span: Self.ekSpan(span), commit: true)
        } catch {
            throw Self.saveError(error)
        }
    }

    // MARK: helpers

    /// A bare id of a recurring event points at the first occurrence only. A change would hit the wrong one.
    private static func requireOccurrence(_ event: EKEvent, _ ref: EventRef) throws {
        if event.hasRecurrenceRules && ref.occurrence == nil { throw EventRef.bareRecurringError }
    }

    /// `calendarItem(withIdentifier:)` returns the first occurrence of a recurring event.
    /// For an id with an occurrence date, search a one second window around that date.
    private func locate(_ ref: EventRef) throws -> EKEvent? {
        guard let item = store.calendarItem(withIdentifier: ref.identifier) as? EKEvent else { return nil }
        guard let occurrence = ref.occurrence else { return item }
        let predicate = store.predicateForEvents(
            withStart: occurrence.addingTimeInterval(-1), end: occurrence.addingTimeInterval(1),
            calendars: [item.calendar])
        return store.events(matching: predicate).first {
            $0.calendarItemIdentifier == ref.identifier && abs($0.startDate.timeIntervalSince(occurrence)) < 1
        }
    }

    private func save(_ event: EKEvent, span: EKSpan) throws {
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw Self.saveError(error)
        }
    }

    private static func saveError(_ error: Error) -> ToolError {
        ToolError(
            .internalError, "Calendar could not save the change: \(error.localizedDescription)",
            fix: "Check that the calendar allows changes and try again.")
    }

    private static func missing(_ ref: EventRef) -> ToolError {
        ToolError(
            .notFound, "No event has the id '\(ref.string)'.",
            fix: "Use an id from list_events or search_events.")
    }

    private static func ekSpan(_ span: EventSpan) -> EKSpan {
        span == .future ? .futureEvents : .thisEvent
    }

    private static func info(_ calendar: EKCalendar) -> CalendarInfo {
        let type: String =
            switch calendar.type {
            case .local: "local"
            case .calDAV: "caldav"
            case .exchange: "exchange"
            case .subscription: "subscription"
            case .birthday: "birthday"
            @unknown default: "other"
            }
        return CalendarInfo(
            id: calendar.calendarIdentifier, title: calendar.title, type: type, source: calendar.source?.title,
            writable: calendar.allowsContentModifications)
    }

    private static func info(_ event: EKEvent) -> EventInfo {
        let recurring = event.hasRecurrenceRules
        let ref = EventRef(
            identifier: event.calendarItemIdentifier, occurrence: recurring ? event.startDate : nil)
        return EventInfo(
            id: ref.string, title: event.title ?? "", start: event.startDate, end: event.endDate,
            allDay: event.isAllDay, location: event.location.flatMap { $0.isEmpty ? nil : $0 },
            notes: event.notes.flatMap { $0.isEmpty ? nil : $0 }, url: event.url?.absoluteString,
            calendar: event.calendar?.title ?? "", calendarId: event.calendar?.calendarIdentifier ?? "",
            recurring: recurring, readOnly: !(event.calendar?.allowsContentModifications ?? false))
    }
}
#endif
