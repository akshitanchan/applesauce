import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModNotes

/// `delete_folder` with a fake store.
@Suite struct NotesDeleteFolderTests {
    static let notes = NotesFolder(id: "x-coredata://S/ICFolder/p1", name: "Notes", account: "iCloud", noteCount: 5)
    static let spare = NotesFolder(id: "x-coredata://S/ICFolder/p2", name: "Spare", account: "iCloud", noteCount: 0)
    static let full = NotesFolder(id: "x-coredata://S/ICFolder/p3", name: "Full", account: "iCloud", noteCount: 2)
    static let parent = NotesFolder(id: "x-coredata://S/ICFolder/p4", name: "Parent", account: "iCloud", noteCount: 0)
    static let child = NotesFolder(id: "x-coredata://S/ICFolder/p5", name: "Child", account: "iCloud", noteCount: 0)
    static let lone = NotesFolder(id: "x-coredata://S/ICFolder/p6", name: "Lone", account: "On My Mac", noteCount: 0)
    static let trash = NotesFolder(
        id: "x-coredata://S/ICFolder/p7", name: "Recently Deleted", account: "iCloud", noteCount: 0)
    static let myMacNotes = NotesFolder(
        id: "x-coredata://S/ICFolder/p8", name: "Notes", account: "On My Mac", noteCount: 0)

    static func details(
        _ folder: NotesFolder, notes: Int = 0, subfolders: Int = 0, topLevel: Bool = true, isDefault: Bool = false,
        top: Int = 3
    ) -> FolderDetails {
        FolderDetails(
            folder: folder, noteCount: notes, subfolderCount: subfolders, topLevel: topLevel, isDefault: isDefault,
            topLevelFolderCount: top)
    }

    func store(_ edit: (inout FakeNotesStore.State) -> Void = { _ in }) -> FakeNotesStore {
        var state = FakeNotesStore.State()
        state.folders = [
            Self.notes, Self.spare, Self.full, Self.parent, Self.child, Self.lone, Self.trash, Self.myMacNotes,
        ]
        let all = [
            Self.details(Self.notes, notes: 5, isDefault: true),
            Self.details(Self.spare),
            Self.details(Self.full, notes: 2),
            Self.details(Self.parent, subfolders: 1),
            Self.details(Self.child, topLevel: false),
            Self.details(Self.lone, top: 1),
            Self.details(Self.trash),
            Self.details(Self.myMacNotes, isDefault: true),
        ]
        state.details = Dictionary(uniqueKeysWithValues: all.map { ($0.folder.id, $0) })
        edit(&state)
        return FakeNotesStore(state)
    }

    func run(_ args: [String: Value], on store: FakeNotesStore) async throws -> ToolOutput {
        try await NotesModule(store: store).call("delete_folder", Arguments(args))
    }

