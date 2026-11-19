import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModNotes

@Suite struct NotesModuleTests {
    static let noteID = "x-coredata://6E1D5C2A/ICNote/p123"
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static let folders = [
        NotesFolder(id: "x-coredata://S/ICFolder/p1", name: "Notes", account: "iCloud", noteCount: 5),
        NotesFolder(id: "x-coredata://S/ICFolder/p2", name: "Work", account: "iCloud", noteCount: 2),
        NotesFolder(id: "x-coredata://S/ICFolder/p3", name: "Notes", account: "On My Mac", noteCount: 1),
        NotesFolder(id: "x-coredata://S/ICFolder/p4", name: "Ideas", account: "On My Mac", noteCount: nil),
    ]

    static let summary = NoteSummary(
        id: noteID, name: "Shopping", folder: "Notes", account: "iCloud", modified: date, locked: false,
        snippet: "milk, eggs")

    static let note = NotesNote(
        id: noteID, name: "Shopping", folder: "Notes", account: "iCloud", created: date, modified: date,
        body: "Shopping\nmilk", truncated: false, html: nil)

    func store(_ edit: (inout FakeNotesStore.State) -> Void = { _ in }) -> FakeNotesStore {
        var state = FakeNotesStore.State()
        state.folders = Self.folders
        state.page = NotesSearchPage(items: [Self.summary], truncated: false)
        state.note = Self.note
        edit(&state)
        return FakeNotesStore(state)
    }

    func module(_ store: FakeNotesStore, backendTimeout: Double = 60, writeTimeout: Double = 30) -> NotesModule {
        NotesModule(store: store, backendTimeout: backendTimeout, writeTimeout: writeTimeout)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeNotesStore) async throws -> ToolOutput {
        try await module(store).call(tool, Arguments(args))
    }

