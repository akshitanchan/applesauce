import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModCalendar

@Suite struct CalendarAlertsRepeatTests {
    let work = calendarInfo("c1", "Work")
    let home = calendarInfo("c2", "Home")
    let holidays = calendarInfo("c3", "Holidays", writable: false)
    let base: [String: Value] = [
        "title": "Standup", "start": "2026-11-16T09:00:00+01:00", "end": "2026-11-16T09:15:00+01:00",
    ]

    func store(_ edit: (inout FakeCalendarStore.State) -> Void = { _ in }) -> FakeCalendarStore {
        var state = FakeCalendarStore.State()
        state.calendars = [work, home, holidays]
        edit(&state)
        return FakeCalendarStore(state)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeCalendarStore) async throws -> ToolOutput {
        try await CalendarModule(store: store).call(tool, Arguments(args))
    }

    func failure(_ tool: String, _ args: [String: Value], on store: FakeCalendarStore) async -> ToolError? {
        do {
            _ = try await run(tool, args, on: store)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func creating(_ extra: [String: Value]) -> [String: Value] {
        base.merging(extra) { $1 }
    }

    /// A recurring event and its id (the id text uses the local time zone, so build it the same way).
    func recurring(calendar: CalendarInfo? = nil) -> (id: String, event: EventInfo) {
        let id = EventRef(identifier: "R1", occurrence: date("2026-11-16T09:00:00+01:00")).string
        let event = eventInfo(
            id, "Standup", start: "2026-11-16T09:00:00+01:00", end: "2026-11-16T09:15:00+01:00",
            calendar: calendar ?? work, recurring: true)
        return (id, event)
    }

    // MARK: input checks

    @Test func badAlertsAndRepeatNeverReachTheStore() async {
        let fake = store { $0.permission = .notDetermined }
        let bad: [[String: Value]] = [
            creating(["alerts": "10"]),
            creating(["alerts": [10, "x"]]),
            creating(["alerts": [1.5]]),
            creating(["alerts": [-1]]),
            creating(["alerts": [40321]]),
            creating(["alerts": [1, 2, 3, 4, 5, 6]]),
            creating(["repeat": "weekly"]),
            creating(["repeat": [:]]),
            creating(["repeat": ["frequency": "hourly"]]),
            creating(["repeat": ["frequency": "daily", "interval": 0]]),
            creating(["repeat": ["frequency": "daily", "interval": 100]]),
            creating(["repeat": ["frequency": "daily", "count": 0]]),
            creating(["repeat": ["frequency": "daily", "count": 1000]]),
            creating(["repeat": ["frequency": "daily", "count": 3, "end": "2026-12-31"]]),
            creating(["repeat": ["frequency": "daily", "end": "soon"]]),
            creating(["repeat": ["frequency": "daily", "days": ["mon"]]]),
            creating(["repeat": ["frequency": "weekly", "days": ["monday"]]]),
            creating(["repeat": ["frequency": "daily", "end": "2026-11-15"]]),
        ]
        for args in bad {
            let error = await failure("create_event", args, on: fake)
            #expect(error?.code == .invalidInput, "\(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    // MARK: alerts

    @Test func createPassesAlertsSortedWithoutRepeats() async throws {
        let fake = store()
        let output = try await run("create_event", creating(["alerts": [10, 1440, 10, 0]]), on: fake)
        #expect(fake.read(\.created)?.alerts == [1440, 10, 0])
        let alerts = output.structured?.objectValue?["alerts"]?.arrayValue?.compactMap(\.intValue)
        #expect(alerts == [1440, 10, 0])
        #expect(output.text.contains("alerts 1440, 10, 0 min before"))
    }

    @Test func updateAlertsReplaceAndEmptyRemoves() async throws {
        let event = eventInfo("e1", "A", start: "2026-11-12T09:00:00Z", end: "2026-11-12T10:00:00Z")
        let fake = store { $0.events = [event] }
        _ = try await run("update_event", ["id": "e1", "alerts": [15]], on: fake)
        #expect(fake.read(\.updated)?.patch.alerts == [15])
        _ = try await run("update_event", ["id": "e1", "alerts": []], on: fake)
        #expect(fake.read(\.updated)?.patch.alerts == [])
        _ = try await run("update_event", ["id": "e1", "title": "B"], on: fake)
        #expect(fake.read(\.updated)?.patch.alerts == nil)
    }

    // MARK: repeat

    @Test func createWithWeeklyRule() async throws {
        let fake = store()
        let rule: Value = [
            "frequency": "Weekly", "interval": 2, "days": ["wed", "mon", "wed"], "end": "2026-12-31",
        ]
        let output = try await run("create_event", creating(["repeat": rule]), on: fake)
        let created = try #require(fake.read(\.created)?.repeat)
        #expect(created.frequency == .weekly)
        #expect(created.interval == 2)
        #expect(created.days == [.mon, .wed])
        #expect(created.end == ISODate.endOfDay(date("2026-12-31")))
        #expect(created.count == nil)
        let text = "every 2 weeks on mon, wed until \(ISODate.string(ISODate.endOfDay(date("2026-12-31"))))"
        #expect(created.text == text)
        #expect(output.text.contains("repeats \(text)"))
        let payload = try #require(output.structured?.objectValue?["repeat"]?.objectValue)
        #expect(payload["frequency"]?.stringValue == "weekly")
        #expect(payload["interval"]?.intValue == 2)
    }

    @Test func ruleDefaultsAndCount() async throws {
        let fake = store()
        _ = try await run("create_event", creating(["repeat": ["frequency": "daily", "count": 5]]), on: fake)
        let rule = try #require(fake.read(\.created)?.repeat)
        #expect(rule.interval == 1)
        #expect(rule.count == 5)
        #expect(rule.text == "every day, 5 times")
        #expect(RepeatRule(frequency: .monthly).text == "every month")
        #expect(RepeatRule(frequency: .yearly, interval: 3).text == "every 3 years")
    }

    @Test func noneAndNullMeanNoRuleOnCreate() async throws {
        let fake = store()
        _ = try await run("create_event", creating(["repeat": ["frequency": "none"]]), on: fake)
        #expect(fake.read(\.created)?.repeat == nil)
        _ = try await run("create_event", creating(["repeat": .null]), on: fake)
        #expect(fake.read(\.created)?.repeat == nil)
    }

    @Test func changingRepeatOfARecurringEventNeedsSpanFuture() async throws {
        let (id, event) = recurring()
        let fake = store { $0.events = [event] }
        let error = await failure(
            "update_event", ["id": .string(id), "repeat": ["frequency": "daily"]], on: fake)
        #expect(error?.code == .invalidInput)
        #expect(error?.message.contains("'span' 'future'") == true)
        #expect(fake.read(\.updated) == nil)

        // With span future it still needs confirm.
        let output = try await run(
            "update_event", ["id": .string(id), "repeat": ["frequency": "daily"], "span": "future"], on: fake)
        #expect(fake.read(\.updated) == nil)
        #expect(output.text.contains("Nothing changed"))
        #expect(output.structured?.objectValue?["confirm_required"]?.boolValue == true)

        _ = try await run(
            "update_event",
            ["id": .string(id), "repeat": ["frequency": "daily"], "span": "future", "confirm": true], on: fake)
        let update = try #require(fake.read(\.updated))
        #expect(update.span == .future)
        #expect(update.patch.repeat == .set(RepeatRule(frequency: .daily)))
    }

    @Test func nullOrNoneRemovesTheRule() async throws {
        let (id, event) = recurring()
        let fake = store { $0.events = [event] }
        _ = try await run(
            "update_event", ["id": .string(id), "repeat": .null, "span": "future", "confirm": true], on: fake)
        #expect(fake.read(\.updated)?.patch.repeat == .clear)
        _ = try await run(
            "update_event",
            ["id": .string(id), "repeat": ["frequency": "none"], "span": "future", "confirm": true], on: fake)
        #expect(fake.read(\.updated)?.patch.repeat == .clear)
    }

    @Test func repeatCanBeAddedToAPlainEventWithoutSpan() async throws {
        let event = eventInfo("e1", "A", start: "2026-11-12T09:00:00Z", end: "2026-11-12T10:00:00Z")
        let fake = store { $0.events = [event] }
        _ = try await run("update_event", ["id": "e1", "repeat": ["frequency": "monthly"]], on: fake)
        #expect(fake.read(\.updated)?.patch.repeat == .set(RepeatRule(frequency: .monthly)))
        // The end must come after the event start.
        let error = await failure(
            "update_event", ["id": "e1", "repeat": ["frequency": "daily", "end": "2026-11-11"]], on: fake)
        #expect(error?.code == .invalidInput)
    }

    @Test func futureSpanChangeNeedsConfirm() async throws {
        let (id, event) = recurring()
        let fake = store { $0.events = [event] }
        let output = try await run(
            "update_event", ["id": .string(id), "title": "Sync", "span": "future"], on: fake)
        #expect(fake.read(\.updated) == nil)
        #expect(output.text.contains("Nothing changed"))
        // One occurrence needs no confirm.
        _ = try await run("update_event", ["id": .string(id), "title": "Sync"], on: fake)
        #expect(fake.read(\.updated)?.span == .this)
    }

    @Test func listShowsRepeatAndAlerts() {
        var event = eventInfo("e1", "Gym", start: "2026-11-12T09:00:00Z", end: "2026-11-12T10:00:00Z")
        event.repeat = RepeatRule(frequency: .weekly, days: [.tue, .thu])
        event.alerts = [60, 5]
        let text = CalendarModule.describe(event)
        #expect(text.contains("repeats every week on tue, thu"))
        #expect(text.contains("alerts 60, 5 min before"))
    }

    // MARK: move to another calendar

    @Test func updateMovesToCalendarByNameOrId() async throws {
        let event = eventInfo("e1", "A", start: "2026-11-12T09:00:00Z", end: "2026-11-12T10:00:00Z")
        let fake = store { $0.events = [event] }
        _ = try await run("update_event", ["id": "e1", "calendar": "home"], on: fake)
        #expect(fake.read(\.updated)?.patch.calendarId == "c2")
        _ = try await run("update_event", ["id": "e1", "calendar": "c1"], on: fake)
        #expect(fake.read(\.updated)?.patch.calendarId == "c1")
    }

    @Test func moveToReadOnlyOrUnknownCalendarIsRefused() async throws {
        let event = eventInfo("e1", "A", start: "2026-11-12T09:00:00Z", end: "2026-11-12T10:00:00Z")
        let fake = store { $0.events = [event] }
        let readOnly = await failure("update_event", ["id": "e1", "calendar": "Holidays"], on: fake)
        #expect(readOnly?.code == .invalidInput)
        #expect(readOnly?.message.contains("does not allow changes") == true)
        let unknown = await failure("update_event", ["id": "e1", "calendar": "Nope"], on: fake)
        #expect(unknown?.code == .notFound)
        #expect(fake.read(\.updated) == nil)
    }

    @Test func movingARecurringEventNeedsSpanFutureAndConfirm() async throws {
        let (id, event) = recurring()
        let fake = store { $0.events = [event] }
        let error = await failure("update_event", ["id": .string(id), "calendar": "Home"], on: fake)
        #expect(error?.code == .invalidInput)
        #expect(error?.message.contains("another calendar") == true)
        _ = try await run(
            "update_event", ["id": .string(id), "calendar": "Home", "span": "future", "confirm": true], on: fake)
        #expect(fake.read(\.updated)?.patch.calendarId == "c2")
    }
}
