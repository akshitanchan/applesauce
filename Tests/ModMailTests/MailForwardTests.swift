import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModMail

/// `forward_message`, and the 'attachments' argument of `send_mail` and `create_draft`. Fake store only.
/// Saved files go to a temp folder, never to the real cache.
@Suite struct MailForwardTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "applesauce-forward-\(UUID().uuidString)", isDirectory: true)

    static let original = MailMessage(
        id: "10", subject: "Quarterly report", from: "Ann <ann@example.com>",
        to: ["me@work.example", "bob@example.com"],
        cc: ["cc@example.com"], date: Date(timeIntervalSince1970: 1_700_000_000), mailbox: "INBOX", accountId: "ACC1",
        read: true, flagged: false, messageId: "<a@b>", body: "Line one\nLine two", bodySource: "emlx",
        truncated: false, partial: false,
        attachments: [MailAttachment(name: "report.pdf", size: 2048), MailAttachment(name: "chart.png", size: 100)],
        note: nil)

    func store(_ edit: (inout FakeMailStore.State) -> Void = { _ in }) -> FakeMailStore {
        var state = FakeMailStore.State()
        state.message = Self.original
        state.refs = ["10": MessageRef(id: "10", accountId: "ACC1", mailbox: "INBOX")]
        edit(&state)
        return FakeMailStore(state)
    }

    func module(_ store: FakeMailStore, limit: Int = AttachmentCache.maxBytes) -> MailModule {
        MailModule(store: store, attachmentRoot: root, attachmentLimit: limit)
    }

    func call(
        _ tool: String, _ args: [String: Value], on store: FakeMailStore, limit: Int = AttachmentCache.maxBytes
    ) async throws -> ToolOutput {
        try await module(store, limit: limit).call(tool, Arguments(args))
    }

    func failure(_ tool: String, _ args: [String: Value], on store: FakeMailStore) async -> ToolError? {
        do {
            _ = try await call(tool, args, on: store)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func object(_ output: ToolOutput) -> [String: Value] { output.structured?.objectValue ?? [:] }

    func names(_ value: Value?) -> [String] { value?.arrayValue?.compactMap(\.stringValue) ?? [] }

    func tempFile(_ name: String, bytes: Int = 8) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(name)
        try Data(repeating: 66, count: bytes).write(to: file)
        return OutgoingFiles.realPath(file.path) ?? file.path
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    // MARK: subject and body

    @Test func subjectGetsOnePrefix() {
        #expect(MailModule.forwardSubject("Hello") == "Fwd: Hello")
        #expect(MailModule.forwardSubject("Fwd: Hello") == "Fwd: Hello")
        #expect(MailModule.forwardSubject("FWD: Hello") == "FWD: Hello")
        #expect(MailModule.forwardSubject("Fw: Hello") == "Fw: Hello")
        #expect(MailModule.forwardSubject("  Re: Hello \n") == "Fwd: Re: Hello")
        #expect(MailModule.forwardSubject("") == "Fwd:")
    }

    @Test func bodyHasYourTextTheHeaderBlockAndTheOriginal() {
        let body = MailModule.forwardBody(intro: "FYI", original: Self.original, text: "Line one\nLine two")
        let date = ISODate.string(Date(timeIntervalSince1970: 1_700_000_000))
        #expect(
            body == """
                FYI

                Begin forwarded message:

                From: Ann <ann@example.com>
                Date: \(date)
                Subject: Quarterly report
                To: me@work.example, bob@example.com
                Cc: cc@example.com

                Line one
                Line two
                """)
        let plain = MailModule.forwardBody(intro: nil, original: Self.original, text: "x")
        #expect(plain.hasPrefix("Begin forwarded message:"))
    }

    // MARK: forward_message

    @Test func forwardSavesADraftUnlessConfirmed() async throws {
        defer { cleanUp() }
        for confirm: Value? in [nil, false] {
            let fake = store()
            var args: [String: Value] = ["id": "10", "to": ["a@b.c"], "body": "Please read"]
            if let confirm { args["confirm"] = confirm }
            let output = try await call("forward_message", args, on: fake)
            let composed = try #require(fake.read(\.composed))
            #expect(composed.send == false)
            #expect(composed.mail.subject == "Fwd: Quarterly report")
            #expect(composed.mail.to == ["a@b.c"] && composed.mail.from == "me@work.example")
            #expect(composed.mail.body.hasPrefix("Please read\n\nBegin forwarded message:"))
            #expect(composed.mail.body.hasSuffix("Line one\nLine two"))
            #expect(output.text.contains("Not sent") && output.text.contains("draft"))
            #expect(object(output)["sent"]?.boolValue == false)
            #expect(object(output)["draft_saved"]?.boolValue == true)
        }
    }

    @Test func forwardSendsWithConfirmTrue() async throws {
        defer { cleanUp() }
        let fake = store()
        let output = try await call(
            "forward_message",
            ["id": "10", "to": ["a@b.c"], "cc": ["c@d.e"], "bcc": ["f@g.h"], "confirm": true], on: fake)
        let composed = try #require(fake.read(\.composed))
        #expect(composed.send == true)
        #expect(composed.mail.cc == ["c@d.e"] && composed.mail.bcc == ["f@g.h"])
        #expect(output.text.hasPrefix("Forwarded message 10 from me@work.example to a@b.c."))
        #expect(object(output)["sent"]?.boolValue == true)
        // No 'body': the forwarded part starts the text.
        #expect(composed.mail.body.hasPrefix("Begin forwarded message:"))
    }

    @Test func forwardIncludesTheOriginalAttachmentsByDefault() async throws {
        defer { cleanUp() }
        let fake = store {
            $0.attachmentNames = [1: "report.pdf", 2: "chart.png"]
        }
        let output = try await call("forward_message", ["id": "10", "to": ["a@b.c"]], on: fake)
        #expect(fake.read(\.savedPicks) == [.index(1), .index(2)])
        let composed = try #require(fake.read(\.composed))
        #expect(composed.mail.attachments.map { ($0 as NSString).lastPathComponent } == ["report.pdf", "chart.png"])
        #expect(composed.mail.attachments.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(names(object(output)["attached"]) == ["report.pdf", "chart.png"])
        #expect(output.text.contains("Attached: report.pdf, chart.png."))
        #expect(object(output)["skipped"] == nil)
    }

    @Test func sameNamedAttachmentsStayApart() async throws {
        defer { cleanUp() }
        let fake = store()  // Both attachments get the fake's one name.
        _ = try await call("forward_message", ["id": "10", "to": ["a@b.c"]], on: fake)
        let paths = try #require(fake.read(\.composed)).mail.attachments
        #expect(paths.count == 2 && Set(paths).count == 2)
    }

    @Test func includeAttachmentsFalseSavesNothing() async throws {
        defer { cleanUp() }
        let fake = store()
        let output = try await call(
            "forward_message", ["id": "10", "to": ["a@b.c"], "include_attachments": false], on: fake)
        #expect(fake.read(\.savedPicks).isEmpty)
        #expect(fake.read(\.composed)?.mail.attachments == [])
        #expect(object(output)["attached"] == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func anAttachmentThatFailsIsSkippedAndReported() async throws {
        defer { cleanUp() }
        let fake = store {
            $0.attachmentNames = [2: "chart.png"]
            $0.attachmentFailures = [
                1: ToolError(.notFound, "Mail has not downloaded the attachment 'report.pdf' yet.")
            ]
        }
        let output = try await call("forward_message", ["id": "10", "to": ["a@b.c"]], on: fake)
        let composed = try #require(fake.read(\.composed))
        #expect(composed.mail.attachments.map { ($0 as NSString).lastPathComponent } == ["chart.png"])
        #expect(names(object(output)["attached"]) == ["chart.png"])
        let skipped = names(object(output)["skipped"])
        #expect(skipped.count == 1 && skipped[0].hasPrefix("report.pdf") && skipped[0].contains("not downloaded"))
        #expect(output.text.contains("Skipped: report.pdf"))
        // The folder of the failed attachment is gone.
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(folders.count == 1)
    }

    @Test func anAttachmentAboveTheLimitIsSkipped() async throws {
        defer { cleanUp() }
        let fake = store {
            $0.attachmentData = Data(repeating: 1, count: 20)
            $0.attachmentNames = [1: "big.bin", 2: "big2.bin"]
        }
        let output = try await call("forward_message", ["id": "10", "to": ["a@b.c"]], on: fake, limit: 10)
        #expect(fake.read(\.composed)?.mail.attachments == [])
        #expect(names(object(output)["skipped"]).count == 2)
        #expect(fake.read(\.savedAttachment)?.limit == 10)
    }

    @Test func extraFilesAreAddedAfterTheForwardedOnes() async throws {
        defer { cleanUp() }
        let extra = try tempFile("extra.txt")
        let fake = store { $0.attachmentNames = [1: "report.pdf", 2: "chart.png"] }
        let output = try await call(
            "forward_message", ["id": "10", "to": ["a@b.c"], "attachments": .array([.string(extra)])], on: fake)
        let attached = try #require(fake.read(\.composed)).mail.attachments
        #expect(attached.count == 3 && attached.last == extra)
        #expect(names(object(output)["attached"]) == ["report.pdf", "chart.png", "extra.txt"])
    }

    @Test func aBadExtraFileStopsTheCallBeforeAnythingIsSaved() async throws {
        defer { cleanUp() }
        let fake = store()
        let error = await failure(
            "forward_message", ["id": "10", "to": ["a@b.c"], "attachments": ["/nonexistent/file.txt"]], on: fake)
        #expect(error?.code == .notFound)
        #expect(fake.read(\.calls).isEmpty && fake.read(\.savedPicks).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func severalAccountsWithoutFromAreAmbiguousAndNothingIsSaved() async throws {
        defer { cleanUp() }
        let fake = store {
            $0.accounts = [
                MailAccount(id: "ACC1", name: "Work", emails: ["me@work.example"]),
                MailAccount(id: "ACC2", name: "Home", emails: ["me@home.example"]),
            ]
        }
        let error = await failure("forward_message", ["id": "10", "to": ["a@b.c"], "confirm": true], on: fake)
        #expect(error?.code == .ambiguous)
        #expect(fake.read(\.composed) == nil && fake.read(\.savedPicks).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // With 'from' the call works.
        _ = try await call(
            "forward_message", ["id": "10", "to": ["a@b.c"], "from": "Home", "include_attachments": false],
            on: fake)
        #expect(fake.read(\.composed)?.mail.from == "me@home.example")
    }

    @Test func aMessageWithoutTextCannotBeForwarded() async throws {
        defer { cleanUp() }
        let noBody = MailMessage(
            id: "10", subject: "S", from: "a@b.c", to: [], cc: [], date: nil, mailbox: "INBOX", accountId: "ACC1",
            read: true, flagged: false, messageId: nil, body: nil, bodySource: "none", truncated: false,
            partial: false, attachments: [], note: "The message file is not on disk.")
        let fake = store {
            $0.message = noBody
            $0.running = false
        }
        let error = await failure("forward_message", ["id": "10", "to": ["a@b.c"], "confirm": true], on: fake)
        #expect(error?.code == .notFound && error?.message.contains("not on disk") == true)
        #expect(fake.read(\.composed) == nil)
    }

    @Test func aTruncatedOriginalSaysSo() async throws {
        defer { cleanUp() }
        let cut = MailMessage(
            id: "10", subject: "S", from: "a@b.c", to: [], cc: [], date: nil, mailbox: "INBOX", accountId: "ACC1",
            read: true, flagged: false, messageId: nil, body: "text", bodySource: "emlx", truncated: true,
            partial: false, attachments: [], note: nil)
        let fake = store { $0.message = cut }
        _ = try await call("forward_message", ["id": "10", "to": ["a@b.c"]], on: fake)
        let body = try #require(fake.read(\.composed)).mail.body
        #expect(body.hasSuffix("(The original text was cut at 100000 characters.)"))
        #expect(body.contains("Subject: S"))
    }

    @Test func forwardOpensMailAndReadsTheMessageThroughMailWithoutFullDiskAccess() async throws {
        defer { cleanUp() }
        let fake = store {
            $0.running = false
            $0.fullDiskAccess = false
            $0.scriptedMessage = Self.original
        }
        let args: [String: Value] = [
            "id": "10", "to": ["a@b.c"], "in_mailbox": "INBOX", "in_account": "ACC1", "include_attachments": false,
        ]
        _ = try await call("forward_message", args, on: fake)
        #expect(fake.read(\.launches) == 1)
        #expect(fake.read(\.calls).contains("scriptedMessage"))
        #expect(fake.read(\.composed)?.mail.subject == "Fwd: Quarterly report")
        // Without a place and without the index, the message cannot be found.
        let lost = await failure("forward_message", ["id": "10", "to": ["a@b.c"]], on: fake)
        #expect(lost?.code == .permissionDenied)
    }

    @Test func lateConfirmedForwardSaysTheMessageMayBeSent() async {
        defer { cleanUp() }
        let fake = store { $0.writeDelay = 2 }
        let slow = MailModule(store: fake, backendTimeout: 0.1, writeTimeout: 0.2, attachmentRoot: root)
        do {
            _ = try await slow.call(
                "forward_message",
                Arguments(["id": "10", "to": ["a@b.c"], "confirm": true, "include_attachments": false]))
            Issue.record("expected a timeout")
        } catch {
            #expect(error as? ToolError == MailModule.sendTimeout)
        }
    }

    // MARK: attachments on send_mail and create_draft

    @Test func sendMailAndCreateDraftCarryTheFiles() async throws {
        defer { cleanUp() }
        let one = try tempFile("one.pdf")
        let two = try tempFile("two.txt")
        let fake = store()
        let output = try await call(
            "send_mail",
            [
                "to": ["a@b.c"], "subject": "s", "body": "b", "confirm": true,
                "attachments": .array([.string(one), .string(two)]),
            ], on: fake)
        #expect(fake.read(\.composed)?.mail.attachments == [one, two])
        #expect(output.text.contains("Attached: one.pdf, two.txt."))
        #expect(names(object(output)["attached"]) == ["one.pdf", "two.txt"])

        let draft = try await call(
            "create_draft", ["subject": "s", "body": "b", "attachments": .array([.string(one)])], on: fake)
        #expect(fake.read(\.composed)?.send == false && fake.read(\.composed)?.mail.attachments == [one])
        #expect(draft.text.contains("Attached: one.pdf."))
        // Without files nothing changes.
        let plain = try await call("create_draft", ["subject": "s", "body": "b"], on: fake)
        #expect(!plain.text.contains("Attached") && object(plain)["attached"] == nil)
        #expect(fake.read(\.composed)?.mail.attachments == [])
    }

    @Test func badFilesNeverReachMail() async throws {
        defer { cleanUp() }
        let fake = store { $0.running = false }
        let folder = root.path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cases: [(Value, ToolError.Code)] = [
            (["/nonexistent/x.txt"], .notFound), ([.string(folder)], .invalidInput),
            (["relative.txt"], .invalidInput),
            (.array(Array(repeating: .string("/etc/hosts"), count: 11)), .invalidInput),
        ]
        for tool in ["send_mail", "create_draft"] {
            for (files, code) in cases {
                let error = await failure(
                    tool, ["to": ["a@b.c"], "subject": "s", "body": "b", "attachments": files], on: fake)
                #expect(error?.code == code, "\(tool) \(files)")
            }
        }
        // Mail was neither opened nor called.
        #expect(fake.read(\.launches) == 0 && fake.read(\.calls).isEmpty && fake.read(\.composed) == nil)
    }

    @Test func filesAboveTheModuleLimitAreRefused() async throws {
        defer { cleanUp() }
        let big = try tempFile("big.bin", bytes: 20)
        let fake = store()
        do {
            _ = try await call(
                "create_draft", ["subject": "s", "body": "b", "attachments": .array([.string(big)])], on: fake,
                limit: 10)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .invalidInput)
        }
        #expect(fake.read(\.composed) == nil)
    }

    @Test func descriptionsMentionTheNewInput() {
        let specs = Dictionary(uniqueKeysWithValues: MailModule.toolSpecs.map { ($0.tool.name, $0) })
        for name in ["send_mail", "create_draft", "forward_message"] {
            let properties = specs[name]?.tool.inputSchema.objectValue?["properties"]?.objectValue
            #expect(properties?["attachments"] != nil, "\(name)")
        }
        let forward = specs["forward_message"]
        #expect(forward?.tool.description?.contains("Fwd:") == true)
        #expect(forward?.tool.annotations.destructiveHint == true)
        let required = forward?.tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["id", "to"])
    }
}
