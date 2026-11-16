import AppleSauceCore
import Foundation

@testable import ModCalendar

/// A calendar store in memory. It records every call. It never touches EventKit.
final class FakeCalendarStore: CalendarStore, @unchecked Sendable {
    struct State {
        var permission: PermissionState = .granted
        /// What `requestAccess` returns. On true the permission becomes granted.
        var requestResult = true
        /// Seconds that `requestAccess` and `event` wait first (to test time limits).
        var requestDelay: Double = 0
        var eventDelay: Double = 0
        var calendars: [CalendarInfo] = []
        var events: [EventInfo] = []
        var calls: [String] = []
        var eventsQuery: (start: Date, end: Date, calendarIds: [String])?
        var created: NewEvent?
        var updated: (ref: EventRef, patch: EventPatch, span: EventSpan)?
        var deleted: (ref: EventRef, span: EventSpan)?
    }

    private let lock = NSLock()
    private var state: State

    init(_ state: State = State()) {
        self.state = state
    }

    func read<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func write(_ body: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&state)
    }

    func accessState() -> PermissionState { read(\.permission) }

    func requestAccess() async throws -> Bool {
        write { $0.calls.append("request") }
        let delay = read(\.requestDelay)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        let result = read(\.requestResult)
        if result { write { $0.permission = .granted } }
        return result
    }

    func calendars() async throws -> [CalendarInfo] {
        write { $0.calls.append("calendars") }
        return read(\.calendars)
    }

    func events(start: Date, end: Date, calendarIds: [String]) async throws -> [EventInfo] {
        write {
            $0.calls.append("events")
            $0.eventsQuery = (start, end, calendarIds)
        }
        return read(\.events).filter { calendarIds.isEmpty || calendarIds.contains($0.calendarId) }
    }

    func event(_ ref: EventRef) async throws -> EventInfo? {
        write { $0.calls.append("event") }
        let delay = read(\.eventDelay)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return read(\.events).first { $0.id == ref.string }
    }

    func create(_ event: NewEvent) async throws -> EventInfo {
        write {
            $0.calls.append("create")
            $0.created = event
        }
        let calendar = read(\.calendars).first { $0.id == event.calendarId } ?? read(\.calendars)[0]
        return EventInfo(
            id: "NEW", title: event.title, start: event.start, end: event.end, allDay: event.allDay,
            location: event.location, notes: event.notes, url: event.url, calendar: calendar.title,
            calendarId: calendar.id, recurring: event.repeat != nil, readOnly: !calendar.writable,
            alerts: event.alerts, repeat: event.repeat)
    }

    func update(_ ref: EventRef, _ patch: EventPatch, span: EventSpan) async throws -> EventInfo {
        write {
            $0.calls.append("update")
            $0.updated = (ref, patch, span)
        }
        return read(\.events).first { $0.id == ref.string }!
    }

    func delete(_ ref: EventRef, span: EventSpan) async throws {
        write {
            $0.calls.append("delete")
            $0.deleted = (ref, span)
        }
    }
}

// MARK: sample data

func date(_ text: String) -> Date { ISODate.parse(text)!.date }

func calendarInfo(_ id: String, _ title: String, writable: Bool = true) -> CalendarInfo {
    CalendarInfo(id: id, title: title, type: "caldav", source: "iCloud", writable: writable)
}

func eventInfo(
    _ id: String, _ title: String, start: String, end: String, calendar: CalendarInfo = calendarInfo("c1", "Work"),
    allDay: Bool = false, location: String? = nil, notes: String? = nil, recurring: Bool = false
) -> EventInfo {
    EventInfo(
        id: id, title: title, start: date(start), end: date(end), allDay: allDay, location: location,
        notes: notes, url: nil, calendar: calendar.title, calendarId: calendar.id, recurring: recurring,
        readOnly: !calendar.writable)
}
