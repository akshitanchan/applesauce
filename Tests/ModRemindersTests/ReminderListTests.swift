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
}
