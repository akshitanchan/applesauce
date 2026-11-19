import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModReminders

@Suite struct ReminderListTests {
    let inbox = listInfo("l1", "Inbox")
    let shopping = listInfo("l2", "Shopping")
    let shared = listInfo("l3", "Shared", writable: false)

    func store(_ edit: (inout FakeRemindersStore.State) -> Void = { _ in }) -> FakeRemindersStore {
        var state = FakeRemindersStore.State()
        state.lists = [inbox, shopping, shared]
        state.sources = [
            ReminderSourceInfo(id: "s1", title: "iCloud"), ReminderSourceInfo(id: "s2", title: "On My Mac"),
        ]
        edit(&state)
        return FakeRemindersStore(state)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeRemindersStore) async throws -> ToolOutput {
        try await RemindersModule(store: store).call(tool, Arguments(args))
    }

    func failure(_ tool: String, _ args: [String: Value], on store: FakeRemindersStore) async -> ToolError? {
        do {
            _ = try await run(tool, args, on: store)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    // MARK: create_reminder_list

    @Test func badListInputNeverReachesTheStore() async {
        let fake = store { $0.permission = .notDetermined }
        for args: [String: Value] in [[:], ["name": ""], ["name": "   "], ["name": 5], ["name": "A", "source": 1]] {
            let error = await failure("create_reminder_list", args, on: fake)
            #expect(error?.code == .invalidInput, "\(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func createsAListInTheDefaultAccount() async throws {
        let fake = store()
        let output = try await run("create_reminder_list", ["name": "  Garden "], on: fake)
        let created = try #require(fake.read(\.createdList))
        #expect(created.name == "Garden")
        #expect(created.sourceId == nil)
        #expect(output.text.contains("Created reminder list: Garden"))
        #expect(output.structured?.objectValue?["id"]?.stringValue == "NEWLIST")
    }

    @Test func createsAListInANamedAccount() async throws {
        let fake = store()
        _ = try await run("create_reminder_list", ["name": "Garden", "source": "on my mac"], on: fake)
        #expect(fake.read(\.createdList)?.sourceId == "s2")
        let error = await failure("create_reminder_list", ["name": "Garden", "source": "Work"], on: fake)
        #expect(error?.code == .notFound)
    }

    @Test func duplicateNameIsRefusedWithoutCase() async {
        let fake = store()
        let error = await failure("create_reminder_list", ["name": "shopping"], on: fake)
        #expect(error?.code == .invalidInput)
        #expect(error?.message.contains("already exists") == true)
        #expect(error?.message.contains("l2") == true)
        #expect(fake.read(\.createdList) == nil)
    }

    // MARK: update_reminder list

    @Test func updateMovesToAnotherListByNameOrId() async throws {
        let reminder = makeReminder("r1", "Milk", list: inbox)
        let fake = store { $0.reminders = [reminder] }
        _ = try await run("update_reminder", ["id": "r1", "list": "shopping"], on: fake)
        #expect(fake.read(\.updated)?.patch.listId == "l2")
        #expect(fake.read(\.updated)?.patch.title == nil)
        _ = try await run("update_reminder", ["id": "r1", "list": "l1", "title": "Oat milk"], on: fake)
        #expect(fake.read(\.updated)?.patch.listId == "l1")
        #expect(fake.read(\.updated)?.patch.title == "Oat milk")
    }

    @Test func moveToReadOnlyOrUnknownListIsRefused() async {
        let reminder = makeReminder("r1", "Milk", list: inbox)
        let fake = store { $0.reminders = [reminder] }
        let readOnly = await failure("update_reminder", ["id": "r1", "list": "Shared"], on: fake)
        #expect(readOnly?.code == .invalidInput)
        let unknown = await failure("update_reminder", ["id": "r1", "list": "Nope"], on: fake)
        #expect(unknown?.code == .notFound)
        #expect(fake.read(\.updated) == nil)
    }

    @Test func createReminderDescriptionStatesNoSubtasksOrTags() throws {
        let spec = try #require(RemindersModule.toolSpecs.first { $0.tool.name == "create_reminder" })
        #expect(spec.tool.description?.contains("Subtasks and tags are not supported") == true)
    }

    // MARK: delete_reminder_list

    func listStore(_ reminders: [ReminderInfo] = []) -> FakeRemindersStore {
        store {
            $0.lists = [listInfo("l1", "Inbox", isDefault: true), self.shopping, self.shared]
            $0.reminders = reminders
        }
    }

    @Test func deleteListBadInputNeverReachesTheStore() async {
        let fake = store { $0.permission = .notDetermined }
        for args: [String: Value] in [[:], ["list": 5], ["list": "Shopping", "confirm": "yes"]] {
            let error = await failure("delete_reminder_list", args, on: fake)
            #expect(error?.code == .invalidInput, "\(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func deleteListNeedsConfirmEvenWhenEmpty() async throws {
        let fake = listStore()
        for confirm: Value? in [nil, false] {
            var args: [String: Value] = ["list": "shopping"]
            if let confirm { args["confirm"] = confirm }
            let output = try await run("delete_reminder_list", args, on: fake)
            #expect(output.structured?.objectValue?["confirm_required"]?.boolValue == true)
            #expect(output.structured?.objectValue?["list"]?.objectValue?["id"]?.stringValue == "l2")
            #expect(output.text.hasPrefix("Nothing deleted."))
        }
        #expect(fake.read(\.deletedList) == nil)
    }

    @Test func deleteListRemovesAnEmptyListAndReturnsACopy() async throws {
        let fake = listStore()
        let output = try await run("delete_reminder_list", ["list": "l2", "confirm": true], on: fake)
        #expect(fake.read(\.deletedList) == "l2")
        let object = try #require(output.structured?.objectValue)
        #expect(object["deleted"]?.stringValue == "l2")
        #expect(object["list"]?.objectValue?["title"]?.stringValue == "Shopping")
        #expect(object["reminder_count"]?.intValue == 0)
        #expect(output.text.contains("create_reminder_list"))
    }

    @Test func deleteListRefusesAListWithRemindersOfAnyState() async {
        let open = makeReminder("r1", "Milk", list: shopping)
        let done = makeReminder("r2", "Eggs", completed: true, list: shopping)
        for reminders in [[open], [done], [open, done]] {
            let fake = listStore(reminders)
            let error = await failure("delete_reminder_list", ["list": "Shopping", "confirm": true], on: fake)
            #expect(error?.code == .invalidInput)
            #expect(error?.message.contains("has \(reminders.count) reminders") == true)
            #expect(error?.message.contains("Nothing was deleted") == true)
            #expect(fake.read(\.deletedList) == nil)
        }
        let fake = listStore([open, done])
        let error = await failure("delete_reminder_list", ["list": "Shopping"], on: fake)
        #expect(error?.message.contains("1 not completed, 1 completed") == true)
    }

    @Test func deleteListIgnoresRemindersOfOtherLists() async throws {
        let other = makeReminder("r1", "Stamps", list: inbox)
        let fake = listStore([other])
        _ = try await run("delete_reminder_list", ["list": "Shopping", "confirm": true], on: fake)
        #expect(fake.read(\.deletedList) == "l2")
    }

    @Test func deleteListRefusesTheDefaultReadOnlyAndUnknownLists() async {
        let fake = listStore()
        let byName = await failure("delete_reminder_list", ["list": "inbox", "confirm": true], on: fake)
        #expect(byName?.code == .invalidInput)
        #expect(byName?.message.contains("default list") == true)
        let readOnly = await failure("delete_reminder_list", ["list": "Shared", "confirm": true], on: fake)
        #expect(readOnly?.code == .invalidInput)
        let unknown = await failure("delete_reminder_list", ["list": "Nope", "confirm": true], on: fake)
        #expect(unknown?.code == .notFound)
        #expect(fake.read(\.deletedList) == nil)
        #expect(!fake.read(\.calls).contains("reminders"))
    }

    @Test func deleteListIsDestructive() throws {
        let spec = try #require(RemindersModule.toolSpecs.first { $0.tool.name == "delete_reminder_list" })
        #expect(spec.isWrite)
        #expect(spec.tool.annotations.destructiveHint == true)
    }
}
