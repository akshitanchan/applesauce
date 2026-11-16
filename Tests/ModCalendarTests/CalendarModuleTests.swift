import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModCalendar

@Suite struct CalendarModuleTests {
    let work = calendarInfo("c1", "Work")
    let home = calendarInfo("c2", "Home")
    let holidays = calendarInfo("c3", "Holidays", writable: false)

    func store(_ edit: (inout FakeCalendarStore.State) -> Void = { _ in }) -> FakeCalendarStore {
        var state = FakeCalendarStore.State()
        state.calendars = [work, home, holidays]
        edit(&state)
        return FakeCalendarStore(state)
    }

    func module(_ store: FakeCalendarStore, permissionTimeout: Double = 120, backendTimeout: Double = 30)
        -> CalendarModule
    {
        CalendarModule(store: store, permissionTimeout: permissionTimeout, backendTimeout: backendTimeout)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeCalendarStore) async throws -> ToolOutput {
        try await module(store).call(tool, Arguments(args))
    }

    func failure(
        _ tool: String, _ args: [String: Value], on store: FakeCalendarStore, using module: CalendarModule? = nil
    )
        async -> ToolError?
    {
        do {
            _ = try await (module ?? self.module(store)).call(tool, Arguments(args))
            return nil
        } catch {
            return error as? ToolError
        }
    }

    // MARK: tools

