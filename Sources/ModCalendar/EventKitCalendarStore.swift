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
        let defaultId = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).map {
            var info = Self.info($0)
            info.isDefault = $0.calendarIdentifier == defaultId
            return info
        }
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
        setAlarms(draft.alerts, on: event)
        if let rule = draft.repeat { event.recurrenceRules = [Self.recurrenceRule(rule)] }
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
        if let alerts = patch.alerts { setAlarms(alerts, on: event) }
        switch patch.repeat {
        case .set(let rule)?: event.recurrenceRules = [Self.recurrenceRule(rule)]
        case .clear?: event.recurrenceRules = nil
        case nil: break
        }
        var target: EKCalendar?
        if let id = patch.calendarId {
            guard let calendar = store.calendar(withIdentifier: id) else {
                throw ToolError(
                    .notFound, "No calendar has the id '\(id)'.", fix: "Use a calendar from list_calendars.")
            }
            event.calendar = calendar
            target = calendar
        }
        do {
            try store.save(event, span: Self.ekSpan(span), commit: true)
        } catch {
            if let target { throw Self.moveError(error, to: target.title) }
            throw Self.saveError(error)
        }
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

    func deleteCalendar(id: String) async throws {
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowedEntityTypes.contains(.event) else {
            throw ToolError(.notFound, "No calendar has the id '\(id)'.", fix: "Use a calendar from list_calendars.")
        }
        guard !calendar.isImmutable else {
            throw ToolError(
                .invalidInput, "The calendar '\(calendar.title)' cannot be deleted. Calendar marks it as fixed.",
                fix: "Delete it in the Calendar app if it allows that. Nothing was deleted.")
        }
        do {
            try store.removeCalendar(calendar, commit: true)
        } catch {
            throw ToolError(
                .internalError, "Calendar could not delete the calendar: \(error.localizedDescription)",
                fix: "Delete the calendar in the Calendar app. Nothing was deleted.")
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

    private func setAlarms(_ minutes: [Int], on event: EKEvent) {
        event.alarms = minutes.isEmpty ? nil : minutes.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
    }

    /// EventKit may refuse to move an event to a calendar of another account (source).
    private static func moveError(_ error: Error, to calendar: String) -> ToolError {
        ToolError(
            .invalidInput, "Calendar could not move the event to '\(calendar)': \(error.localizedDescription)",
            fix:
                "Calendar can refuse to move an event between accounts. Create the event in '\(calendar)' with create_event, then delete the old one."
        )
    }

    private static func recurrenceRule(_ rule: RepeatRule) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency =
            switch rule.frequency {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
        var end: EKRecurrenceEnd?
        if let date = rule.end {
            end = EKRecurrenceEnd(end: date)
        } else if let count = rule.count {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }
        let days = rule.days.map { EKRecurrenceDayOfWeek(weekday($0)) }
        return EKRecurrenceRule(
            recurrenceWith: frequency, interval: rule.interval, daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
            end: end)
    }

    private static func weekday(_ day: Weekday) -> EKWeekday {
        switch day {
        case .mon: .monday
        case .tue: .tuesday
        case .wed: .wednesday
        case .thu: .thursday
        case .fri: .friday
        case .sat: .saturday
        case .sun: .sunday
        }
    }

    private static func repeatRule(_ rule: EKRecurrenceRule?) -> RepeatRule? {
        guard let rule else { return nil }
        let frequency: RepeatFrequency =
            switch rule.frequency {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            @unknown default: .daily
            }
        var result = RepeatRule(frequency: frequency, interval: max(rule.interval, 1))
        result.end = rule.recurrenceEnd?.endDate
        if let count = rule.recurrenceEnd?.occurrenceCount, count > 0 { result.count = count }
        let found = (rule.daysOfTheWeek ?? []).compactMap { Self.weekday(from: $0.dayOfTheWeek) }
        result.days = Weekday.allCases.filter { found.contains($0) }
        return result
    }

    private static func weekday(from day: EKWeekday) -> Weekday? {
        switch day {
        case .monday: .mon
        case .tuesday: .tue
        case .wednesday: .wed
        case .thursday: .thu
        case .friday: .fri
        case .saturday: .sat
        case .sunday: .sun
        @unknown default: nil
        }
    }

    /// Alerts as minutes before the start. Alerts that depend on a place are left out.
    private static func alerts(_ event: EKEvent) -> [Int] {
        let minutes = (event.alarms ?? []).compactMap { alarm -> Int? in
            guard alarm.proximity == .none else { return nil }
            let seconds: TimeInterval
            if let date = alarm.absoluteDate {
                seconds = event.startDate.timeIntervalSince(date)
            } else {
                seconds = -alarm.relativeOffset
            }
            return seconds >= 0 ? Int((seconds / 60).rounded()) : nil
        }
        return Array(Set(minutes)).sorted(by: >)
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
            recurring: recurring, readOnly: !(event.calendar?.allowsContentModifications ?? false),
            alerts: alerts(event), repeat: repeatRule(event.recurrenceRules?.first))
    }
}
#endif