    func failure(
        _ tool: String, _ args: [String: Value], on store: FakeNotesStore, using module: NotesModule? = nil
    ) async -> ToolError? {
        do {
            _ = try await (module ?? self.module(store)).call(tool, Arguments(args))
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func object(_ output: ToolOutput) -> [String: Value] { output.structured?.objectValue ?? [:] }

    // MARK: tools

    @Test func toolNamesFlagsAndPermissions() {
        let notes = module(store())
        #expect(
            notes.tools.map(\.tool.name) == [
                "list_folders", "search_notes", "get_note", "get_note_attachment", "create_note", "append_to_note",
                "update_note", "create_folder", "move_note", "delete_note", "delete_folder",
            ])
        #expect(
            notes.tools.filter(\.isWrite).map(\.tool.name) == [
                "get_note_attachment", "create_note", "append_to_note", "update_note", "create_folder", "move_note",
                "delete_note", "delete_folder",
            ])
        #expect(
            notes.tools.filter { $0.tool.annotations.destructiveHint == true }.map(\.tool.name) == [
                "update_note", "delete_note", "delete_folder",
            ])
        #expect(notes.name == "notes")
        #expect(notes.permissions == [.automationNotes])
    }

    @Test func readOnlyRegistryHidesWriteTools() async throws {
        let config = try Config.parse(arguments: ["--read-only"], environment: [:])
        let fake = store()
        let registry = try Registry(available: [module(fake)], config: config)
        #expect(registry.tools.map(\.name) == ["list_folders", "search_notes", "get_note"])
        for tool in [
            "create_note", "append_to_note", "update_note", "create_folder", "move_note", "delete_note",
            "delete_folder",
        ] {
            let result = await registry.call(
                tool,
                arguments: [
                    "id": .string(Self.noteID), "title": "t", "text": "t", "folder": "Work", "name": "n",
                ])
            #expect(result.isError == true, "\(tool)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    // MARK: input checks

    @Test func badInputNeverReachesTheStore() async {
        let fake = store()
        let id = Value.string(Self.noteID)
        let bad: [(String, [String: Value])] = [
            ("list_folders", ["account": ""]),
            ("list_folders", ["account": 3]),
            ("search_notes", [:]),
            ("search_notes", ["query": ""]),
            ("search_notes", ["query": "   "]),
            ("search_notes", ["query": 5]),
            ("search_notes", ["query": "a", "limit": 0]),
            ("search_notes", ["query": "a", "limit": 201]),
            ("search_notes", ["query": "a", "folder": ""]),
            ("search_notes", ["query": "a\0b"]),
            ("get_note", [:]),
            ("get_note", ["id": "abc"]),
            ("get_note", ["id": "x-coredata://a b"]),
            ("get_note", ["id": "1; do shell script"]),
            ("get_note", ["id": id, "include_html": "yes"]),
            ("create_note", [:]),
            ("create_note", ["title": ""]),
            ("create_note", ["title": "  "]),
            ("create_note", ["title": "t", "body": 5]),
            ("create_note", ["title": "t", "body": "a\0b"]),
            ("create_note", ["title": "t", "folder": ""]),
            ("append_to_note", ["id": id]),
            ("append_to_note", ["id": id, "text": ""]),
            ("append_to_note", ["id": id, "text": " \n "]),
            ("append_to_note", ["id": "nope", "text": "x"]),
            ("move_note", ["id": id]),
            ("move_note", ["folder": "Work"]),
            ("move_note", ["id": "nope", "folder": "Work"]),
            ("delete_note", [:]),
            ("delete_note", ["id": "123"]),
            ("update_note", [:]),
            ("update_note", ["id": id]),
            ("update_note", ["title": "x"]),
            ("update_note", ["id": "nope", "title": "x"]),
            ("update_note", ["id": id, "title": ""]),
            ("update_note", ["id": id, "title": "  "]),
            ("update_note", ["id": id, "title": 5]),
            ("update_note", ["id": id, "body": 5]),
            ("update_note", ["id": id, "body": "a\0b"]),
            ("update_note", ["id": id, "title": "a\0b"]),
            ("create_folder", [:]),
            ("create_folder", ["name": ""]),
            ("create_folder", ["name": "a\nb"]),
            ("create_folder", ["name": 5]),
            ("create_folder", ["name": "a\0b"]),
            ("create_folder", ["name": "x", "parent": ""]),
            ("create_folder", ["name": "x", "account": ""]),
        ]
        for (tool, args) in bad {
            let error = await failure(tool, args, on: fake)
            #expect(error?.code == .invalidInput, "\(tool) \(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func textTooLongIsRejectedBeforeTheStore() async {
        let fake = store()
        let long = String(repeating: "\"", count: 100_000)  // six bytes each after escaping
        let create = await failure("create_note", ["title": "t", "body": .string(long)], on: fake)
        #expect(create?.code == .invalidInput)
        let append = await failure("append_to_note", ["id": .string(Self.noteID), "text": .string(long)], on: fake)
        #expect(append?.code == .invalidInput)
        let update = await failure("update_note", ["id": .string(Self.noteID), "body": .string(long)], on: fake)
        #expect(update?.code == .invalidInput)
        #expect(fake.read(\.calls).isEmpty)
    }

    // MARK: list_folders

    @Test func listFolders() async throws {
        let fake = store()
        let all = try await run("list_folders", [:], on: fake)
        #expect(all.text.hasPrefix("4 folders."))
        let list = object(all)["folders"]?.arrayValue ?? []
        #expect(list.count == 4 && object(all)["count"]?.intValue == 4)
        let first = list.first?.objectValue
        #expect(first?["id"]?.stringValue == "x-coredata://S/ICFolder/p1")
        #expect(first?["note_count"]?.intValue == 5 && first?["account"]?.stringValue == "iCloud")
        #expect(list.last?.objectValue?["note_count"] == nil)

        let one = try await run("list_folders", ["account": "on my mac"], on: fake)
        #expect(object(one)["folders"]?.arrayValue?.count == 2)
        let error = await failure("list_folders", ["account": "Nope"], on: fake)
        #expect(error?.code == .notFound && error?.message.contains("'iCloud'") == true)
    }

    // MARK: search_notes

    @Test func searchWithoutFiltersNeverListsFolders() async throws {
        let fake = store()
        let output = try await run("search_notes", ["query": " milk "], on: fake)
        #expect(fake.read(\.calls) == ["search"])
        let query = try #require(fake.read(\.query))
        #expect(query == NotesSearchQuery(text: "milk", folderId: nil, account: nil, limit: 25))
        let notes = object(output)["notes"]?.arrayValue ?? []
        #expect(notes.count == 1 && object(output)["truncated"]?.boolValue == false)
        let first = notes.first?.objectValue
        #expect(first?["id"]?.stringValue == Self.noteID && first?["snippet"]?.stringValue == "milk, eggs")
        #expect(first?["folder"]?.stringValue == "Notes" && first?["account"]?.stringValue == "iCloud")
        #expect(first?["modified"]?.stringValue == ISODate.string(Self.date))
        #expect(first?["locked"]?.boolValue == false)
        #expect(output.text.contains(Self.noteID) && output.text.contains("milk, eggs"))
    }

    @Test func searchResolvesFolderByNameAndAccount() async throws {
        let fake = store()
        _ = try await run("search_notes", ["query": "x", "folder": "work", "limit": 7], on: fake)
        #expect(
            fake.read(\.query)
                == NotesSearchQuery(text: "x", folderId: "x-coredata://S/ICFolder/p2", account: "iCloud", limit: 7))
        // The same name in two accounts is ambiguous. An account or an id settles it.
        let ambiguous = await failure("search_notes", ["query": "x", "folder": "Notes"], on: fake)
        #expect(ambiguous?.code == .ambiguous)
        #expect(ambiguous?.message.contains("x-coredata://S/ICFolder/p1") == true)
        _ = try await run("search_notes", ["query": "x", "folder": "NOTES", "account": "On My Mac"], on: fake)
        #expect(fake.read(\.query)?.folderId == "x-coredata://S/ICFolder/p3")
        _ = try await run("search_notes", ["query": "x", "folder": "x-coredata://S/ICFolder/p4"], on: fake)
        #expect(fake.read(\.query)?.folderId == "x-coredata://S/ICFolder/p4")
        #expect(fake.read(\.query)?.account == "On My Mac")
        // Account only: no folder id.
        _ = try await run("search_notes", ["query": "x", "account": "icloud"], on: fake)
        #expect(fake.read(\.query)?.folderId == nil && fake.read(\.query)?.account == "iCloud")
    }

    @Test func searchFolderErrors() async {
        let fake = store()
        let missing = await failure("search_notes", ["query": "x", "folder": "Nope"], on: fake)
        #expect(missing?.code == .notFound && missing?.message.contains("'Ideas'") == true)
        // A folder that exists in another account does not match.
        let wrongAccount = await failure(
            "search_notes", ["query": "x", "folder": "Ideas", "account": "iCloud"], on: fake)
        #expect(wrongAccount?.code == .notFound)
        let noAccount = await failure("search_notes", ["query": "x", "account": "Nope"], on: fake)
        #expect(noAccount?.code == .notFound)
        #expect(fake.read(\.calls).contains("search") == false)
    }

    @Test func searchReportsTruncation() async throws {
        let fake = store { $0.page = NotesSearchPage(items: [Self.summary], truncated: true) }
        let output = try await run("search_notes", ["query": "x"], on: fake)
        #expect(object(output)["truncated"]?.boolValue == true)
        #expect(output.text.contains("Raise 'limit'"))
    }

    @Test func lockedNotesShowInSearchWithoutText() async throws {
        let locked = NoteSummary(
            id: Self.noteID, name: "Secret", folder: "Notes", account: "iCloud", modified: nil, locked: true,
            snippet: "")
        let fake = store { $0.page = NotesSearchPage(items: [locked], truncated: false) }
        let output = try await run("search_notes", ["query": "secret"], on: fake)
        #expect(output.text.contains("[locked]") && output.text.contains("no date"))
        #expect(object(output)["notes"]?.arrayValue?.first?.objectValue?["modified"] == nil)
    }

    @Test func searchTimeoutSuggestsAFolder() async {
        let fake = store { $0.delay = 2 }
        let error = await failure("search_notes", ["query": "x"], on: fake, using: module(fake, backendTimeout: 0.05))
        #expect(error?.code == .timeout)
        #expect(error?.fix?.contains("'folder'") == true)
    }

    // MARK: get_note

    @Test func getNoteReturnsTextAndOnlyAsksForHTMLOnRequest() async throws {
        let fake = store()
        let output = try await run("get_note", ["id": .string(Self.noteID)], on: fake)
        #expect(fake.read(\.noteRequest)?.includeHTML == false)
        let data = object(output)
        #expect(data["name"]?.stringValue == "Shopping" && data["body"]?.stringValue == "Shopping\nmilk")
        #expect(data["truncated"]?.boolValue == false && data["html"] == nil)
        #expect(data["created"]?.stringValue == ISODate.string(Self.date))
        #expect(output.text.contains("Folder: Notes (iCloud)") && output.text.contains("milk"))

        let withHTML = NotesNote(
            id: Self.noteID, name: "S", folder: "Notes", account: "iCloud", created: nil, modified: nil, body: "x",
            truncated: true, html: "<div>x</div>")
        let htmlFake = store { $0.note = withHTML }
        let html = try await run("get_note", ["id": .string(Self.noteID), "include_html": true], on: htmlFake)
        #expect(htmlFake.read(\.noteRequest)?.includeHTML == true)
        #expect(object(html)["html"]?.stringValue == "<div>x</div>" && object(html)["truncated"]?.boolValue == true)
        #expect(html.text.contains("cut at 100000"))
    }

    @Test func lockedNoteGivesAClearError() async {
        let fake = store { $0.error = NotesScripts.lockedError() }
        for (tool, args) in [
            ("get_note", ["id": Value.string(Self.noteID)]),
            ("append_to_note", ["id": .string(Self.noteID), "text": "x"]),
        ] {
            let error = await failure(tool, args, on: fake)
            #expect(error?.code == .permissionDenied && error?.message.contains("locked") == true, "\(tool)")
            #expect(error?.fix?.isEmpty == false)
        }
    }

    @Test func unknownIdIsNotFound() async {
        let fake = store { $0.note = nil }
        #expect(await failure("get_note", ["id": .string(Self.noteID)], on: fake)?.code == .notFound)
    }

    // MARK: create_note

    @Test func createNoteSendsEscapedHTML() async throws {
        let fake = store()
        let output = try await run(
            "create_note", ["title": " A & B <i> ", "body": "x < y\n\"z\"\n<script>"], on: fake)
        let created = try #require(fake.read(\.created))
        #expect(
            created.html
                == "<div><h1>A &amp; B &lt;i&gt;</h1></div><div>x &lt; y<br>&quot;z&quot;<br>&lt;script&gt;</div>")
        #expect(created.folderId == nil && created.account == nil)
        #expect(fake.read(\.calls) == ["create"])
        #expect(output.text.contains("id: x-coredata://A/ICNote/p1"))
        let data = object(output)
        #expect(data["action"]?.stringValue == "create_note" && data["note"]?.objectValue?["id"]?.stringValue != nil)
    }

    @Test func createNoteWithoutBodyAndWithFolder() async throws {
        let fake = store()
        _ = try await run("create_note", ["title": "Only title", "folder": "ideas"], on: fake)
        let created = try #require(fake.read(\.created))
        #expect(created.html == "<div><h1>Only title</h1></div>")
        #expect(created.folderId == "x-coredata://S/ICFolder/p4" && created.account == "On My Mac")
        // Account only: the script uses the default folder of that account.
        _ = try await run("create_note", ["title": "T", "account": "ICLOUD"], on: fake)
        #expect(fake.read(\.created)?.folderId == nil && fake.read(\.created)?.account == "iCloud")
    }

    @Test func createNoteFolderErrorsStopBeforeTheWrite() async {
        let fake = store()
        #expect(await failure("create_note", ["title": "T", "folder": "Notes"], on: fake)?.code == .ambiguous)
        #expect(await failure("create_note", ["title": "T", "folder": "Nope"], on: fake)?.code == .notFound)
        #expect(fake.read(\.created) == nil)
    }

    // MARK: append_to_note

    @Test func appendEscapesTheText() async throws {
        let fake = store()
        let output = try await run(
            "append_to_note", ["id": .string(Self.noteID), "text": "a & b\n<b>bold</b> \"q\""], on: fake)
        let appended = try #require(fake.read(\.appended))
        #expect(appended.id == Self.noteID)
        #expect(appended.html == "<div>a &amp; b<br>&lt;b&gt;bold&lt;/b&gt; &quot;q&quot;</div>")
        #expect(output.text.contains("Added text"))
    }

    // MARK: move_note and delete_note

    @Test func moveNoteResolvesFolderAndReportsTheNewId() async throws {
        let moved = NoteRef(id: "x-coredata://A/ICNote/p999", name: "Shopping", folder: "Work", account: "iCloud")
        let fake = store { $0.ref = moved }
        let output = try await run("move_note", ["id": .string(Self.noteID), "folder": "work"], on: fake)
        #expect(fake.read(\.moved)?.id == Self.noteID && fake.read(\.moved)?.folderId == "x-coredata://S/ICFolder/p2")
        #expect(output.text.contains("p999") && output.text.contains("'Work'"))
        #expect(object(output)["note"]?.objectValue?["id"]?.stringValue == moved.id)
        #expect(object(output)["moved_to"]?.stringValue == "Work")

        let ambiguous = await failure("move_note", ["id": .string(Self.noteID), "folder": "Notes"], on: fake)
        #expect(ambiguous?.code == .ambiguous)
        _ = try await run(
            "move_note", ["id": .string(Self.noteID), "folder": "Notes", "account": "On My Mac"], on: fake)
        #expect(fake.read(\.moved)?.folderId == "x-coredata://S/ICFolder/p3")
        let missing = await failure("move_note", ["id": .string(Self.noteID), "folder": "Nope"], on: fake)
        #expect(missing?.code == .notFound)
    }

    @Test func deleteNoteSaysItGoesToRecentlyDeleted() async throws {
        let fake = store()
        let output = try await run("delete_note", ["id": .string(Self.noteID)], on: fake)
        #expect(fake.read(\.deleted) == Self.noteID)
        #expect(output.text.contains("Recently Deleted"))
        #expect(object(output)["moved_to"]?.stringValue == "Recently Deleted")
    }

    @Test func storeErrorsPassThrough() async {
        let appError = ToolError(.appNotRunning, "Notes is not running.", fix: "Open Notes, then try again.")
        let fake = store { $0.error = appError }
        #expect(await failure("search_notes", ["query": "x"], on: fake) == appError)
        #expect(await failure("delete_note", ["id": .string(Self.noteID)], on: fake) == appError)
    }

    @Test func writeTimeoutIsAToolError() async {
        let fake = store { $0.delay = 2 }
        let error = await failure(
            "delete_note", ["id": .string(Self.noteID)], on: fake, using: module(fake, writeTimeout: 0.05))
        #expect(error?.code == .timeout)
    }

    @Test func unknownToolIsReported() async {
        #expect(await failure("nope", [:], on: store())?.code == .unknownTool)
    }
}
