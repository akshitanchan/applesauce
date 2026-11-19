import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModCalendar

@Suite struct CalendarDeleteTests {
    let work = calendarInfo("c1", "Work", isDefault: true)
    let spare = calendarInfo("c2", "Spare")
    let holidays = calendarInfo("c3", "Holidays", writable: false)
    let subscribed = calendarInfo("c4", "Feed", type: "subscription")
    let birthdays = calendarInfo("c5", "Birthdays", type: "birthday")

    func store(events: [EventInfo] = []) -> FakeCalendarStore {
        var state = FakeCalendarStore.State()
        state.calendars = [work, spare, holidays, subscribed, birthdays]
        state.events = events
        return FakeCalendarStore(state)
    }

    func run(_ args: [String: Value], on store: FakeCalendarStore) async throws -> ToolOutput {
        try await CalendarModule(store: store).call("delete_calendar", Arguments(args))
    }

    func failure(_ args: [String: Value], on store: FakeCalendarStore) async -> ToolError? {
        do {
            _ = try await run(args, on: store)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    @Test func badInputNeverReachesTheStore() async {
        var state = FakeCalendarStore.State()
        state.permission = .notDetermined
        let fake = FakeCalendarStore(state)
        for args: [String: Value] in [[:], ["calendar": 5], ["calendar": "Spare", "confirm": "yes"]] {
            let error = await failure(args, on: fake)
            #expect(error?.code == .invalidInput, "\(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func needsConfirmEvenWhenEmptyAndReportsTheCheck() async throws {
        let fake = store()
        for confirm: Value? in [nil, false] {
            var args: [String: Value] = ["calendar": "spare"]
            if let confirm { args["confirm"] = confirm }
            let output = try await run(args, on: fake)
            let object = try #require(output.structured?.objectValue)
            #expect(object["confirm_required"]?.boolValue == true)
            #expect(object["calendar"]?.objectValue?["id"]?.stringValue == "c2")
            #expect(object["checked"]?.objectValue?["event_count"]?.intValue == 0)
            #expect(output.text.hasPrefix("Nothing deleted."))
        }
        #expect(fake.read(\.deletedCalendar) == nil)
    }

    @Test func deletesAnEmptyCalendar() async throws {
        let fake = store()
        let output = try await run(["calendar": "c2", "confirm": true], on: fake)
        #expect(fake.read(\.deletedCalendar) == "c2")
        let object = try #require(output.structured?.objectValue)
        #expect(object["deleted"]?.stringValue == "c2")
        #expect(object["calendar"]?.objectValue?["title"]?.stringValue == "Spare")
        let checked = try #require(object["checked"]?.objectValue)
        #expect(checked["from"]?.stringValue != nil)
        #expect(checked["to"]?.stringValue != nil)
        #expect(output.text.contains("were not checked"))
    }

    @Test func searchesOnlyThisCalendarInWindowsThatTheStoreAccepts() async throws {
        let fake = store()
        _ = try await run(["calendar": "Spare", "confirm": true], on: fake)
        let queries = fake.read(\.eventsQueries)
        #expect(queries.count >= 5)
        #expect(queries.allSatisfy { $0.calendarIds == ["c2"] })
        let day: TimeInterval = 86_400
        #expect(queries.allSatisfy { $0.end.timeIntervalSince($0.start) <= 1400 * day })
        for (before, after) in zip(queries, queries.dropFirst()) { #expect(before.end == after.start) }
        let total = try #require(queries.last).end.timeIntervalSince(try #require(queries.first).start)
        #expect(total > 7300 * day)
        #expect(queries.first!.start < Date().addingTimeInterval(-3600 * day))
        #expect(queries.last!.end > Date().addingTimeInterval(3600 * day))
    }

    @Test func refusesACalendarWithEventsEvenWithConfirm() async {
        let event = eventInfo(
            "e1", "Dentist", start: "2026-12-01T09:00:00Z", end: "2026-12-01T10:00:00Z", calendar: spare)
        let other = eventInfo("e2", "Sync", start: "2026-12-01T09:00:00Z", end: "2026-12-01T10:00:00Z", calendar: work)
        let fake = store(events: [event, other])
        let error = await failure(["calendar": "Spare", "confirm": true], on: fake)
        #expect(error?.code == .invalidInput)
        #expect(error?.message.contains("has 1 events") == true)
        #expect(error?.message.contains("Nothing was deleted") == true)
        #expect(fake.read(\.deletedCalendar) == nil)
    }

    @Test func countsARecurringEventOnceAcrossWindows() async {
        let first = eventInfo(
            "R1@2026-12-01T09:00:00Z", "Daily", start: "2026-12-01T09:00:00Z", end: "2026-12-01T10:00:00Z",
            calendar: spare, recurring: true)
        let second = eventInfo(
            "R1@2026-12-02T09:00:00Z", "Daily", start: "2026-12-02T09:00:00Z", end: "2026-12-02T10:00:00Z",
            calendar: spare, recurring: true)
        let fake = store(events: [first, second])
        let error = await failure(["calendar": "Spare"], on: fake)
        #expect(error?.message.contains("has 1 events") == true)
    }

    @Test func refusesTheSpecialCalendars() async {
        let fake = store()
        let defaultCalendar = await failure(["calendar": "Work", "confirm": true], on: fake)
        #expect(defaultCalendar?.message.contains("default calendar") == true)
        let readOnly = await failure(["calendar": "Holidays", "confirm": true], on: fake)
        #expect(readOnly?.message.contains("does not allow changes") == true)
        for name in ["Feed", "Birthdays"] {
            let error = await failure(["calendar": .string(name), "confirm": true], on: fake)
            #expect(error?.code == .invalidInput, "\(name)")
        }
        let unknown = await failure(["calendar": "Nope", "confirm": true], on: fake)
        #expect(unknown?.code == .notFound)
        #expect(fake.read(\.deletedCalendar) == nil)
        #expect(!fake.read(\.calls).contains("events"))
    }

    @Test func subscribedAndBirthdayCalendarsGetTheirOwnMessage() async {
        let writableFeed = calendarInfo("c6", "Writable feed", type: "subscription")
        var state = FakeCalendarStore.State()
        state.calendars = [work, writableFeed]
        let fake = FakeCalendarStore(state)
        let error = await failure(["calendar": "Writable feed", "confirm": true], on: fake)
        #expect(error?.message.contains("subscription calendar") == true)
        #expect(fake.read(\.deletedCalendar) == nil)
    }

    @Test func windowsDoNotDependOnTheTimeZone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let windows = CalendarEmptiness.windows(now: now)
        let span = CalendarEmptiness.span(now: now)
        #expect(windows.first?.start == span.start)
        #expect(windows.last?.end == span.end)
        #expect(windows.count == 6)
        #expect(span.end.timeIntervalSince(span.start) == 20 * 365.25 * 86_400)
    }

    @Test func isDestructive() throws {
        let spec = try #require(CalendarModule.toolSpecs.first { $0.tool.name == "delete_calendar" })
        #expect(spec.isWrite)
        #expect(spec.tool.annotations.destructiveHint == true)
    }
}
