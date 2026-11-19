import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModReminders

@Suite struct RemindersModuleTests {
    let inbox = listInfo("l1", "Inbox")
    let shopping = listInfo("l2", "Shopping")
    let shared = listInfo("l3", "Shared", writable: false)

    func store(_ edit: (inout FakeRemindersStore.State) -> Void = { _ in }) -> FakeRemindersStore {
        var state = FakeRemindersStore.State()
        state.lists = [inbox, shopping, shared]
        edit(&state)
        return FakeRemindersStore(state)
    }

    func module(_ store: FakeRemindersStore, permissionTimeout: Double = 120, backendTimeout: Double = 30)
        -> RemindersModule
    {
        RemindersModule(store: store, permissionTimeout: permissionTimeout, backendTimeout: backendTimeout)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeRemindersStore) async throws -> ToolOutput {
        try await module(store).call(tool, Arguments(args))
    }

    func failure(
        _ tool: String, _ args: [String: Value], on store: FakeRemindersStore, using module: RemindersModule? = nil
    ) async -> ToolError? {
        do {
            _ = try await (module ?? self.module(store)).call(tool, Arguments(args))
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func ids(_ output: ToolOutput) -> [String]? {
        output.structured?.objectValue?["reminders"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }
    }

    // MARK: tools

    @Test func toolNamesAndFlags() {
        let tools = module(store()).tools
        #expect(
            tools.map(\.tool.name) == [
                "list_reminder_lists", "create_reminder_list", "list_reminders", "search_reminders", "get_reminder",
                "create_reminder", "update_reminder", "complete_reminder", "delete_reminder", "delete_reminder_list",
            ])
        let writes = tools.filter(\.isWrite).map(\.tool.name)
        #expect(
            writes == [
                "create_reminder_list", "create_reminder", "update_reminder", "complete_reminder", "delete_reminder",
                "delete_reminder_list",
            ])
        #expect(tools.last?.tool.annotations.destructiveHint == true)
        #expect(tools.allSatisfy { !$0.tool.description!.isEmpty })
    }

