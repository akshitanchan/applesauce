import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModNotes

/// `update_note` and `create_folder` with a fake store.
@Suite struct NotesEditTests {
    static let noteID = "x-coredata://6E1D5C2A/ICNote/p123"

    static let before = NotesNote(
        id: noteID, name: "Shopping", folder: "Notes", account: "iCloud", created: nil, modified: nil,
        body: "Shopping\nmilk\neggs", truncated: false,
        html: "<div><h1>Shopping</h1></div><div>milk<br>eggs</div>")

    static let folders = [
        NotesFolder(id: "x-coredata://S/ICFolder/p1", name: "Notes", account: "iCloud", noteCount: 5),
        NotesFolder(id: "x-coredata://S/ICFolder/p2", name: "Work", account: "iCloud", noteCount: 2),
        NotesFolder(id: "x-coredata://S/ICFolder/p3", name: "Notes", account: "On My Mac", noteCount: 1),
    ]

    func store(_ edit: (inout FakeNotesStore.State) -> Void = { _ in }) -> FakeNotesStore {
        var state = FakeNotesStore.State()
        state.folders = Self.folders
        state.note = Self.before
        state.ref = NoteRef(id: Self.noteID, name: "Result", folder: "Notes", account: "iCloud")
        edit(&state)
        return FakeNotesStore(state)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeNotesStore) async throws -> ToolOutput {
        try await NotesModule(store: store).call(tool, Arguments(args))
    }

    func failure(_ tool: String, _ args: [String: Value], on store: FakeNotesStore) async -> ToolError? {
        do {
            _ = try await run(tool, args, on: store)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func object(_ output: ToolOutput) -> [String: Value] { output.structured?.objectValue ?? [:] }

    // MARK: update_note

    @Test func bodyReplacesTheWholeBodyAndKeepsTheTitleAsFirstLine() async throws {
        let fake = store()
        let output = try await run(
            "update_note", ["id": .string(Self.noteID), "body": "new <b>\nline & two"], on: fake)
        let replaced = try #require(fake.read(\.replaced))
        #expect(replaced.id == Self.noteID)
        #expect(replaced.html == "<div><h1>Shopping</h1></div><div>new &lt;b&gt;<br>line &amp; two</div>")
        // The old note was read first, with its HTML, and nothing else was called.
        #expect(fake.read(\.calls) == ["note", "replaceBody"])
        #expect(fake.read(\.noteRequest)?.includeHTML == true)
        let data = object(output)
        #expect(data["action"]?.stringValue == "update_note")
        #expect(data["previous_title"]?.stringValue == "Shopping")
        #expect(data["previous_body"]?.stringValue == "milk\neggs")
        #expect(data["previous_body_truncated"]?.boolValue == false)
        #expect(data["previous_html"]?.stringValue == Self.before.html)
        #expect(output.text.contains("previous_body") && output.text.contains("id: "))
    }

    @Test func titleAndBodyTogether() async throws {
        let fake = store()
        _ = try await run(
            "update_note", ["id": .string(Self.noteID), "title": " New & title ", "body": "text"], on: fake)
        #expect(fake.read(\.replaced)?.html == "<div><h1>New &amp; title</h1></div><div>text</div>")
    }

    @Test func titleAloneRenamesAndKeepsTheRest() async throws {
        let fake = store()
        let output = try await run("update_note", ["id": .string(Self.noteID), "title": "Groceries"], on: fake)
        #expect(fake.read(\.replaced)?.html == "<div><h1>Groceries</h1></div><div>milk<br>eggs</div>")
        #expect(output.text.contains("'Shopping' became 'Groceries'"))
        #expect(!output.text.contains("body was replaced"))
        #expect(object(output)["previous_title"]?.stringValue == "Shopping")
    }

    @Test func anEmptyBodyClearsTheBodyAndKeepsTheTitle() async throws {
        let fake = store()
        _ = try await run("update_note", ["id": .string(Self.noteID), "body": ""], on: fake)
        #expect(fake.read(\.replaced)?.html == "<div><h1>Shopping</h1></div>")
    }

    @Test func aRenameThatCannotFindTheTitleLineFailsBeforeTheWrite() async {
        let odd = NotesNote(
            id: Self.noteID, name: "Plain", folder: "Notes", account: "iCloud", created: nil, modified: nil,
            body: "Plain", truncated: false, html: "Plain text without blocks")
        let fake = store { $0.note = odd }
        let error = await failure("update_note", ["id": .string(Self.noteID), "title": "T"], on: fake)
        #expect(error?.code == .invalidInput && error?.fix?.contains("'body'") == true)
        #expect(fake.read(\.replaced) == nil)
    }

    @Test func aLockedNoteIsRefusedAndNothingIsWritten() async {
        let fake = store { $0.error = NotesScripts.lockedError() }
        let error = await failure("update_note", ["id": .string(Self.noteID), "body": "x"], on: fake)
        #expect(error?.code == .permissionDenied && error?.message.contains("locked") == true)
        #expect(fake.read(\.replaced) == nil)
    }

    @Test func aLongOldBodyIsFlaggedAndItsHTMLIsLeftOut() async throws {
        let long = NotesNote(
            id: Self.noteID, name: "Big", folder: "Notes", account: "iCloud", created: nil, modified: nil,
            body: "Big\n" + String(repeating: "a", count: 10), truncated: true,
            html: "<div><h1>Big</h1></div><div>" + String(repeating: "a", count: NotesScripts.bodyLimit) + "</div>")
        let fake = store { $0.note = long }
        let output = try await run("update_note", ["id": .string(Self.noteID), "body": "x"], on: fake)
        let data = object(output)
        #expect(data["previous_body_truncated"]?.boolValue == true)
        #expect(data["previous_html"] == nil)
        #expect(output.text.contains("cut at"))
    }

    @Test func updateNoteIsDestructiveAndWrites() throws {
        let spec = try #require(NotesModule.toolSpecs.first { $0.tool.name == "update_note" })
        #expect(spec.isWrite && spec.tool.annotations.destructiveHint == true)
        #expect(spec.tool.description?.contains("previous_body") == true)
        let required = spec.tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["id"])
        // There is no separate rename tool.
        #expect(!NotesModule.toolSpecs.contains { $0.tool.name == "rename_note" })
    }

    @Test func storeErrorsOnUpdatePassThrough() async {
        let missing = store { $0.note = nil }
        #expect(
            await failure("update_note", ["id": .string(Self.noteID), "title": "T"], on: missing)?.code == .notFound)
        let appError = ToolError(.appNotRunning, "Notes is not running.", fix: "Open Notes, then try again.")
        let down = store { $0.error = appError }
        #expect(await failure("update_note", ["id": .string(Self.noteID), "title": "T"], on: down) == appError)
    }