    @Test func toolNamesAndFlags() {
        let tools = module(store()).tools
        #expect(
            tools.map(\.tool.name) == [
                "list_calendars", "list_events", "search_events", "get_event", "create_event", "update_event",
                "delete_event",
            ])
        let writes = tools.filter(\.isWrite).map(\.tool.name)
        #expect(writes == ["create_event", "update_event", "delete_event"])
        #expect(tools.last?.tool.annotations.destructiveHint == true)
        #expect(tools.allSatisfy { !$0.tool.description!.isEmpty })
    }

    @Test func readOnlyRegistryHidesWriteTools() async throws {
        let config = try Config.parse(arguments: ["--read-only"], environment: [:])
        let registry = try Registry(available: [module(store())], config: config)
        #expect(
            registry.tools.map(\.name) == ["list_calendars", "list_events", "search_events", "get_event"])
        let result = await registry.call("delete_event", arguments: ["id": "x"])
        #expect(result.isError == true)
    }

    // MARK: input checks

    @Test func badInputNeverReachesTheStore() async {
        let fake = store { $0.permission = .notDetermined }
        let bad: [(String, [String: Value])] = [
            ("list_events", ["start": "tomorrow", "end": "2026-11-13"]),
            ("list_events", ["start": "2026-02-30", "end": "2026-03-02"]),
            ("list_events", ["start": "2026-11-13", "end": "2026-11-12"]),
            ("list_events", ["start": "2026-01-01", "end": "2027-01-03"]),
            ("list_events", ["start": "2026-11-12", "end": "2026-11-13", "limit": 0]),
            ("list_events", ["start": "2026-11-12", "end": "2026-11-13", "limit": 501]),
            ("list_events", ["start": "2026-11-12"]),
            ("search_events", ["query": "x", "start": "2026-11-12"]),
            ("search_events", ["query": ""]),
            ("get_event", ["id": ""]),
            ("create_event", ["title": "A", "start": "2026-11-12T10:00:00", "end": "2026-11-12T10:00:00"]),
            ("create_event", ["title": "A", "start": "2026-11-12T10:00:00", "end": "2026-11-12T09:00:00"]),
            ("create_event", ["title": "A", "start": "2026-11-12", "end": "2026-11-11"]),
            ("create_event", ["title": "", "start": "2026-11-12", "end": "2026-11-12"]),
            ("create_event", ["title": "A", "start": "2026-11-12", "end": "2026-11-12", "url": "not a url"]),
            ("update_event", ["id": "x"]),
            ("update_event", ["id": "x", "title": ""]),
            ("update_event", ["id": "x", "title": "T", "span": "all"]),
            ("delete_event", ["id": "x", "span": "forever"]),
        ]
        for (tool, args) in bad {
            let error = await failure(tool, args, on: fake)
            #expect(error?.code == .invalidInput, "\(tool) \(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func badDateMessageHasAnExample() async {
        let error = await failure("list_events", ["start": "12/11/2026", "end": "2026-11-13"], on: store())
        #expect(error?.message.contains("'start'") == true)
        #expect(error?.fix?.contains("2026-11-12T09:30:00+01:00") == true)
    }

    @Test func rangeOf366DaysIsAllowed() async throws {
        let fake = store()
        _ = try await run("list_events", ["start": "2027-01-01", "end": "2027-12-31"], on: fake)
        #expect(fake.read(\.calls).contains("events"))
    }

    @Test func dateOnlyEndIncludesTheWholeDay() async throws {
        let fake = store()
        _ = try await run("list_events", ["start": "2026-11-12", "end": "2026-11-12"], on: fake)
        let query = try #require(fake.read(\.eventsQuery))
        #expect(query.start == date("2026-11-12"))
        #expect(query.end == date("2026-11-13"))
    }

    // MARK: permissions

    @Test(arguments: [PermissionState.denied, .writeOnly, .restricted])
    func blockedPermissionGivesFix(_ state: PermissionState) async {
        let fake = store { $0.permission = state }
        let error = await failure("list_calendars", [:], on: fake)
        #expect(error?.code == .permissionDenied)
        #expect(error?.fix == Permission.calendars.fix(for: state))
        #expect(error?.fix?.isEmpty == false)
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func notDeterminedAsksOnceThenRuns() async throws {
        let fake = store { $0.permission = .notDetermined }
        _ = try await run("list_calendars", [:], on: fake)
        #expect(fake.read(\.calls) == ["request", "calendars"])
    }

    @Test func unansweredPromptGivesPermissionTimeout() async {
        let fake = store {
            $0.permission = .notDetermined
            $0.requestDelay = 5
        }
        let error = await failure("list_calendars", [:], on: fake, using: module(fake, permissionTimeout: 0.1))
        #expect(error?.code == .permissionTimeout)
        #expect(error?.fix?.isEmpty == false)
    }

    @Test func refusedPromptGivesPermissionDenied() async {
        let fake = store {
            $0.permission = .notDetermined
            $0.requestResult = false
        }
        let error = await failure("list_calendars", [:], on: fake)
        #expect(error?.code == .permissionDenied)
    }

    @Test func slowBackendGivesTimeout() async {
        let fake = store {
            $0.eventDelay = 5
            $0.events = [eventInfo("e1", "A", start: "2026-11-12T09:00:00Z", end: "2026-11-12T10:00:00Z")]
        }
        let error = await failure("get_event", ["id": "e1"], on: fake, using: module(fake, backendTimeout: 0.1))
        #expect(error?.code == .timeout)
    }

    // MARK: calendar names

    @Test func calendarMatchesByNameWithoutCaseAndById() async throws {
        let fake = store()
        _ = try await run(
            "list_events", ["start": "2026-11-12", "end": "2026-11-13", "calendar": "wORk"], on: fake)
        #expect(fake.read(\.eventsQuery)?.calendarIds == ["c1"])
        _ = try await run("list_events", ["start": "2026-11-12", "end": "2026-11-13", "calendar": "c2"], on: fake)
        #expect(fake.read(\.eventsQuery)?.calendarIds == ["c2"])
    }

    @Test func twoCalendarsWithTheSameNameAreAmbiguous() async {
        let fake = store { $0.calendars.append(calendarInfo("c9", "work")) }
        let error = await failure(
            "list_events", ["start": "2026-11-12", "end": "2026-11-13", "calendar": "Work"], on: fake)
        #expect(error?.code == .ambiguous)
        #expect(error?.message.contains("c1") == true && error?.message.contains("c9") == true)
    }

    @Test func unknownCalendarListsTheNames() async {
        let error = await failure(
            "create_event", ["title": "A", "start": "2026-11-12", "end": "2026-11-12", "calendar": "Nope"],
            on: store())
        #expect(error?.code == .notFound)
        #expect(error?.message.contains("'Home'") == true && error?.message.contains("'Work'") == true)
    }

    // MARK: read-only calendars

    @Test func writesToReadOnlyCalendarsAreRefused() async {
        let event = eventInfo(
            "h1", "Holiday", start: "2026-12-25T00:00:00Z", end: "2026-12-25T23:59:59Z", calendar: holidays)
        let fake = store { $0.events = [event] }
        let create = await failure(
            "create_event", ["title": "A", "start": "2026-11-12", "end": "2026-11-12", "calendar": "Holidays"],
            on: fake)
        let update = await failure("update_event", ["id": "h1", "title": "B"], on: fake)
        let delete = await failure("delete_event", ["id": "h1"], on: fake)
        #expect([create?.code, update?.code, delete?.code] == [.invalidInput, .invalidInput, .invalidInput])
        let calls = fake.read(\.calls)
        #expect(!calls.contains("create") && !calls.contains("update") && !calls.contains("delete"))
    }

    // MARK: recurring ids

    @Test func eventRefParsing() throws {
        #expect(try EventRef.parse("ABC-123") == EventRef(identifier: "ABC-123", occurrence: nil))
        let ref = try EventRef.parse("ABC-123@2026-11-12T09:00:00+01:00")
        #expect(ref == EventRef(identifier: "ABC-123", occurrence: date("2026-11-12T09:00:00+01:00")))
        // The part after the last @ counts only when it is a date with a time.
        #expect(try EventRef.parse("a@b.c").identifier == "a@b.c")
        #expect(try EventRef.parse("ABC@2026-11-12").occurrence == nil)
        #expect(try EventRef.parse(ref.string) == ref)
        #expect(throws: ToolError.self) { try EventRef.parse("  ") }
    }

    @Test func recurringIdAndSpanReachTheStore() async throws {
        let id = "R1@2026-11-19T09:00:00+01:00"
        let event = eventInfo(
            id, "Standup", start: "2026-11-19T09:00:00+01:00", end: "2026-11-19T09:15:00+01:00", recurring: true)
        let fake = store { $0.events = [event] }
        _ = try await run("update_event", ["id": .string(id), "title": "Sync", "span": "future"], on: fake)
        let update = try #require(fake.read(\.updated))
        #expect(update.ref == EventRef(identifier: "R1", occurrence: date("2026-11-19T09:00:00+01:00")))
        #expect(update.span == .future)
        #expect(update.patch.title == "Sync")
        #expect(update.patch.start == nil)

        _ = try await run("delete_event", ["id": .string(id)], on: fake)
        let deleted = try #require(fake.read(\.deleted))
        #expect(deleted.ref.occurrence == date("2026-11-19T09:00:00+01:00"))
        #expect(deleted.span == .this)
    }

    @Test func bareIdOfARecurringEventIsRefusedForChanges() async throws {
        let event = eventInfo(
            "R1", "Standup", start: "2026-11-19T09:00:00+01:00", end: "2026-11-19T09:15:00+01:00", recurring: true)
        let fake = store { $0.events = [event] }
        for (tool, args) in [
            ("update_event", ["id": "R1", "title": "Sync"] as [String: Value]), ("delete_event", ["id": "R1"]),
        ] {
            let error = await failure(tool, args, on: fake)
            #expect(error?.code == .invalidInput, "\(tool)")
            #expect(error?.message.contains("recurring event") == true, "\(tool)")
            #expect(error?.message.contains("@occurrence") == true, "\(tool)")
        }
        let calls = fake.read(\.calls)
        #expect(!calls.contains("update") && !calls.contains("delete"))
        // Reading it still works.
        _ = try await run("get_event", ["id": "R1"], on: fake)
    }

    @Test func missingEventIsNotFound() async {
        let error = await failure("get_event", ["id": "nope"], on: store())
        #expect(error?.code == .notFound)
    }

    // MARK: writes

    @Test func dateOnlyCreateMakesAnAllDayEvent() async throws {
        let fake = store()
        let output = try await run(
            "create_event", ["title": "Trip", "start": "2026-11-12", "end": "2026-11-14", "location": "Oslo"],
            on: fake)
        let created = try #require(fake.read(\.created))
        #expect(created.allDay)
        #expect(created.start == date("2026-11-12"))
        #expect(created.end == date("2026-11-15").addingTimeInterval(-1))
        #expect(created.calendarId == nil)
        #expect(created.location == "Oslo")
        #expect(output.text.hasPrefix("Created event: Trip"))
    }

    @Test func timedCreateKeepsTimesAndResolvesCalendar() async throws {
        let fake = store()
        _ = try await run(
            "create_event",
            [
                "title": "Call", "start": "2026-11-12T09:30:00+01:00", "end": "2026-11-12T10:00:00+01:00",
                "calendar": "home", "url": "https://example.com", "all_day": false,
            ], on: fake)
        let created = try #require(fake.read(\.created))
        #expect(!created.allDay)
        #expect(created.start == date("2026-11-12T08:30:00Z"))
        #expect(created.calendarId == "c2")
        #expect(created.url == "https://example.com")
    }

    @Test func updateChecksNewStartAgainstExistingEnd() async throws {
        let event = eventInfo("e1", "A", start: "2026-11-12T09:00:00Z", end: "2026-11-12T10:00:00Z")
        let fake = store { $0.events = [event] }
        let error = await failure("update_event", ["id": "e1", "start": "2026-11-12T11:00:00Z"], on: fake)
        #expect(error?.code == .invalidInput)
        #expect(fake.read(\.updated) == nil)

        _ = try await run(
            "update_event", ["id": "e1", "start": "2026-11-12T09:30:00Z", "notes": ""], on: fake)
        let patch = try #require(fake.read(\.updated)).patch
        #expect(patch.start == date("2026-11-12T09:30:00Z"))
        #expect(patch.end == date("2026-11-12T10:00:00Z"))
        #expect(patch.notes == "")
    }

    @Test func deleteReportsTheEvent() async throws {
        let event = eventInfo("e1", "Dentist", start: "2026-11-12T09:00:00Z", end: "2026-11-12T10:00:00Z")
        let fake = store { $0.events = [event] }
        let output = try await run("delete_event", ["id": "e1"], on: fake)
        #expect(output.text.contains("Dentist") && output.text.contains("create_event"))
        let root = try #require(output.structured?.objectValue)
        #expect(root["deleted"]?.stringValue == "e1")
        // The copy lets create_event put the event back.
        #expect(root["event"]?.objectValue?["title"]?.stringValue == "Dentist")
    }

    @Test func deletingAllLaterOccurrencesNeedsConfirm() async throws {
        let id = "R1@2026-11-19T09:00:00+01:00"
        let event = eventInfo(
            id, "Standup", start: "2026-11-19T09:00:00+01:00", end: "2026-11-19T09:15:00+01:00", recurring: true)
        let fake = store { $0.events = [event] }
        let output = try await run("delete_event", ["id": .string(id), "span": "future"], on: fake)
        #expect(fake.read(\.deleted) == nil)
        #expect(output.text.contains("Nothing deleted"))
        #expect(output.structured?.objectValue?["confirm_required"]?.boolValue == true)
        _ = try await run("delete_event", ["id": .string(id), "span": "future", "confirm": true], on: fake)
        #expect(fake.read(\.deleted)?.span == .future)
        // One occurrence needs no confirm.
        let single = store { $0.events = [event] }
        _ = try await run("delete_event", ["id": .string(id)], on: single)
        #expect(single.read(\.deleted)?.span == .this)
    }

    // MARK: reads

    @Test func listEventsSortsLimitsAndShapesOutput() async throws {
        let late = eventInfo(
            "e3", "Late", start: "2026-11-14T09:00:00Z", end: "2026-11-14T10:00:00Z", location: "Room 1")
        let early = eventInfo("e1", "Early", start: "2026-11-12T09:00:00Z", end: "2026-11-12T10:00:00Z")
        let mid = eventInfo(
            "e2", "Mid", start: "2026-11-13T00:00:00Z", end: "2026-11-13T23:59:59Z", allDay: true)
        let fake = store { $0.events = [late, early, mid] }
        let output = try await run(
            "list_events", ["start": "2026-11-12", "end": "2026-11-20", "limit": 2], on: fake)

        #expect(output.text.hasPrefix("Showing 2 of 3 events."))
        #expect(output.text.contains("id: e1") && output.text.contains("id: e2"))
        let root = try #require(output.structured?.objectValue)
        #expect(root["total"]?.intValue == 3)
        #expect(root["truncated"]?.boolValue == true)
        let events = try #require(root["events"]?.arrayValue)
        #expect(events.compactMap { $0.objectValue?["id"]?.stringValue } == ["e1", "e2"])
        let first = try #require(events.first?.objectValue)
        #expect(first["all_day"]?.boolValue == false)
        #expect(first["calendar_id"]?.stringValue == "c1")
        #expect(first["location"] == nil)
        // ISO 8601 with an offset (Z or +hh:mm).
        let start = try #require(first["start"]?.stringValue)
        #expect(start.wholeMatch(of: #/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)/#) != nil)
        #expect(ISODate.parse(start)?.date == date("2026-11-12T09:00:00Z"))
    }

    @Test func searchFindsTitleLocationAndNotesWithoutCase() async throws {
        let fake = store {
            $0.events = [
                eventInfo("e1", "Budget review", start: "2026-11-12T09:00:00Z", end: "2026-11-12T10:00:00Z"),
                eventInfo(
                    "e2", "Lunch", start: "2026-11-13T09:00:00Z", end: "2026-11-13T10:00:00Z", location: "BUDGET cafe"),
                eventInfo(
                    "e3", "Call", start: "2026-11-14T09:00:00Z", end: "2026-11-14T10:00:00Z", notes: "the budget"),
                eventInfo("e4", "Gym", start: "2026-11-15T09:00:00Z", end: "2026-11-15T10:00:00Z"),
            ]
        }
        let output = try await run("search_events", ["query": "budget"], on: fake)
        let ids = output.structured?.objectValue?["events"]?.arrayValue?.compactMap {
            $0.objectValue?["id"]?.stringValue
        }
        #expect(ids == ["e1", "e2", "e3"])
        // No range given: about 30 days back and 30 days ahead.
        let query = try #require(fake.read(\.eventsQuery))
        let span = query.end.timeIntervalSince(query.start)
        #expect(abs(span - 60 * 86_400) < 5)
    }

    @Test func listCalendarsShape() async throws {
        let output = try await run("list_calendars", [:], on: store())
        let calendars = try #require(output.structured?.objectValue?["calendars"]?.arrayValue)
        #expect(calendars.count == 3)
        #expect(calendars.compactMap { $0.objectValue?["title"]?.stringValue } == ["Holidays", "Home", "Work"])
        #expect(calendars.first?.objectValue?["writable"]?.boolValue == false)
        #expect(output.text.contains("Holidays | caldav | iCloud | read-only | id: c3"))
    }
}