    @Test func readOnlyRegistryHidesWriteTools() async throws {
        let config = try Config.parse(arguments: ["--read-only"], environment: [:])
        let registry = try Registry(available: [module(store())], config: config)
        #expect(
            registry.tools.map(\.name) == ["list_reminder_lists", "list_reminders", "search_reminders", "get_reminder"])
        let result = await registry.call("delete_reminder", arguments: ["id": "x"])
        #expect(result.isError == true)
    }

    // MARK: input checks

    @Test func badInputNeverReachesTheStore() async {
        let fake = store { $0.permission = .notDetermined }
        let bad: [(String, [String: Value])] = [
            ("list_reminders", ["filter": "done"]),
            ("list_reminders", ["due_start": "soon"]),
            ("list_reminders", ["due_start": "2026-11-13", "due_end": "2026-11-12"]),
            ("list_reminders", ["limit": 0]),
            ("list_reminders", ["limit": 501]),
            ("search_reminders", ["query": ""]),
            ("search_reminders", ["query": "x", "limit": 1000]),
            ("get_reminder", [:]),
            ("create_reminder", ["title": ""]),
            ("create_reminder", ["title": "A", "due": "tomorrow"]),
            ("create_reminder", ["title": "A", "priority": "urgent"]),
            ("create_reminder", ["title": "A", "url": "not a url"]),
            ("update_reminder", ["id": "x"]),
            ("update_reminder", ["id": "x", "due": "2026-02-30"]),
            ("update_reminder", ["id": "x", "title": ""]),
            ("complete_reminder", ["id": "x", "completed": "yes"]),
            ("delete_reminder", ["id": ""]),
        ]
        for (tool, args) in bad {
            let error = await failure(tool, args, on: fake)
            #expect(error?.code == .invalidInput, "\(tool) \(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func badDateMessageHasAnExample() async {
        let error = await failure("create_reminder", ["title": "A", "due": "12/11/2026"], on: store())
        #expect(error?.message.contains("'due'") == true)
        #expect(error?.fix?.contains("2026-11-12T09:30:00+01:00") == true)
    }

    // MARK: permissions

    @Test(arguments: [PermissionState.denied, .writeOnly, .restricted])
    func blockedPermissionGivesFix(_ state: PermissionState) async {
        let fake = store { $0.permission = state }
        let error = await failure("list_reminder_lists", [:], on: fake)
        #expect(error?.code == .permissionDenied)
        #expect(error?.fix == Permission.reminders.fix(for: state))
        #expect(error?.fix?.isEmpty == false)
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func notDeterminedAsksOnceThenRuns() async throws {
        let fake = store { $0.permission = .notDetermined }
        _ = try await run("list_reminder_lists", [:], on: fake)
        #expect(fake.read(\.calls) == ["request", "lists"])
    }

    @Test func unansweredPromptGivesPermissionTimeout() async {
        let fake = store {
            $0.permission = .notDetermined
            $0.requestDelay = 5
        }
        let error = await failure("list_reminder_lists", [:], on: fake, using: module(fake, permissionTimeout: 0.1))
        #expect(error?.code == .permissionTimeout)
        #expect(error?.fix?.isEmpty == false)
    }

    @Test func refusedPromptGivesPermissionDenied() async {
        let fake = store {
            $0.permission = .notDetermined
            $0.requestResult = false
        }
        let error = await failure("list_reminder_lists", [:], on: fake)
        #expect(error?.code == .permissionDenied)
    }

    @Test func slowBackendGivesTimeout() async {
        let fake = store {
            $0.reminderDelay = 5
            $0.reminders = [makeReminder("r1", "A")]
        }
        let error = await failure("get_reminder", ["id": "r1"], on: fake, using: module(fake, backendTimeout: 0.1))
        #expect(error?.code == .timeout)
    }

    // MARK: list names

    @Test func listMatchesByNameWithoutCaseAndById() async throws {
        let fake = store()
        _ = try await run("list_reminders", ["list": "sHoppING"], on: fake)
        #expect(fake.read(\.listQuery) == ["l2"])
        _ = try await run("list_reminders", ["list": "l1"], on: fake)
        #expect(fake.read(\.listQuery) == ["l1"])
    }

    @Test func twoListsWithTheSameNameAreAmbiguous() async {
        let fake = store { $0.lists.append(listInfo("l9", "inbox")) }
        let error = await failure("list_reminders", ["list": "Inbox"], on: fake)
        #expect(error?.code == .ambiguous)
        #expect(error?.message.contains("l1") == true && error?.message.contains("l9") == true)
    }

    @Test func unknownListListsTheNames() async {
        let error = await failure("create_reminder", ["title": "A", "list": "Nope"], on: store())
        #expect(error?.code == .notFound)
        #expect(error?.message.contains("'Inbox'") == true && error?.message.contains("'Shopping'") == true)
    }

    // MARK: read-only lists

    @Test func writesToReadOnlyListsAreRefused() async {
        let item = makeReminder("r1", "Milk", list: shared)
        let fake = store { $0.reminders = [item] }
        let results = [
            await failure("create_reminder", ["title": "A", "list": "Shared"], on: fake),
            await failure("update_reminder", ["id": "r1", "title": "B"], on: fake),
            await failure("complete_reminder", ["id": "r1"], on: fake),
            await failure("delete_reminder", ["id": "r1"], on: fake),
        ]
        #expect(results.map { $0?.code } == [.invalidInput, .invalidInput, .invalidInput, .invalidInput])
        let calls = fake.read(\.calls)
        #expect(!calls.contains { ["create", "update", "complete", "delete"].contains($0) })
    }

    // MARK: reads

    @Test func listFiltersByCompletionAndDueRange() async throws {
        let fake = store {
            $0.reminders = [
                makeReminder("open-late", "B", due: due("2026-11-20")),
                makeReminder("open-soon", "A", due: due("2026-11-12T09:00:00Z")),
                makeReminder("open-none", "C"),
                makeReminder("done", "D", due: due("2026-11-13"), completed: true),
            ]
        }
        // Default: incomplete only, due date first, no date last.
        #expect(ids(try await run("list_reminders", [:], on: fake)) == ["open-soon", "open-late", "open-none"])
        #expect(ids(try await run("list_reminders", ["filter": "completed"], on: fake)) == ["done"])
        #expect(
            ids(try await run("list_reminders", ["filter": "all"], on: fake))
                == ["open-soon", "open-late", "open-none", "done"])
        // A date-only due_end includes that day. Reminders without a due date drop out of a range.
        let range = try await run(
            "list_reminders", ["filter": "all", "due_start": "2026-11-13", "due_end": "2026-11-20"], on: fake)
        #expect(ids(range) == ["open-late", "done"])
        let onlyEnd = try await run("list_reminders", ["due_end": "2026-11-12"], on: fake)
        #expect(ids(onlyEnd) == ["open-soon"])
    }

    @Test func listSortsLimitsAndShapesOutput() async throws {
        let fake = store {
            $0.reminders = [
                makeReminder("r2", "Two", due: due("2026-11-14"), priority: .high),
                makeReminder("r1", "One", due: due("2026-11-12T09:30:00+01:00"), notes: "note", list: shopping),
                makeReminder("r3", "Three"),
            ]
        }
        let output = try await run("list_reminders", ["limit": 2], on: fake)
        #expect(output.text.hasPrefix("Showing 2 of 3 reminders."))
        // Due dates show in the local time zone.
        let oneDue = ISODate.string(due("2026-11-12T09:30:00+01:00").date)
        #expect(output.text.contains("[ ] One | due \(oneDue) | Shopping | id: r1"))
        #expect(output.text.contains("priority high"))
        let root = try #require(output.structured?.objectValue)
        #expect(root["total"]?.intValue == 3)
        #expect(root["truncated"]?.boolValue == true)
        let first = try #require(root["reminders"]?.arrayValue?.first?.objectValue)
        #expect(first["id"]?.stringValue == "r1")
        #expect(first["list_id"]?.stringValue == "l2")
        #expect(first["due_date_only"]?.boolValue == false)
        #expect(first["priority"]?.stringValue == "none")
        #expect(first["completed"]?.boolValue == false)
        #expect(first["url"] == nil)
        let text = try #require(first["due"]?.stringValue)
        #expect(text.wholeMatch(of: #/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)/#) != nil)
        #expect(ISODate.parse(text)?.date == date("2026-11-12T09:30:00+01:00"))
    }

    @Test func searchFindsTitleAndNotesIncludingCompleted() async throws {
        let fake = store {
            $0.reminders = [
                makeReminder("r1", "Buy MILK"),
                makeReminder("r2", "Call", notes: "ask about milk", completed: true),
                makeReminder("r3", "Gym"),
            ]
        }
        let output = try await run("search_reminders", ["query": "milk"], on: fake)
        #expect(ids(output) == ["r1", "r2"])
    }

    @Test func listListsShape() async throws {
        let output = try await run("list_reminder_lists", [:], on: store())
        let lists = try #require(output.structured?.objectValue?["lists"]?.arrayValue)
        #expect(lists.compactMap { $0.objectValue?["title"]?.stringValue } == ["Inbox", "Shared", "Shopping"])
        #expect(lists[1].objectValue?["writable"]?.boolValue == false)
        #expect(output.text.contains("Shared | iCloud | read-only | id: l3"))
    }

    @Test func missingReminderIsNotFound() async {
        let error = await failure("get_reminder", ["id": "nope"], on: store())
        #expect(error?.code == .notFound)
    }

    // MARK: writes

    @Test func createPassesAllFields() async throws {
        let fake = store()
        let output = try await run(
            "create_reminder",
            [
                "title": "Milk", "list": "shopping", "due": "2026-11-12", "notes": "2 litres",
                "priority": "High", "url": "https://example.com",
            ], on: fake)
        let created = try #require(fake.read(\.created))
        #expect(created.listId == "l2")
        #expect(created.due == due("2026-11-12"))
        #expect(created.due?.dateOnly == true)
        #expect(created.priority == .high)
        #expect(created.notes == "2 litres")
        #expect(created.url == "https://example.com")
        #expect(output.text.hasPrefix("Created reminder: [ ] Milk"))
    }

    @Test func createWithTimeKeepsTheTimeAndDefaultList() async throws {
        let fake = store()
        _ = try await run("create_reminder", ["title": "Call", "due": "2026-11-12T09:30:00+01:00"], on: fake)
        let created = try #require(fake.read(\.created))
        #expect(created.listId == nil)
        #expect(created.due == ReminderDue(date: date("2026-11-12T08:30:00Z"), dateOnly: false))
        #expect(created.priority == .none)
    }

    @Test func updateCanClearDueAndNotes() async throws {
        let fake = store { $0.reminders = [makeReminder("r1", "A", due: due("2026-11-12"))] }
        _ = try await run("update_reminder", ["id": "r1", "due": "", "notes": ""], on: fake)
        let patch = try #require(fake.read(\.updated)).patch
        #expect(patch.due == .clear)
        #expect(patch.notes == "")
        #expect(patch.title == nil)

        _ = try await run("update_reminder", ["id": "r1", "due": "2026-12-01T08:00:00Z", "priority": "low"], on: fake)
        let next = try #require(fake.read(\.updated)).patch
        #expect(next.due == .set(ReminderDue(date: date("2026-12-01T08:00:00Z"), dateOnly: false)))
        #expect(next.priority == .low)
    }

    @Test func completeDefaultsToTrueAndCanReopen() async throws {
        let fake = store { $0.reminders = [makeReminder("r1", "A")] }
        let done = try await run("complete_reminder", ["id": "r1"], on: fake)
        #expect(fake.read(\.completed)?.value == true)
        #expect(done.text.hasPrefix("Completed reminder"))
        let reopened = try await run("complete_reminder", ["id": "r1", "completed": false], on: fake)
        #expect(fake.read(\.completed)?.value == false)
        #expect(reopened.text.hasPrefix("Reopened reminder"))
    }

    @Test func deleteReportsTheReminder() async throws {
        let fake = store { $0.reminders = [makeReminder("r1", "Milk")] }
        let output = try await run("delete_reminder", ["id": "r1"], on: fake)
        #expect(fake.read(\.deleted) == "r1")
        #expect(output.text.contains("Milk") && output.text.contains("create_reminder"))
        #expect(output.structured?.objectValue?["deleted"]?.stringValue == "r1")
        #expect(output.structured?.objectValue?["reminder"]?.objectValue?["title"]?.stringValue == "Milk")
    }
}
