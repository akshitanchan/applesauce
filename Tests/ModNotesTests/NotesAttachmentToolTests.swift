import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModNotes

/// The `get_note_attachment` tool with a fake store. Files go to a temp folder, never to the real cache.
@Suite struct NotesAttachmentToolTests {
    static let noteID = "x-coredata://6E1D5C2A/ICNote/p123"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "applesauce-notes-tool-\(UUID().uuidString)", isDirectory: true)

    func store(_ edit: (inout FakeNotesStore.State) -> Void = { _ in }) -> FakeNotesStore {
        var state = FakeNotesStore.State()
        edit(&state)
        return FakeNotesStore(state)
    }

    func module(_ store: FakeNotesStore, limit: Int = AttachmentCache.maxBytes) -> NotesModule {
        NotesModule(store: store, attachmentRoot: root, attachmentLimit: limit)
    }

    func call(
        _ args: [String: Value], on store: FakeNotesStore, limit: Int = AttachmentCache.maxBytes
    ) async throws -> ToolOutput {
        try await module(store, limit: limit).call("get_note_attachment", Arguments(args))
    }

    func failure(_ args: [String: Value], on store: FakeNotesStore, limit: Int = AttachmentCache.maxBytes) async
        -> ToolError?
    {
        do {
            _ = try await call(args, on: store, limit: limit)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    // MARK: get_note lists attachments

    @Test func getNoteListsTheAttachmentsWithTypes() async throws {
        let note = NotesNote(
            id: Self.noteID, name: "Trip", folder: "Notes", account: "iCloud", created: nil, modified: nil,
            body: "Trip", truncated: false, html: nil,
            attachments: [
                NoteAttachment(index: 1, name: "IMG_4311.heic"), NoteAttachment(index: 2, name: "Booking link"),
            ])
        let fake = store { $0.note = note }
        let output = try await module(fake).call("get_note", Arguments(["id": .string(Self.noteID)]))
        #expect(output.text.contains("Attachments: 1. IMG_4311.heic (image/heic), 2. Booking link"))
        let list = try #require(output.structured?.objectValue?["attachments"]?.arrayValue)
        #expect(list.count == 2)
        #expect(list[0].objectValue?["name"]?.stringValue == "IMG_4311.heic")
        #expect(list[0].objectValue?["type"]?.stringValue == "image/heic")
        #expect(list[0].objectValue?["index"]?.intValue == 1)
        #expect(list[1].objectValue?["type"] == nil)
        // A note without attachments shows no line.
        let plain = try await module(store { $0.note = NotesModuleTests.note }).call(
            "get_note", Arguments(["id": .string(Self.noteID)]))
        #expect(!plain.text.contains("Attachments:"))
    }

    // MARK: tool shape and gate

    @Test func toolIsHiddenInReadOnlyMode() async throws {
        let spec = try #require(NotesModule.toolSpecs.first { $0.tool.name == "get_note_attachment" })
        #expect(spec.isWrite && spec.tool.annotations.readOnlyHint == false)
        #expect(spec.tool.annotations.destructiveHint == false)
        let description = spec.tool.description ?? ""
        #expect(description.contains("confirm") && description.contains("25 MB") && description.contains("drawings"))

        let config = try Config.parse(arguments: ["--read-only"], environment: [:])
        let registry = try Registry(available: [NotesModule(store: store())], config: config)
        #expect(!registry.tools.map(\.name).contains("get_note_attachment"))
        let result = await registry.call(
            "get_note_attachment", arguments: ["id": .string(Self.noteID), "index": 1, "confirm": true])
        #expect(result.isError == true)
        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("no text")
            return
        }
        #expect(text.contains("READ_ONLY"))
    }

    @Test func withoutConfirmNothingHappens() async {
        defer { cleanUp() }
        let fake = store()
        for confirm in [nil, false] as [Bool?] {
            var args: [String: Value] = ["id": .string(Self.noteID), "index": 1]
            if let confirm { args["confirm"] = .bool(confirm) }
            let error = await failure(args, on: fake)
            #expect(error?.code == .invalidInput && error?.message.contains("confirm") == true)
            #expect(error?.fix?.contains("Ask the user") == true)
        }
        #expect(fake.read(\.calls).isEmpty)
        #expect(leftovers().isEmpty)
    }

    @Test func badInputNeverReachesTheStore() async {
        defer { cleanUp() }
        let fake = store()
        let id = Value.string(Self.noteID)
        let bad: [[String: Value]] = [
            ["confirm": true, "index": 1],
            ["id": "not-a-note-id", "confirm": true, "index": 1],
            ["id": id, "confirm": true],
            ["id": id, "confirm": true, "name": "a", "index": 1],
            ["id": id, "confirm": true, "index": 0],
            ["id": id, "confirm": true, "index": "one"],
            ["id": id, "confirm": true, "name": ""],
            ["id": id, "confirm": "yes", "index": 1],
        ]
        for args in bad {
            let error = await failure(args, on: fake)
            #expect(error?.code == .invalidInput, "\(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
        #expect(leftovers().isEmpty)
    }

    // MARK: saving

    @Test func savesTheFileAndReturnsThePathAndText() async throws {
        defer { cleanUp() }
        let fake = store()
        let output = try await call(["id": .string(Self.noteID), "name": "memo.txt", "confirm": true], on: fake)
        let payload = try #require(output.structured?.objectValue)
        let path = try #require(payload["path"]?.stringValue)
        #expect(path.hasPrefix(root.path + "/") && path.hasSuffix("/memo.txt"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("note attachment".utf8))
        #expect(output.text.contains(path) && output.text.contains("note attachment"))
        let saved = try #require(fake.read(\.savedAttachment))
        #expect(saved.id == Self.noteID && saved.pick == .name("memo.txt") && saved.limit == AttachmentCache.maxBytes)
    }

    @Test func theNameOnDiskIsSanitized() async throws {
        defer { cleanUp() }
        let fake = store { $0.attachmentName = "../../../etc/cron.d/evil" }
        let output = try await call(["id": .string(Self.noteID), "index": 1, "confirm": true], on: fake)
        let path = try #require(output.structured?.objectValue?["path"]?.stringValue)
        #expect(!path.contains(".."))
        let file = URL(fileURLWithPath: path)
        #expect(file.deletingLastPathComponent().deletingLastPathComponent().path == root.path)
    }

    @Test func aFileAboveTheLimitIsRefusedAndNothingStays() async {
        defer { cleanUp() }
        let fake = store { $0.attachmentData = Data(count: 20) }
        let error = await failure(["id": .string(Self.noteID), "index": 1, "confirm": true], on: fake, limit: 10)
        #expect(error?.code == .invalidInput && error?.message.contains("memo.txt") == true)
        #expect(error?.message.contains("MB") == true)
        #expect(leftovers().isEmpty)
    }

    @Test func anExportErrorPassesThroughAndLeavesNoFolder() async {
        defer { cleanUp() }
        let exportError = NotesScripts.scriptError(
            ToolError(
                .internalError,
                "1:1: execution error: Notes could not save the attachment 'Link' (AppleEvent handler failed.). (1006)")
        )
        let fake = store { $0.error = exportError }
        let error = await failure(["id": .string(Self.noteID), "index": 2, "confirm": true], on: fake)
        #expect(error == exportError && error?.code == .invalidInput)
        #expect(error?.fix?.contains("Drawings, scans, tables and links") == true)
        #expect(leftovers().isEmpty)
    }

    @Test func filesOlderThan24HoursAreDeletedAtTheStartOfACall() async throws {
        defer { cleanUp() }
        let fileManager = FileManager.default
        let oldFolder = try AttachmentCache.makeFolder(root: root)
        _ = try AttachmentCache.write(Data("old".utf8), name: "old.txt", into: oldFolder)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: oldFolder.path)
        let youngFolder = try AttachmentCache.makeFolder(root: root)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-1 * 3600)], ofItemAtPath: youngFolder.path)

        _ = try await call(["id": .string(Self.noteID), "index": 1, "confirm": true], on: store())
        #expect(!fileManager.fileExists(atPath: oldFolder.path))
        #expect(fileManager.fileExists(atPath: youngFolder.path))
    }

    @Test func aLockedNoteIsNotRead() async {
        defer { cleanUp() }
        let fake = store { $0.error = NotesScripts.lockedError() }
        let error = await failure(["id": .string(Self.noteID), "index": 1, "confirm": true], on: fake)
        #expect(error?.code == .permissionDenied)
        #expect(leftovers().isEmpty)
    }

    // MARK: content

    @Test func textIsCutAtTheBodyLimit() async throws {
        defer { cleanUp() }
        let fake = store { $0.attachmentData = Data(String(repeating: "y", count: 100_001).utf8) }
        let output = try await call(["id": .string(Self.noteID), "index": 1, "confirm": true], on: fake)
        #expect(!output.text.contains(String(repeating: "y", count: 100_001)))
        #expect(output.text.contains("Text cut at 100000 characters"))
    }

    #if os(macOS)
    @Test func imagesComeBackAsAnImageBlock() async throws {
        defer { cleanUp() }
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            ))
        let fake = store {
            $0.attachmentData = png
            $0.attachmentName = "drawing.png"
        }
        let output = try await call(["id": .string(Self.noteID), "index": 1, "confirm": true], on: fake)
        #expect(output.images.count == 1 && output.images[0].mimeType == "image/png")
        #expect(Data(base64Encoded: output.images[0].data) == png)
    }
    #endif
}
