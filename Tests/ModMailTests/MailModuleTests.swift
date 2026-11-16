import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModMail

@Suite struct MailModuleTests {
    static let summary = MessageSummary(
        id: "10", subject: "Hello", from: "Ann <ann@example.com>", date: Date(timeIntervalSince1970: 1_700_000_000),
        mailbox: "INBOX", accountId: "ACC1", read: false, flagged: true, hasAttachments: false)

    static let message = MailMessage(
        id: "10", subject: "Hello", from: "Ann <ann@example.com>", to: ["me@work.example"], cc: [],
        date: Date(timeIntervalSince1970: 1_700_000_000), mailbox: "INBOX", accountId: "ACC1", read: false,
        flagged: false, messageId: "<a@b>", body: "Body text", bodySource: "emlx", truncated: false, partial: false,
        attachments: [MailAttachment(name: "a.pdf", size: 2048)], note: nil)

    func store(_ edit: (inout FakeMailStore.State) -> Void = { _ in }) -> FakeMailStore {
        var state = FakeMailStore.State()
        state.indexPage = SearchPage(items: [Self.summary], truncated: false)
        state.scriptedPage = SearchPage(items: [Self.summary], truncated: false)
        state.message = Self.message
        state.refs = [
            "10": MessageRef(id: "10", accountId: "ACC1", mailbox: "INBOX"),
            "11": MessageRef(id: "11", accountId: "ACC1", mailbox: "[Gmail]/All Mail"),
        ]
        edit(&state)
        return FakeMailStore(state)
    }

    func module(_ store: FakeMailStore, backendTimeout: Double = 30, writeTimeout: Double = 60) -> MailModule {
        MailModule(store: store, backendTimeout: backendTimeout, writeTimeout: writeTimeout)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeMailStore) async throws -> ToolOutput {
        try await module(store).call(tool, Arguments(args))
    }

