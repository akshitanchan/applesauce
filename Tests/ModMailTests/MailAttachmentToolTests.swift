import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModMail

/// The `get_mail_attachment` tool with a fake store. Files go to a temp folder, never to the real cache.
@Suite struct MailAttachmentToolTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "applesauce-tool-\(UUID().uuidString)", isDirectory: true)

    func store(_ edit: (inout FakeMailStore.State) -> Void = { _ in }) -> FakeMailStore {
        var state = FakeMailStore.State()
        state.refs = ["10": MessageRef(id: "10", accountId: "ACC1", mailbox: "INBOX")]
        edit(&state)
        return FakeMailStore(state)
    }

    func module(_ store: FakeMailStore, limit: Int = AttachmentCache.maxBytes) -> MailModule {
        MailModule(store: store, attachmentRoot: root, attachmentLimit: limit)
    }

    func call(
        _ args: [String: Value], on store: FakeMailStore, limit: Int = AttachmentCache.maxBytes
    ) async throws -> ToolOutput {
        try await module(store, limit: limit).call("get_mail_attachment", Arguments(args))
    }

    func failure(_ args: [String: Value], on store: FakeMailStore, limit: Int = AttachmentCache.maxBytes) async
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

    // MARK: tool shape

    @Test func toolIsHiddenInReadOnlyMode() async throws {
        let spec = try #require(MailModule.toolSpecs.first { $0.tool.name == "get_mail_attachment" })
        #expect(spec.isWrite && spec.tool.annotations.readOnlyHint == false)
        #expect(spec.tool.annotations.destructiveHint == false)
        #expect(spec.tool.description?.contains("confirm") == true && spec.tool.description?.contains("25 MB") == true)

        let config = try Config.parse(arguments: ["--read-only"], environment: [:])
        let registry = try Registry(available: [MailModule(store: store())], config: config)
        #expect(!registry.tools.map(\.name).contains("get_mail_attachment"))
        let result = await registry.call("get_mail_attachment", arguments: ["id": "10", "name": "a", "confirm": true])
        #expect(result.isError == true)
        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("no text")
            return
        }
        #expect(text.contains("READ_ONLY"))
        // Without read-only mode the tool is listed.
        let open = try Registry(available: [MailModule(store: store())], config: Config())
        #expect(open.tools.map(\.name).contains("get_mail_attachment"))
    }

    // MARK: confirm gate

    @Test func withoutConfirmNothingHappens() async {
        defer { cleanUp() }
        let fake = store()
        for confirm in [nil, false] as [Bool?] {
            var args: [String: Value] = ["id": "10", "name": "notes.txt"]
            if let confirm { args["confirm"] = .bool(confirm) }
            let error = await failure(args, on: fake)
            #expect(error?.code == .invalidInput)
            #expect(error?.message.contains("confirm") == true)
            #expect(error?.fix?.contains("Ask the user") == true)
        }
        #expect(fake.read(\.calls).isEmpty)
        #expect(leftovers().isEmpty)
    }

    @Test func badInputNeverReachesTheStore() async {
        defer { cleanUp() }
        let fake = store()
        let bad: [[String: Value]] = [
            ["confirm": true, "name": "a"],
            ["id": "abc", "confirm": true, "name": "a"],
            ["id": "10", "confirm": true],
            ["id": "10", "confirm": true, "name": "a", "index": 1],
            ["id": "10", "confirm": true, "index": 0],
            ["id": "10", "confirm": true, "index": "one"],
            ["id": "10", "confirm": true, "name": ""],
            ["id": "10", "confirm": true, "name": 5],
            ["id": "10", "confirm": "yes", "name": "a"],
            ["id": "10", "in_mailbox": "INBOX", "confirm": true, "name": "a"],
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
        let output = try await call(["id": "10", "name": "notes.txt", "confirm": true], on: fake)
        let payload = try #require(output.structured?.objectValue)
        let path = try #require(payload["path"]?.stringValue)
        #expect(path.hasPrefix(root.path + "/") && path.hasSuffix("/notes.txt"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("attachment text".utf8))
        #expect(output.text.contains(path) && output.text.contains("attachment text"))
        #expect(payload["size"]?.intValue == 15 && payload["kind"]?.stringValue == "text")
        let saved = try #require(fake.read(\.savedAttachment))
        #expect(saved.pick == .name("notes.txt") && saved.ref.mailbox == "INBOX")
        #expect(saved.limit == AttachmentCache.maxBytes)
        // Folder and file are private to the user.
        let attributes = try FileManager.default.attributesOfItem(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test func everyCallGetsItsOwnFolder() async throws {
        defer { cleanUp() }
        let fake = store()
        let first = try await call(["id": "10", "index": 1, "confirm": true], on: fake)
        let second = try await call(["id": "10", "index": 2, "confirm": true], on: fake)
        #expect(first.structured?.objectValue?["path"] != second.structured?.objectValue?["path"])
        #expect(leftovers().count == 2)
        #expect(fake.read(\.savedAttachment)?.pick == .index(2))
    }

    @Test func theNameOnDiskIsSanitized() async throws {
        defer { cleanUp() }
        let fake = store {
            $0.attachmentName = "../../.ssh/authorized_keys"
        }
        let output = try await call(["id": "10", "index": 1, "confirm": true], on: fake)
        let path = try #require(output.structured?.objectValue?["path"]?.stringValue)
        #expect(!path.contains(".."))
        let file = URL(fileURLWithPath: path)
        #expect(file.deletingLastPathComponent().deletingLastPathComponent().path == root.path)
        #expect(FileManager.default.fileExists(atPath: path))
        // The original name still shows, as data.
        #expect(output.structured?.objectValue?["name"]?.stringValue == "../../.ssh/authorized_keys")
    }

    // MARK: limits and cleanup

    @Test func aFileAboveTheLimitIsRefusedAndNothingStays() async {
        defer { cleanUp() }
        let fake = store { $0.attachmentData = Data(count: 20) }
        let error = await failure(["id": "10", "index": 1, "confirm": true], on: fake, limit: 10)
        #expect(error?.code == .invalidInput && error?.message.contains("notes.txt") == true)
        #expect(error?.message.contains("MB") == true && error?.fix?.isEmpty == false)
        #expect(leftovers().isEmpty)
    }

    @Test func aFileAtTheLimitPasses() async throws {
        defer { cleanUp() }
        let fake = store { $0.attachmentData = Data(count: 10) }
        _ = try await call(["id": "10", "index": 1, "confirm": true], on: fake, limit: 10)
        #expect(leftovers().count == 1)
        #expect(fake.read(\.savedAttachment)?.limit == 10)
    }

    @Test func aStoreErrorPassesThroughAndLeavesNoFolder() async {
        defer { cleanUp() }
        let notDownloaded = MailAttachments.notDownloaded("a.pdf")
        let fake = store { $0.attachmentError = notDownloaded }
        let error = await failure(["id": "10", "name": "a.pdf", "confirm": true], on: fake)
        #expect(error == notDownloaded)
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
        _ = try AttachmentCache.write(Data("young".utf8), name: "young.txt", into: youngFolder)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-23 * 3600)], ofItemAtPath: youngFolder.path)

        _ = try await call(["id": "10", "index": 1, "confirm": true], on: store())
        #expect(!fileManager.fileExists(atPath: oldFolder.path))
        #expect(fileManager.fileExists(atPath: youngFolder.path))
        #expect(leftovers().count == 2)
    }

    @Test func theSweepRunsEvenWhenTheCallFails() async throws {
        defer { cleanUp() }
        let oldFolder = try AttachmentCache.makeFolder(root: root)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 3600)], ofItemAtPath: oldFolder.path)
        let fake = store { $0.attachmentError = ToolError(.notFound, "No attachment.") }
        _ = await failure(["id": "10", "index": 1, "confirm": true], on: fake)
        #expect(!FileManager.default.fileExists(atPath: oldFolder.path))
    }

    // MARK: content

    @Test func textIsCutAtTheBodyLimit() async throws {
        defer { cleanUp() }
        let text = String(repeating: "x", count: 100_001)
        let fake = store { $0.attachmentData = Data(text.utf8) }
        let output = try await call(["id": "10", "index": 1, "confirm": true], on: fake)
        #expect(output.text.contains(String(repeating: "x", count: 100_000)))
        #expect(!output.text.contains(String(repeating: "x", count: 100_001)))
        #expect(output.text.contains("Text cut at 100000 characters"))
        #expect(output.structured?.objectValue?["truncated"]?.boolValue == true)
    }

    #if os(macOS)
    @Test func imagesComeBackAsAnImageBlock() async throws {
        defer { cleanUp() }
        // A 1x1 PNG.
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            ))
        let fake = store {
            $0.attachmentData = png
            $0.attachmentName = "dot.png"
        }
        let output = try await call(["id": "10", "name": "dot.png", "confirm": true], on: fake)
        #expect(output.images.count == 1 && output.images[0].mimeType == "image/png")
        #expect(Data(base64Encoded: output.images[0].data) == png)
        #expect(output.structured?.objectValue?["image_returned"]?.boolValue == true)
        // Through the registry the image is a content block after the text.
        let registry = try Registry(available: [module(fake)], config: Config())
        let result = await registry.call(
            "get_mail_attachment", arguments: ["id": "10", "name": "dot.png", "confirm": true])
        #expect(result.content.count == 2)
        guard case .image(_, let mime, _, _) = result.content[1] else {
            Issue.record("no image block")
            return
        }
        #expect(mime == "image/png")
    }
    #endif

    @Test func otherTypesReturnOnlyThePath() async throws {
        defer { cleanUp() }
        let fake = store {
            $0.attachmentData = Data([0x50, 0x4B, 3, 4])
            $0.attachmentName = "data.zip"
        }
        let output = try await call(["id": "10", "index": 1, "confirm": true], on: fake)
        #expect(output.images.isEmpty && output.text.contains("data.zip"))
        #expect(output.structured?.objectValue?["text_returned"]?.boolValue == false)
    }

    // MARK: finding the message

    @Test func withoutFullDiskAccessTheCallerSaysWhereTheMessageIs() async throws {
        defer { cleanUp() }
        let fake = store { $0.fullDiskAccess = false }
        let error = await failure(["id": "10", "index": 1, "confirm": true], on: fake)
        #expect(error?.code == .permissionDenied && error?.fix?.contains("in_mailbox") == true)
        #expect(fake.read(\.calls).isEmpty)
        let output = try await call(
            ["id": "10", "index": 1, "confirm": true, "in_mailbox": "Archive", "in_account": "ACC9"], on: fake)
        #expect(output.structured?.objectValue?["path"]?.stringValue != nil)
        let saved = try #require(fake.read(\.savedAttachment))
        #expect(saved.ref == MessageRef(id: "10", accountId: "ACC9", mailbox: "Archive"))
    }

    @Test func unknownIdIsNotFoundBeforeAnythingIsSaved() async {
        defer { cleanUp() }
        let fake = store()
        let error = await failure(["id": "99", "index": 1, "confirm": true], on: fake)
        #expect(error?.code == .notFound)
        #expect(fake.read(\.calls) == ["locate"])
        #expect(leftovers().isEmpty)
    }
}