    func failure(_ args: [String: Value], on store: FakeNotesStore) async -> ToolError? {
        do {
            _ = try await run(args, on: store)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    @Test func badInputNeverReachesTheStore() async {
        let fake = store()
        for args: [String: Value] in [
            [:], ["folder": ""], ["folder": 5], ["folder": "Spare", "account": ""],
            ["folder": "Spare", "confirm": "yes"],
        ] {
            let error = await failure(args, on: fake)
            #expect(error?.code == .invalidInput, "\(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func needsConfirmEvenWhenEmpty() async throws {
        let fake = store()
        for confirm: Value? in [nil, false] {
            var args: [String: Value] = ["folder": "spare"]
            if let confirm { args["confirm"] = confirm }
            let output = try await run(args, on: fake)
            let object = try #require(output.structured?.objectValue)
            #expect(object["confirm_required"]?.boolValue == true)
            #expect(object["folder"]?.objectValue?["id"]?.stringValue == Self.spare.id)
            #expect(output.text.hasPrefix("Nothing deleted."))
        }
        #expect(fake.read(\.deletedFolder) == nil)
        #expect(!fake.read(\.calls).contains("deleteFolder"))
    }

    @Test func deletesAnEmptyFolderByNameOrId() async throws {
        let fake = store()
        let output = try await run(["folder": "Spare", "confirm": true], on: fake)
        #expect(fake.read(\.deletedFolder) == Self.spare.id)
        let object = try #require(output.structured?.objectValue)
        #expect(object["action"]?.stringValue == "delete_folder")
        #expect(object["deleted"]?.stringValue == Self.spare.id)
        #expect(object["folder"]?.objectValue?["name"]?.stringValue == "Spare")
        _ = try await run(["folder": .string(Self.child.id), "confirm": true], on: fake)
        #expect(fake.read(\.deletedFolder) == Self.child.id)
    }

    @Test func refusesAFolderWithNotesOrSubfolders() async {
        let fake = store()
        let withNotes = await failure(["folder": "Full", "confirm": true], on: fake)
        #expect(withNotes?.code == .invalidInput)
        #expect(withNotes?.message.contains("holds 2 notes and 0 subfolders") == true)
        #expect(withNotes?.message.contains("Nothing was deleted") == true)
        let withChild = await failure(["folder": "Parent", "confirm": true], on: fake)
        #expect(withChild?.message.contains("holds 0 notes and 1 subfolders") == true)
        #expect(fake.read(\.deletedFolder) == nil)
    }

    @Test func refusesBuiltInDefaultAndOnlyFolders() async {
        let fake = store()
        let builtIn = await failure(["folder": "Recently Deleted", "confirm": true], on: fake)
        #expect(builtIn?.message.contains("built-in") == true)
        let named = await failure(["folder": "Notes", "account": "iCloud", "confirm": true], on: fake)
        #expect(named?.message.contains("built-in") == true)
        let defaultFolder = await failure(["folder": .string(Self.myMacNotes.id), "confirm": true], on: fake)
        #expect(defaultFolder?.message.contains("built-in") == true)
        let only = await failure(["folder": "Lone", "confirm": true], on: fake)
        #expect(only?.message.contains("only folder") == true)
        #expect(fake.read(\.deletedFolder) == nil)
    }

    @Test func aDefaultFolderWithAnotherNameIsRefused() async {
        let state = FakeNotesStore.State(
            folders: [Self.spare], details: [Self.spare.id: Self.details(Self.spare, isDefault: true)])
        let fake = FakeNotesStore(state)
        let error = await failure(["folder": "Spare", "confirm": true], on: fake)
        #expect(error?.message.contains("default folder") == true)
        #expect(fake.read(\.deletedFolder) == nil)
    }

    @Test func aNestedFolderWithABuiltInNameIsNotRefusedForTheName() async throws {
        let nested = NotesFolder(id: "x-coredata://S/ICFolder/p9", name: "Notes", account: "iCloud", noteCount: 0)
        let state = FakeNotesStore.State(
            folders: [nested], details: [nested.id: Self.details(nested, topLevel: false)])
        let fake = FakeNotesStore(state)
        _ = try await run(["folder": .string(nested.id), "confirm": true], on: fake)
        #expect(fake.read(\.deletedFolder) == nested.id)
    }

    @Test func unknownAndAmbiguousFoldersAreRefused() async {
        let fake = store()
        let unknown = await failure(["folder": "Nope", "confirm": true], on: fake)
        #expect(unknown?.code == .notFound)
        let ambiguous = await failure(["folder": "Notes", "confirm": true], on: fake)
        #expect(ambiguous?.code == .ambiguous)
        let account = await failure(["folder": "Spare", "account": "Nope", "confirm": true], on: fake)
        #expect(account?.code == .notFound)
        #expect(fake.read(\.deletedFolder) == nil)
    }

    @Test func aFolderThatFilledUpBeforeTheDeleteIsKept() async {
        let late = NotesScripts.scriptError(
            ToolError(.internalError, "execution error: The folder holds 1 notes and 0 subfolders. (1008)"))
        let fake = store { $0.deleteFolderError = late }
        let error = await failure(["folder": "Spare", "confirm": true], on: fake)
        #expect(error?.code == .invalidInput)
        #expect(error?.message == "The folder holds 1 notes and 0 subfolders.")
        #expect(error?.fix?.contains("Nothing was deleted") == true)
    }

    @Test func parsesTheDetailsRecord() {
        let fs = "\u{1F}"
        let text = ["x-coredata://S/ICFolder/p2", "Spare", "iCloud", "0", "2", "true", "false", "4"].joined(
            separator: fs)
        let details = NotesScripts.parseFolderDetails(text)
        #expect(details?.folder.name == "Spare")
        #expect(details?.subfolderCount == 2)
        #expect(details?.topLevel == true)
        #expect(details?.isDefault == false)
        #expect(details?.topLevelFolderCount == 4)
        #expect(NotesScripts.parseFolderDetails("") == nil)
        #expect(NotesScripts.parseFolderDetails("a\(fs)b\(fs)c") == nil)
    }

    @Test func isDestructiveAndNeedsOnlyFolder() throws {
        let spec = try #require(NotesModule.toolSpecs.first { $0.tool.name == "delete_folder" })
        #expect(spec.isWrite && spec.tool.annotations.destructiveHint == true)
        let required = spec.tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["folder"])
    }
}