    func failure(
        _ tool: String, _ args: [String: Value], on store: FakeMailStore, using module: MailModule? = nil
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
        let mail = module(store())
        #expect(
            mail.tools.map(\.tool.name) == [
                "list_accounts", "list_mailboxes", "search_mail", "get_message", "create_draft", "send_mail", "reply",
                "move_message", "flag_message", "mark_read", "delete_message",
            ])
        #expect(
            Set(mail.tools.filter(\.isWrite).map(\.tool.name)) == [
                "create_draft", "send_mail", "reply", "move_message", "flag_message", "mark_read", "delete_message",
            ])
        let destructive = mail.tools.filter { $0.tool.annotations.destructiveHint == true }.map(\.tool.name)
        #expect(Set(destructive) == ["send_mail", "reply", "move_message", "delete_message"])
        #expect(mail.name == "mail")
        #expect(mail.permissions == [.automationMail, .fullDiskAccess])
    }

    @Test func readOnlyRegistryHidesWriteTools() async throws {
        let config = try Config.parse(arguments: ["--read-only"], environment: [:])
        let registry = try Registry(available: [module(store())], config: config)
        #expect(registry.tools.map(\.name) == ["list_accounts", "list_mailboxes", "search_mail", "get_message"])
        let result = await registry.call("send_mail", arguments: ["to": ["a@b.c"], "subject": "s", "body": "b"])
        #expect(result.isError == true)
    }

    // MARK: input checks

    @Test func badInputNeverReachesTheStore() async {
        let fake = store()
        let bad: [(String, [String: Value])] = [
            ("search_mail", ["query": ""]),
            ("search_mail", ["limit": 0]),
            ("search_mail", ["limit": 201]),
            ("search_mail", ["since": "yesterday"]),
            ("search_mail", ["before": "2026-13-01"]),
            ("search_mail", ["since": "2026-11-12", "before": "2026-11-01"]),
            ("search_mail", ["unread": "yes"]),
            ("get_message", [:]),
            ("get_message", ["id": "abc"]),
            ("get_message", ["id": "1 OR 1=1"]),
            ("get_message", ["id": "5", "in_mailbox": "INBOX"]),
            ("create_draft", ["subject": "s"]),
            ("create_draft", ["subject": "s", "body": "b", "to": ["nobody"]]),
            ("create_draft", ["subject": "s", "body": "b", "cc": ["a b@c.d"]]),
            ("create_draft", ["subject": "s", "body": "b", "bcc": "a@b.c"]),
            ("send_mail", ["subject": "s", "body": "b"]),
            ("send_mail", ["to": [], "subject": "s", "body": "b"]),
            ("send_mail", ["to": ["bad"], "subject": "s", "body": "b"]),
            ("send_mail", ["to": ["a@b.c"], "subject": "s", "body": "b", "confirm": "true"]),
            ("reply", ["id": "10"]),
            ("reply", ["id": "x", "body": "b"]),
            ("move_message", ["ids": ["10"]]),
            ("move_message", ["mailbox": "Archive"]),
            ("move_message", ["ids": [], "mailbox": "Archive"]),
            ("flag_message", ["ids": ["10"]]),
            ("mark_read", ["ids": ["10"]]),
            ("mark_read", ["ids": ["10", "x"], "read": true]),
            ("delete_message", ["ids": "10"]),
        ]
        for (tool, args) in bad {
            let error = await failure(tool, args, on: fake)
            #expect(error?.code == .invalidInput, "\(tool) \(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func batchLimitIs100() async {
        let fake = store()
        let many = (1...101).map { Value.string(String($0)) }
        for tool in ["delete_message", "flag_message", "mark_read", "move_message"] {
            let error = await failure(
                tool, ["ids": .array(many), "mailbox": "A", "flagged": true, "read": true], on: fake)
            #expect(error?.code == .invalidInput && error?.message.contains("101") == true, "\(tool)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    // MARK: read tools

    @Test func listAccountsAndMailboxes() async throws {
        let fake = store {
            $0.mailboxes = [
                MailboxInfo(name: "INBOX", path: "INBOX", accountId: "ACC1", account: "Work", unread: 3),
                MailboxInfo(name: "INBOX", path: "INBOX", accountId: "ACC2", account: "Home", unread: nil),
            ]
        }
        let accounts = try await run("list_accounts", [:], on: fake)
        #expect(accounts.text.hasPrefix("2 accounts."))
        #expect(object(accounts)["accounts"]?.arrayValue?.count == 2)
        let all = try await run("list_mailboxes", [:], on: fake)
        #expect(object(all)["mailboxes"]?.arrayValue?.count == 2)
        let one = try await run("list_mailboxes", ["account": "work"], on: fake)
        let boxes = object(one)["mailboxes"]?.arrayValue ?? []
        #expect(boxes.count == 1)
        #expect(boxes.first?.objectValue?["unread"]?.intValue == 3)
        #expect(boxes.first?.objectValue?["account_id"]?.stringValue == "ACC1")
        let error = await failure("list_mailboxes", ["account": "Nope"], on: fake)
        #expect(error?.code == .notFound)
    }

    @Test func searchUsesTheFastIndexWhenAvailable() async throws {
        let fake = store()
        let output = try await run(
            "search_mail",
            [
                "query": " hello ", "from": "ann", "mailbox": "INBOX", "account": "Work", "unread": true,
                "has_attachments": false, "since": "2026-11-01", "before": "2026-11-12T10:00:00Z", "limit": 5,
            ], on: fake)
        let query = try #require(fake.read(\.searchQuery))
        #expect(query.text == "hello" && query.from == "ann" && query.mailbox == "INBOX")
        #expect(query.account == "ACC1" && query.unread == true && query.hasAttachments == false)
        #expect(query.limit == 5 && query.since != nil && query.before != nil)
        #expect(fake.read(\.calls).contains("searchScripted") == false)
        #expect(object(output)["source"]?.stringValue == "index")
        #expect(object(output)["count"]?.intValue == 1)
        #expect(output.text.contains("- 10 |") && output.text.contains("[unread, flagged]"))
    }

    @Test func searchDefaultsAndTruncation() async throws {
        let fake = store { $0.indexPage = SearchPage(items: [Self.summary], truncated: true) }
        let output = try await run("search_mail", [:], on: fake)
        #expect(fake.read(\.searchQuery)?.limit == 25)
        #expect(object(output)["truncated"]?.boolValue == true)
        #expect(output.text.contains("Raise 'limit'"))
        #expect(output.text.contains("[unread, flagged]"))
    }

    @Test func withoutFullDiskAccessSearchFallsBackToTheScopedSearch() async throws {
        let fake = store { $0.fullDiskAccess = false }
        let output = try await run("search_mail", ["mailbox": "INBOX", "query": "hello"], on: fake)
        #expect(fake.read(\.calls).contains("searchIndex") == false)
        let query = try #require(fake.read(\.scriptedQuery))
        // The default range is the last 30 days.
        let since = try #require(query.since)
        let before = try #require(query.before)
        let days = before.timeIntervalSince(since) / 86400
        #expect(abs(days - 30) < 0.01)
        #expect(abs(before.timeIntervalSinceNow) < 60)
        #expect(object(output)["source"]?.stringValue == "applescript")
        let fix = Permission.fullDiskAccess.fix(for: .denied) ?? ""
        #expect(object(output)["fix"]?.stringValue?.contains(fix) == true)
        #expect(output.text.contains("slower scoped search"))
        #expect(output.text.contains(fix))
    }

    @Test func scopedSearchKeepsGivenRangeAndNeedsAMailbox() async throws {
        let fake = store { $0.fullDiskAccess = false }
        _ = try await run("search_mail", ["mailbox": "INBOX", "since": "2026-10-01", "before": "2026-10-05"], on: fake)
        let query = try #require(fake.read(\.scriptedQuery))
        #expect(query.since == ISODate.parse("2026-10-01")?.date && query.before == ISODate.parse("2026-10-05")?.date)

        let none = await failure("search_mail", ["query": "x"], on: fake)
        #expect(none?.code == .permissionDenied)
        #expect(none?.fix?.contains(Permission.fullDiskAccess.fix(for: .denied) ?? "?") == true)
        #expect(none?.fix?.contains("mailbox") == true)

        for args: [String: Value] in [
            ["mailbox": "INBOX", "to": "bob"], ["mailbox": "INBOX", "has_attachments": true],
        ] {
            let error = await failure("search_mail", args, on: fake)
            #expect(error?.code == .invalidInput)
        }
        #expect(fake.read(\.calls).filter { $0 == "searchScripted" }.count == 1)
    }

    @Test func indexTroubleFallsBackButOtherErrorsDoNot() async throws {
        let schema = ToolError(.internalError, "The Mail index has no column 'messages.read'.", fix: "Report.")
        let fake = store { $0.indexError = schema }
        let output = try await run("search_mail", ["mailbox": "INBOX"], on: fake)
        #expect(object(output)["source"]?.stringValue == "applescript")
        let denied = store { $0.indexError = .permission(.fullDiskAccess, state: .denied) }
        #expect(try await run("search_mail", ["mailbox": "INBOX"], on: denied).text.contains("slower"))
        // No mailbox: the error says why, and keeps the fix.
        let error = await failure("search_mail", [:], on: fake)
        #expect(error?.code == .permissionDenied && error?.message.contains("messages.read") == true)
        // A mailbox that does not exist is not an index problem.
        let missing = store { $0.indexError = ToolError(.notFound, "No mailbox is named 'X'.") }
        #expect(await failure("search_mail", ["mailbox": "X"], on: missing)?.code == .notFound)
        #expect(missing.read(\.calls).contains("searchScripted") == false)
    }

    // MARK: get_message

    @Test func getMessageReadsFromTheIndexAndFile() async throws {
        let fake = store()
        let output = try await run("get_message", ["id": "10"], on: fake)
        #expect(fake.read(\.calls) == ["indexMessage"])
        #expect(output.text.contains("Subject: Hello") && output.text.contains("Body text"))
        #expect(output.text.contains("a.pdf (2 KB)"))
        let data = object(output)
        #expect(data["body_source"]?.stringValue == "emlx")
        #expect(data["attachments"]?.arrayValue?.first?.objectValue?["size"]?.intValue == 2048)
        // A number id works too.
        _ = try await run("get_message", ["id": 10], on: fake)
    }

    @Test func getMessageAsksMailWhenTheFileIsMissing() async throws {
        var noBody = Self.message
        noBody = MailMessage(
            id: "10", subject: "Hello", from: "Ann", to: [], cc: [], date: nil, mailbox: "INBOX", accountId: "ACC1",
            read: true, flagged: false, messageId: nil, body: nil, bodySource: "none", truncated: false,
            partial: false, attachments: [], note: "file missing")
        var scripted = Self.message
        scripted = MailMessage(
            id: "10", subject: "Hello", from: "Ann", to: [], cc: [], date: nil, mailbox: "INBOX", accountId: "ACC1",
            read: true, flagged: false, messageId: nil, body: "From Mail", bodySource: "applescript",
            truncated: false, partial: false, attachments: [MailAttachment(name: "x.png", size: 9)], note: nil)
        let fake = store {
            $0.message = noBody
            $0.scriptedMessage = scripted
        }
        let output = try await run("get_message", ["id": "10"], on: fake)
        #expect(fake.read(\.calls) == ["indexMessage", "scriptedMessage"])
        #expect(output.text.contains("From Mail"))
        #expect(object(output)["body_source"]?.stringValue == "applescript")

        // Mail is closed: the headers still come back, with a note.
        let closed = store {
            $0.message = noBody
            $0.running = false
        }
        let partial = try await run("get_message", ["id": "10"], on: closed)
        #expect(object(partial)["body"] == nil)
        #expect(partial.text.contains("Open Mail"))
    }

    @Test func getMessageWithoutFullDiskAccess() async throws {
        let fake = store {
            $0.fullDiskAccess = false
            $0.scriptedMessage = Self.message
        }
        let error = await failure("get_message", ["id": "10"], on: fake)
        #expect(error?.code == .permissionDenied)
        #expect(error?.fix?.contains("in_mailbox") == true)
        let output = try await run(
            "get_message", ["id": "10", "in_mailbox": "INBOX", "in_account": "ACC1"], on: fake)
        #expect(fake.read(\.calls) == ["scriptedMessage"])
        #expect(output.text.contains("Subject: Hello"))
        // Mail is closed: applesauce opens it, then reads the message.
        let closed = store {
            $0.fullDiskAccess = false
            $0.running = false
            $0.scriptedMessage = Self.message
        }
        let reopened = try await run(
            "get_message", ["id": "10", "in_mailbox": "INBOX", "in_account": "A"], on: closed)
        #expect(closed.read(\.launches) == 1 && reopened.text.contains("Subject: Hello"))
        let stuck = store {
            $0.fullDiskAccess = false
            $0.running = false
            $0.launchFails = true
        }
        let notRunning = await failure(
            "get_message", ["id": "10", "in_mailbox": "INBOX", "in_account": "A"], on: stuck)
        #expect(notRunning?.code == .appNotRunning && notRunning?.fix?.contains("try again") == true)
    }

    @Test func unknownIdIsNotFound() async {
        let fake = store { $0.message = nil }
        #expect(await failure("get_message", ["id": "99"], on: fake)?.code == .notFound)
    }

    // MARK: drafts and sending

    @Test func createDraftSavesButNeverSends() async throws {
        let fake = store()
        let output = try await run(
            "create_draft",
            ["to": [" a@b.c "], "cc": ["d@e.f"], "bcc": ["g@h.i"], "subject": "Hi", "body": "Text"], on: fake)
        let composed = try #require(fake.read(\.composed))
        #expect(composed.send == false)
        #expect(
            composed.mail
                == OutgoingMail(
                    to: ["a@b.c"], cc: ["d@e.f"], bcc: ["g@h.i"], subject: "Hi", body: "Text", from: "me@work.example"))
        #expect(output.text.contains("Draft saved"))
        // A draft may have no recipient.
        _ = try await run("create_draft", ["subject": "Hi", "body": "Text"], on: fake)
        #expect(fake.read(\.composed)?.mail.to == [])
    }

    @Test func sendMailSendsOnlyWithConfirmTrue() async throws {
        let args: [String: Value] = ["to": ["a@b.c"], "subject": "Hi", "body": "Text"]
        for confirm: Value? in [nil, false] {
            let fake = store()
            var withConfirm = args
            if let confirm { withConfirm["confirm"] = confirm }
            let output = try await run("send_mail", withConfirm, on: fake)
            #expect(fake.read(\.composed)?.send == false)
            #expect(output.text.contains("Not sent") && output.text.contains("draft"))
            #expect(object(output)["sent"]?.boolValue == false)
            #expect(object(output)["draft_saved"]?.boolValue == true)
        }
        let fake = store()
        var confirmed = args
        confirmed["confirm"] = true
        let output = try await run("send_mail", confirmed, on: fake)
        #expect(fake.read(\.composed)?.send == true)
        #expect(output.text.hasPrefix("Sent from me@work.example to a@b.c"))
        #expect(object(output)["sent"]?.boolValue == true)
    }

    // MARK: sender

    private func twoAccounts(_ state: inout FakeMailStore.State) {
        state.accounts = [
            MailAccount(id: "ACC1", name: "Work", emails: ["me@work.example"]),
            MailAccount(id: "ACC2", name: "Home", emails: ["me@home.example", "alias@home.example"]),
        ]
    }

    @Test func oneAccountSendsWithoutAsking() async throws {
        let fake = store()
        let output = try await run(
            "send_mail", ["to": ["a@b.c"], "subject": "s", "body": "b", "confirm": true], on: fake)
        #expect(fake.read(\.composed)?.mail.from == "me@work.example")
        #expect(output.text.hasPrefix("Sent from me@work.example to a@b.c"))
    }

    @Test func severalAccountsWithoutFromAreAmbiguousAndNothingIsSent() async throws {
        let fake = store { twoAccounts(&$0) }
        for tool in ["send_mail", "create_draft"] {
            let error = await failure(
                tool, ["to": ["a@b.c"], "subject": "s", "body": "b", "confirm": true], on: fake)
            #expect(error?.code == .ambiguous, "\(tool)")
            #expect(error?.message.contains("me@home.example") == true && error?.fix?.contains("Ask the user") == true)
        }
        #expect(fake.read(\.composed) == nil)
    }

    @Test func fromPicksTheSender() async throws {
        let fake = store { twoAccounts(&$0) }
        _ = try await run("create_draft", ["subject": "s", "body": "b", "from": "Work"], on: fake)
        #expect(fake.read(\.composed)?.mail.from == "me@work.example")
        _ = try await run("create_draft", ["subject": "s", "body": "b", "from": "ALIAS@home.example"], on: fake)
        #expect(fake.read(\.composed)?.mail.from == "alias@home.example")
        // An account with two addresses does not say which one.
        let twoAddresses = await failure("create_draft", ["subject": "s", "body": "b", "from": "Home"], on: fake)
        #expect(twoAddresses?.code == .ambiguous)
        let unknown = await failure("create_draft", ["subject": "s", "body": "b", "from": "x@y.z"], on: fake)
        #expect(unknown?.code == .notFound)
    }

    @Test func deleteDescriptionWarnsAboutTheTrash() {
        let tool = module(store()).tools.first { $0.tool.name == "delete_message" }
        let description = tool?.tool.description ?? ""
        #expect(description.contains("already in the Trash (that delete is final), needs 'confirm' true"))
    }

    @Test func tooLongBodiesAreRefusedBeforeMail() async throws {
        let fake = store()
        let big = String(repeating: "a", count: MailModule.bodyInputLimit + 1)
        let calls: [(String, [String: Value])] = [
            ("create_draft", ["subject": "s", "body": .string(big)]),
            ("send_mail", ["to": ["a@b.c"], "subject": "s", "body": .string(big), "confirm": true]),
            ("reply", ["id": "10", "body": .string(big), "confirm": true]),
        ]
        for (tool, args) in calls {
            let error = await failure(tool, args, on: fake)
            #expect(error?.code == .invalidInput, "\(tool)")
            #expect(error?.message.contains("'body' is too long") == true, "\(tool)")
        }
        #expect(fake.read(\.calls).isEmpty)
        // A body at the limit passes.
        let ok = String(repeating: "a", count: MailModule.bodyInputLimit)
        _ = try await run("create_draft", ["subject": "s", "body": .string(ok)], on: fake)
        #expect(fake.read(\.composed)?.mail.body.count == MailModule.bodyInputLimit)
    }

    static let writeCalls: [(String, [String: Value])] = [
        ("create_draft", ["subject": "s", "body": "b"]),
        ("send_mail", ["to": ["a@b.c"], "subject": "s", "body": "b", "confirm": true]),
        ("reply", ["id": "10", "body": "b"]),
        ("move_message", ["ids": ["10"], "mailbox": "A"]),
        ("flag_message", ["ids": ["10"], "flagged": true]),
        ("mark_read", ["ids": ["10"], "read": true]),
        ("delete_message", ["ids": ["10"]]),
    ]

    @Test func writesOpenMailWhenItIsClosedAndLeaveItRunning() async throws {
        for (tool, args) in Self.writeCalls {
            let fake = store { $0.running = false }
            _ = try await run(tool, args, on: fake)
            #expect(fake.read(\.launches) == 1 && fake.read(\.running), "\(tool)")
            #expect(fake.read(\.calls).isEmpty == false, "\(tool)")
        }
        // Mail is open already: nothing is started.
        let open = store()
        _ = try await run("mark_read", ["ids": ["10"], "read": true], on: open)
        #expect(open.read(\.launches) == 0)
    }

    @Test func writesFailWithAFixWhenMailDoesNotStart() async {
        let fake = store {
            $0.running = false
            $0.launchFails = true
        }
        for (tool, args) in Self.writeCalls {
            let error = await failure(tool, args, on: fake)
            #expect(error == FakeMailStore.cannotStart, "\(tool)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func toolDescriptionsNoLongerSayMailMustBeRunning() {
        for spec in MailModule.toolSpecs {
            #expect(spec.tool.description?.contains("Mail must be running") != true, "\(spec.tool.name)")
        }
        let send = MailModule.toolSpecs.first { $0.tool.name == "send_mail" }
        #expect(send?.tool.description?.contains("opens it hidden in the background") == true)
    }

    @Test func writeUsesTheSixtySecondLimitSlot() async {
        let fake = store { $0.writeDelay = 2 }
        let mail = module(fake, backendTimeout: 0.1, writeTimeout: 0.2)
        let error = await failure("create_draft", ["subject": "s", "body": "b"], on: fake, using: mail)
        #expect(error?.code == .timeout)
    }

    @Test func lateSendsAndRepliesSayTheMessageMayBeSent() async {
        let fake = store { $0.writeDelay = 2 }
        let mail = module(fake, backendTimeout: 0.1, writeTimeout: 0.2)
        let calls: [(String, [String: Value])] = [
            ("send_mail", ["to": ["a@b.c"], "subject": "s", "body": "b", "confirm": true]),
            ("reply", ["id": "10", "body": "b", "confirm": true]),
        ]
        for (tool, args) in calls {
            let error = await failure(tool, args, on: fake, using: mail)
            #expect(error?.code == .timeout, "\(tool)")
            #expect(error?.message == "Mail did not answer in time. The message may have been sent.", "\(tool)")
            #expect(error?.fix == "Check the Sent mailbox before you try again.", "\(tool)")
        }
    }

    @Test func lateDraftsKeepTheGenericTimeout() async {
        let fake = store { $0.writeDelay = 2 }
        let mail = module(fake, backendTimeout: 0.1, writeTimeout: 0.2)
        let error = await failure(
            "send_mail", ["to": ["a@b.c"], "subject": "s", "body": "b"], on: fake, using: mail)
        #expect(error?.code == .timeout)
        #expect(error?.message.contains("may have been sent") == false)
    }

    @Test func lateBatchChangesSayTheBatchMayBePartlyApplied() async {
        let fake = store { $0.writeDelay = 2 }
        let mail = module(fake, backendTimeout: 0.1, writeTimeout: 0.2)
        let calls: [(String, [String: Value])] = [
            ("move_message", ["ids": ["10"], "mailbox": "A"]),
            ("flag_message", ["ids": ["10"], "flagged": true]),
            ("mark_read", ["ids": ["10"], "read": true]),
            ("delete_message", ["ids": ["10"]]),
        ]
        for (tool, args) in calls {
            let error = await failure(tool, args, on: fake, using: mail)
            #expect(error?.code == .timeout, "\(tool)")
            #expect(error?.message.contains("partly applied") == true, "\(tool)")
            #expect(error?.fix == "Check the messages before you try again.", "\(tool)")
        }
    }

    // MARK: reply

    @Test func replySavesADraftUnlessConfirmed() async throws {
        let fake = store()
        let draft = try await run("reply", ["id": "10", "body": "Thanks", "reply_all": true], on: fake)
        var replied = try #require(fake.read(\.replied))
        #expect(replied.send == false && replied.replyAll == true && replied.body == "Thanks")
        #expect(replied.ref == MessageRef(id: "10", accountId: "ACC1", mailbox: "INBOX"))
        #expect(draft.text.contains("Not sent") && object(draft)["sent"]?.boolValue == false)

        let sent = try await run("reply", ["id": "10", "body": "Thanks", "confirm": true], on: fake)
        replied = try #require(fake.read(\.replied))
        #expect(replied.send == true && replied.replyAll == false)
        #expect(sent.text == "Reply sent.")
    }

    // MARK: changes

    @Test func moveFlagReadDeleteUseTheLocatedMailbox() async throws {
        let fake = store()
        _ = try await run(
            "move_message", ["ids": ["10", 11, "10"], "mailbox": " Archive ", "account": "Home"], on: fake)
        let moved = try #require(fake.read(\.moved))
        // The duplicate id is dropped. The home mailbox of each message comes from the index.
        #expect(moved.refs.map(\.id) == ["10", "11"] && moved.refs[1].mailbox == "[Gmail]/All Mail")
        #expect(moved.mailbox == "Archive" && moved.account == "Home")

        let flag = try await run("flag_message", ["ids": ["10"], "flagged": false], on: fake)
        #expect(fake.read(\.flagged)?.value == false && flag.text.contains("Unflagged 1"))
        let readOutput = try await run("mark_read", ["ids": ["10", "11"], "read": true], on: fake)
        #expect(fake.read(\.read)?.refs.count == 2 && readOutput.text.contains("read"))
        let deleted = try await run("delete_message", ["ids": ["11"]], on: fake)
        #expect(fake.read(\.deleted)?.map(\.id) == ["11"])
        #expect(deleted.text.contains("Trash"))
        #expect(object(deleted)["count"]?.intValue == 1)
    }

    // MARK: flag colors

    @Test func flagMessageColorReachesTheStore() async throws {
        let fake = store()
        let colored = try await run("flag_message", ["ids": ["10"], "flagged": true, "color": "Orange"], on: fake)
        #expect(fake.read(\.flagged)?.color == .orange && fake.read(\.flagged)?.value == true)
        #expect(colored.text.contains("Flagged 1 messages orange"))
        _ = try await run("flag_message", ["ids": ["10"], "flagged": true], on: fake)
        #expect(fake.read(\.flagged)?.color == nil)
        _ = try await run("flag_message", ["ids": ["10"], "flagged": false], on: fake)
        #expect(fake.read(\.flagged)?.color == nil && fake.read(\.flagged)?.value == false)
    }

    @Test func badFlagColorInputNeverReachesTheStore() async {
        let fake = store()
        let bad: [(String, [String: Value])] = [
            ("flag_message", ["ids": ["10"], "flagged": false, "color": "red"]),
            ("flag_message", ["ids": ["10"], "flagged": true, "color": "pink"]),
            ("flag_message", ["ids": ["10"], "flagged": true, "color": 3]),
            ("search_mail", ["flag_color": "pink"]),
            ("search_mail", ["flag_color": "red", "flagged": false]),
        ]
        for (tool, args) in bad {
            let error = await failure(tool, args, on: fake)
            #expect(error?.code == .invalidInput, "\(tool) \(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func searchPassesTheFlagColorAndShowsIt() async throws {
        var colored = Self.summary
        colored.flagColor = "orange"
        let fake = store { $0.indexPage = SearchPage(items: [colored], truncated: false) }
        let output = try await run("search_mail", ["flag_color": "ORANGE"], on: fake)
        #expect(fake.read(\.searchQuery)?.flagColor == .orange)
        #expect(output.text.contains("[unread, flagged orange]"))
        let messages = try #require(object(output)["messages"]?.arrayValue)
        #expect(messages.first?.objectValue?["flag_color"]?.stringValue == "orange")
        // The color filter also works on the scoped search.
        let slow = store {
            $0.fullDiskAccess = false
            $0.scriptedPage = SearchPage(items: [colored], truncated: false)
        }
        _ = try await run("search_mail", ["flag_color": "orange", "mailbox": "INBOX"], on: slow)
        #expect(slow.read(\.scriptedQuery)?.flagColor == .orange)
    }

    @Test func getMessageShowsTheFlagColor() async throws {
        let base = Self.message
        let flagged = MailMessage(
            id: base.id, subject: base.subject, from: base.from, to: base.to, cc: base.cc, date: base.date,
            mailbox: base.mailbox, accountId: base.accountId, read: true, flagged: true, messageId: nil, body: "x",
            bodySource: "emlx", truncated: false, partial: false, attachments: [], note: nil, flagColor: "purple")
        let fake = store { $0.message = flagged }
        let output = try await run("get_message", ["id": "10"], on: fake)
        #expect(output.text.contains("(flagged purple)"))
        #expect(object(output)["flag_color"]?.stringValue == "purple")
    }

    @Test func exactly100IdsPass() async throws {
        let refs = Dictionary(
            uniqueKeysWithValues: (1...100).map {
                (String($0), MessageRef(id: String($0), accountId: "A", mailbox: "INBOX"))
            })
        let fake = store { $0.refs = refs }
        let ids = (1...100).map { Value.string(String($0)) }
        _ = try await run("delete_message", ["ids": .array(ids), "confirm": true], on: fake)
        #expect(fake.read(\.deleted)?.count == 100)
    }

    // MARK: confirm

    private func inbox(_ count: Int, mailbox: String = "INBOX") -> [String: MessageRef] {
        Dictionary(
            uniqueKeysWithValues: (1...count).map {
                (String($0), MessageRef(id: String($0), accountId: "A", mailbox: mailbox))
            })
    }

    private func ids(_ count: Int) -> Value { .array((1...count).map { .string(String($0)) }) }

    @Test func smallDeleteRunsWithoutConfirm() async throws {
        let fake = store { $0.refs = inbox(10) }
        let output = try await run("delete_message", ["ids": ids(10)], on: fake)
        #expect(fake.read(\.deleted)?.count == 10)
        #expect(object(output)["confirm_required"] == nil)
    }

    @Test func largeDeleteNeedsConfirmAndChangesNothingWithoutIt() async throws {
        let fake = store { $0.refs = inbox(11) }
        let output = try await run("delete_message", ["ids": ids(11)], on: fake)
        #expect(fake.read(\.deleted) == nil)
        #expect(object(output)["confirm_required"]?.boolValue == true)
        #expect(output.text.contains("Nothing changed") && output.text.contains("11 messages"))
        _ = try await run("delete_message", ["ids": ids(11), "confirm": true], on: fake)
        #expect(fake.read(\.deleted)?.count == 11)
    }

    @Test func deleteFromTheTrashIsFinalAndNeedsConfirm() async throws {
        for trash in ["Trash", "Deleted Messages", "Deleted Items", "[Gmail]/Bin"] {
            let fake = store { $0.refs = inbox(1, mailbox: trash) }
            let output = try await run("delete_message", ["ids": ids(1)], on: fake)
            #expect(fake.read(\.deleted) == nil, "\(trash)")
            #expect(output.text.contains("final"), "\(trash)")
        }
    }

    @Test func largeMoveToTrashOrJunkNeedsConfirm() async throws {
        let fake = store { $0.refs = inbox(11) }
        for target in ["Deleted Items", "Junk", "[Gmail]/Spam"] {
            let output = try await run("move_message", ["ids": ids(11), "mailbox": .string(target)], on: fake)
            #expect(fake.read(\.moved) == nil, "\(target)")
            #expect(object(output)["confirm_required"]?.boolValue == true, "\(target)")
        }
        _ = try await run("move_message", ["ids": ids(11), "mailbox": "Archive"], on: fake)
        #expect(fake.read(\.moved)?.refs.count == 11)
    }

    @Test func trashAndJunkNamesMatchTheLastPathPart() {
        #expect(MailModule.isTrash("[Gmail]/Trash") && MailModule.isTrash("deleted items"))
        #expect(MailModule.isTrash("Projects/Trash plans") == false && MailModule.isTrash("INBOX") == false)
        #expect(MailModule.isJunk("Junk E-mail") && MailModule.isJunk("[Gmail]/Spam"))
    }

    @Test func unknownIdsAreNotFoundAndNothingChanges() async {
        let fake = store()
        let error = await failure("delete_message", ["ids": ["10", "999"]], on: fake)
        #expect(error?.code == .notFound)
        #expect(fake.read(\.deleted) == nil)
    }

    @Test func writesWithoutTheIndexNeedALocationOrFail() async throws {
        let fake = store { $0.fullDiskAccess = false }
        let error = await failure("flag_message", ["ids": ["10"], "flagged": true], on: fake)
        #expect(error?.code == .permissionDenied && error?.fix?.contains("in_mailbox") == true)
        #expect(fake.read(\.flagged) == nil)
        _ = try await run(
            "flag_message", ["ids": ["10"], "flagged": true, "in_mailbox": "INBOX", "in_account": "ACC1"], on: fake)
        #expect(fake.read(\.flagged)?.refs == [MessageRef(id: "10", accountId: "ACC1", mailbox: "INBOX")])
        #expect(fake.read(\.calls).contains("locate") == false)
        // The index fails (layout changed): the location is used too.
        let broken = store { $0.locateError = ToolError(.internalError, "layout") }
        _ = try await run(
            "delete_message", ["ids": ["10"], "in_mailbox": "INBOX", "in_account": "ACC1"], on: broken)
        #expect(broken.read(\.deleted)?.count == 1)
    }
}