    // MARK: create_folder

    @Test func topLevelFolderGoesToTheDefaultAccountWithoutLookups() async throws {
        let fake = store()
        let output = try await run("create_folder", ["name": "  Recipes "], on: fake)
        let created = try #require(fake.read(\.createdFolder))
        #expect(created.name == "Recipes" && created.parentId == nil && created.account == nil)
        // No folder list was needed.
        #expect(fake.read(\.calls) == ["createFolder"])
        #expect(output.text.contains("Created folder 'New'") && output.text.contains("id: x-coredata://A/ICFolder/p9"))
        let data = object(output)
        #expect(data["action"]?.stringValue == "create_folder")
        #expect(data["folder"]?.objectValue?["id"]?.stringValue == "x-coredata://A/ICFolder/p9")
        #expect(data["parent"] == nil)
    }

    @Test func accountIsResolvedIgnoringCase() async throws {
        let fake = store()
        _ = try await run("create_folder", ["name": "A", "account": "on my mac"], on: fake)
        #expect(fake.read(\.createdFolder)?.account == "On My Mac")
        let error = await failure("create_folder", ["name": "A", "account": "Nope"], on: fake)
        #expect(error?.code == .notFound)
    }

    @Test func parentIsResolvedByNameOrId() async throws {
        let fake = store()
        let output = try await run("create_folder", ["name": "Sub", "parent": "work"], on: fake)
        #expect(
            fake.read(\.createdFolder)?.parentId == "x-coredata://S/ICFolder/p2"
                && fake.read(\.createdFolder)?.account == "iCloud")
        #expect(output.text.contains("inside 'Work'") && object(output)["parent"]?.stringValue == "Work")
        _ = try await run("create_folder", ["name": "Sub", "parent": "x-coredata://S/ICFolder/p3"], on: fake)
        #expect(fake.read(\.createdFolder)?.account == "On My Mac")
        // Two folders have the name: the account decides, or the call is ambiguous.
        let ambiguous = await failure("create_folder", ["name": "Sub", "parent": "Notes"], on: fake)
        #expect(ambiguous?.code == .ambiguous)
        _ = try await run("create_folder", ["name": "Sub", "parent": "Notes", "account": "iCloud"], on: fake)
        #expect(fake.read(\.createdFolder)?.parentId == "x-coredata://S/ICFolder/p1")
        let missing = await failure("create_folder", ["name": "Sub", "parent": "Nope"], on: fake)
        #expect(missing?.code == .notFound)
    }

    @Test func aParentFromAnotherAccountIsNotFound() async {
        let fake = store()
        let error = await failure(
            "create_folder", ["name": "Sub", "parent": "x-coredata://S/ICFolder/p3", "account": "iCloud"], on: fake)
        #expect(error?.code == .notFound)
        #expect(fake.read(\.createdFolder) == nil)
    }

    @Test func aDuplicateNameIsRefusedByTheStore() async {
        let duplicate = NotesScripts.scriptError(
            ToolError(.internalError, "execution error: A folder named 'Work' is already there. (1007)"))
        let fake = store { $0.error = duplicate }
        let error = await failure("create_folder", ["name": "Work"], on: fake)
        #expect(error?.code == .invalidInput && error?.message.contains("already there") == true)
        #expect(error?.fix?.isEmpty == false)
    }

    @Test func createFolderWritesButIsNotDestructive() throws {
        let spec = try #require(NotesModule.toolSpecs.first { $0.tool.name == "create_folder" })
        #expect(spec.isWrite && spec.tool.annotations.destructiveHint == false)
        let required = spec.tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["name"])
    }
}
