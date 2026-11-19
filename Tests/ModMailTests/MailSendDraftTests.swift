import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModMail

/// `send_draft` with a fake store. Saved files go to a temp folder, never to the real cache.
@Suite struct MailSendDraftTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "applesauce-send-draft-\(UUID().uuidString)", isDirectory: true)

    static let ref = MessageRef(id: "50", accountId: "ACC1", mailbox: "Drafts")

    static func draft(
        to: [String] = ["bob@example.com"], cc: [String] = ["cc@example.com"], bcc: [String] = ["hidden@example.com"],
        attachments: [String] = ["plan.pdf"], body: String? = "Hello Bob", truncated: Bool = false,
        senderAddress: String = "me@work.example", sender: String = "Me <me@work.example>"
    ) -> DraftMessage {
        let message = MailMessage(
            id: "50", subject: "Plan", from: sender, to: to, cc: cc, date: nil, mailbox: "Drafts", accountId: "ACC1",
            read: true, flagged: false, messageId: nil, body: body, bodySource: "applescript", truncated: truncated,
            partial: false, attachments: attachments.map { MailAttachment(name: $0, size: 10) }, note: nil)
        return DraftMessage(message: message, bcc: bcc, senderAddress: senderAddress)
    }

    func store(
        mailbox: String = "Drafts", _ edit: (inout FakeMailStore.State) -> Void = { _ in }
    ) -> FakeMailStore {
        var state = FakeMailStore.State()
        state.draft = Self.draft()
        state.refs = ["50": MessageRef(id: "50", accountId: "ACC1", mailbox: mailbox)]
        edit(&state)
        return FakeMailStore(state)
    }

    func call(_ args: [String: Value], on store: FakeMailStore) async throws -> ToolOutput {
        try await MailModule(store: store, attachmentRoot: root).call("send_draft", Arguments(args))
    }

    func failure(_ args: [String: Value], on store: FakeMailStore) async -> ToolError? {
        do {
            _ = try await call(args, on: store)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func object(_ output: ToolOutput) -> [String: Value] { output.structured?.objectValue ?? [:] }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    // MARK: input

    @Test func badInputNeverReachesTheStore() async {
        let fake = store()
        let bad: [[String: Value]] = [
            [:], ["id": "abc"], ["id": "1 OR 1=1"], ["id": "50", "confirm": "true"],
            ["id": "50", "in_mailbox": "Drafts"],
        ]
        for args in bad {
            let error = await failure(args, on: fake)
            #expect(error?.code == .invalidInput, "\(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func isDraftsNames() {
        for name in ["Drafts", "drafts", "[Gmail]/Drafts", "Draft Messages", "Work/Drafts"] {
            #expect(MailModule.isDrafts(name), "\(name)")
        }
        for name in ["INBOX", "Sent Messages", "Drafts/Old stuff", "Trash", "Draftsman"] {
            #expect(!MailModule.isDrafts(name), "\(name)")
        }
    }

    @Test func aMessageOutsideDraftsIsRefusedBeforeItIsRead() async {
        let fake = store(mailbox: "INBOX")
        for confirm: Bool in [false, true] {
            let error = await failure(["id": "50", "confirm": .bool(confirm)], on: fake)
            #expect(error?.code == .invalidInput)
            #expect(error?.message.contains("not in a Drafts mailbox") == true)
            #expect(error?.message.contains("Nothing was sent") == true)
        }
        #expect(!fake.read(\.calls).contains("draft"))
        #expect(fake.read(\.composed) == nil)
    }

    // MARK: confirm gate

    @Test func withoutConfirmNothingIsSentAndTheDraftIsShown() async throws {
        defer { cleanUp() }
        for confirm: Value? in [nil, false] {
            let fake = store()
            var args: [String: Value] = ["id": "50"]
            if let confirm { args["confirm"] = confirm }
            let output = try await call(args, on: fake)
            let data = object(output)
            #expect(data["confirm_required"]?.boolValue == true)
            #expect(data["sent"]?.boolValue == false)
            #expect(data["subject"]?.stringValue == "Plan")
            #expect(data["from"]?.stringValue == "Me <me@work.example>")
            #expect(data["to"]?.arrayValue?.compactMap(\.stringValue) == ["bob@example.com"])
            #expect(data["cc"]?.arrayValue?.compactMap(\.stringValue) == ["cc@example.com"])
            #expect(data["bcc"]?.arrayValue?.compactMap(\.stringValue) == ["hidden@example.com"])
            #expect(data["attached"]?.arrayValue?.compactMap(\.stringValue) == ["plan.pdf"])
            for part in ["Subject: Plan", "From: Me <me@work.example>", "To: bob@example.com", "Cc: cc@example.com"] {
                #expect(output.text.contains(part), "\(part)")
            }
            #expect(output.text.contains("Bcc: hidden@example.com"))
            #expect(output.text.contains("Attachments: plan.pdf"))
            #expect(fake.read(\.composed) == nil)
            #expect(fake.read(\.deleted) == nil)
            #expect(!fake.read(\.calls).contains("saveAttachment"))
        }
    }

    // MARK: send

    @Test func confirmBuildsANewMessageSendsItAndDeletesTheDraft() async throws {
        defer { cleanUp() }
        let fake = store()
        let output = try await call(["id": "50", "confirm": true], on: fake)
        let composed = try #require(fake.read(\.composed))
        #expect(composed.send == true)
        let mail = composed.mail
        #expect(mail.subject == "Plan" && mail.body == "Hello Bob")
        #expect(mail.to == ["bob@example.com"] && mail.cc == ["cc@example.com"] && mail.bcc == ["hidden@example.com"])
        #expect(mail.from == "me@work.example")
        #expect(mail.attachments.count == 1 && mail.attachments[0].hasSuffix("notes.txt"))
        #expect(FileManager.default.fileExists(atPath: mail.attachments[0]))
        // The old draft goes after the send, and only that one.
        #expect(fake.read(\.deleted) == [Self.ref])
        let calls = fake.read(\.calls)
        let composeAt = try #require(calls.firstIndex(of: "compose"))
        let deleteAt = try #require(calls.firstIndex(of: "delete"))
        #expect(composeAt < deleteAt)
        let data = object(output)
        #expect(data["sent"]?.boolValue == true)
        #expect(data["path"]?.stringValue == "rebuild")
        #expect(data["draft_deleted"]?.boolValue == true)
        #expect(data["confirm_required"] == nil)
        #expect(output.text.hasPrefix("Sent draft 50 from me@work.example"))
    }

    @Test func senderMatchIgnoresCaseAndUsesTheAccountSpelling() async throws {
        defer { cleanUp() }
        let fake = store { $0.draft = Self.draft(attachments: [], senderAddress: "ME@Work.Example") }
        _ = try await call(["id": "50", "confirm": true], on: fake)
        #expect(fake.read(\.composed)?.mail.from == "me@work.example")
        #expect(fake.read(\.composed)?.mail.attachments == [])
        #expect(!fake.read(\.calls).contains("saveAttachment"))
    }

    @Test func aSendThatFailsKeepsTheDraft() async throws {
        defer { cleanUp() }
        let failed = ToolError(.internalError, "Mail said no.")
        let fake = store { $0.composeError = failed }
        let error = await failure(["id": "50", "confirm": true], on: fake)
        #expect(error?.message == "Mail said no.")
        #expect(fake.read(\.deleted) == nil)
    }

    @Test func aTimedOutSendKeepsTheDraftAndWarns() async throws {
        defer { cleanUp() }
        // The delay is far above the limit. The test passes when the timeout answers before the work ends.
        let fake = store { $0.writeDelay = 30 }
        let module = MailModule(store: fake, writeTimeout: 0.5, attachmentRoot: root)
        do {
            _ = try await module.call("send_draft", Arguments(["id": "50", "confirm": true]))
            Issue.record("The call should time out.")
        } catch let error as ToolError {
            #expect(error.code == .timeout)
            #expect(error.message.contains("may have been sent"))
        }
        #expect(fake.read(\.deleted) == nil)
    }

    @Test func aFailedDeleteAfterTheSendIsANoteNotAnError() async throws {
        defer { cleanUp() }
        let fake = store { $0.deleteError = ToolError(.internalError, "Mail could not delete.") }
        let output = try await call(["id": "50", "confirm": true], on: fake)
        let data = object(output)
        #expect(data["sent"]?.boolValue == true)
        #expect(data["draft_deleted"]?.boolValue == false)
        #expect(data["note"]?.stringValue?.contains("could not be deleted") == true)
        #expect(output.text.contains("can be sent twice"))
    }

    // MARK: refusals with confirm

    @Test func aDraftWithoutRecipientsIsRefused() async {
        defer { cleanUp() }
        let fake = store { $0.draft = Self.draft(to: [], cc: [], bcc: []) }
        let error = await failure(["id": "50", "confirm": true], on: fake)
        #expect(error?.code == .invalidInput)
        #expect(error?.message.contains("no recipient") == true)
        #expect(fake.read(\.composed) == nil)
    }

    @Test func aBccOnlyDraftIsSent() async throws {
        defer { cleanUp() }
        let fake = store { $0.draft = Self.draft(to: [], cc: [], attachments: []) }
        _ = try await call(["id": "50", "confirm": true], on: fake)
        #expect(fake.read(\.composed)?.mail.bcc == ["hidden@example.com"])
    }

    @Test func aCutOrMissingTextIsNotSent() async {
        defer { cleanUp() }
        for draft in [Self.draft(body: "cut", truncated: true), Self.draft(body: nil)] {
            let fake = store { $0.draft = draft }
            let error = await failure(["id": "50", "confirm": true], on: fake)
            #expect(error?.code == .invalidInput)
            #expect(error?.message.contains("Nothing was sent") == true)
            #expect(fake.read(\.composed) == nil)
        }
    }

    @Test func aSenderThatIsNoAccountAddressIsRefused() async {
        defer { cleanUp() }
        let fake = store { $0.draft = Self.draft(senderAddress: "other@example.com") }
        let error = await failure(["id": "50", "confirm": true], on: fake)
        #expect(error?.code == .invalidInput)
        #expect(error?.message.contains("other@example.com") == true)
        #expect(fake.read(\.composed) == nil)
        #expect(fake.read(\.deleted) == nil)
    }

    @Test func anEmptySenderUsesTheOnlyAddress() async throws {
        defer { cleanUp() }
        let fake = store { $0.draft = Self.draft(attachments: [], senderAddress: "", sender: "") }
        _ = try await call(["id": "50", "confirm": true], on: fake)
        #expect(fake.read(\.composed)?.mail.from == "me@work.example")
    }

    @Test func anAttachmentThatCannotBeFetchedStopsTheSend() async {
        defer { cleanUp() }
        let fake = store {
            $0.draft = Self.draft(attachments: ["a.pdf", "b.pdf"])
            $0.attachmentFailures = [2: ToolError(.notFound, "Mail has not downloaded it.")]
        }
        let error = await failure(["id": "50", "confirm": true], on: fake)
        #expect(error?.code == .notFound)
        #expect(error?.message.contains("b.pdf") == true)
        #expect(error?.message.contains("Nothing was sent") == true)
        #expect(fake.read(\.composed) == nil)
        #expect(fake.read(\.deleted) == nil)
    }

    // MARK: script output

    @Test func mailWithoutAccountAddressesIsNotCalledAnUnknownSender() async {
        // While Mail starts, the store knows only the account ids from the index.
        let fake = store { $0.accounts = [MailAccount(id: "ACC1", name: "ACC1", emails: [])] }
        let error = await failure(["id": "50", "confirm": true], on: fake)
        #expect(error?.code == .appNotRunning)
        #expect(fake.read(\.calls).filter { $0 == "accounts" }.count == 2)
        #expect(!fake.read(\.calls).contains("compose"))
        #expect(!fake.read(\.calls).contains("delete"))
        cleanUp()
    }

    @Test func parsesTheDraftRecord() throws {
        let fs = "\u{1F}"
        let attachments = "a.pdf\u{1C}2048\u{1D}b.png\u{1C}7"
        let text = [
            "Plan", "Me <me@work.example>", "me@work.example", "bob@example.com,eve@example.com", "cc@example.com",
            "hidden@example.com", attachments, "Hello\u{FFFC}\nBob",
        ].joined(separator: fs)
        let draft = try #require(MailScripts.parseDraft(text, ref: Self.ref))
        #expect(draft.message.subject == "Plan")
        #expect(draft.message.from == "Me <me@work.example>")
        #expect(draft.senderAddress == "me@work.example")
        #expect(draft.message.to == ["bob@example.com", "eve@example.com"])
        #expect(draft.message.cc == ["cc@example.com"])
        #expect(draft.bcc == ["hidden@example.com"])
        #expect(
            draft.message.attachments == [
                MailAttachment(name: "a.pdf", size: 2048), MailAttachment(name: "b.png", size: 7),
            ])
        #expect(draft.message.body == "Hello\nBob")
        #expect(draft.message.mailbox == "Drafts" && draft.message.accountId == "ACC1")
    }

    @Test func aBodyWithTheFieldSeparatorStaysWhole() throws {
        let fs = "\u{1F}"
        let text = ["S", "", "", "", "", "", "", "one\(fs)two"].joined(separator: fs)
        #expect(MailScripts.parseDraft(text, ref: Self.ref)?.message.body == "one\(fs)two")
        #expect(MailScripts.parseDraft("only\(fs)three\(fs)fields", ref: Self.ref) == nil)
    }

    @Test func descriptionStatesTheConfirmRule() throws {
        let spec = try #require(MailModule.toolSpecs.first { $0.tool.name == "send_draft" })
        #expect(spec.isWrite && spec.tool.annotations.destructiveHint == true)
        let description = try #require(spec.tool.description)
        #expect(description.contains("Without 'confirm' true nothing is sent"))
        #expect(description.contains("Sending cannot be undone"))
    }
}
