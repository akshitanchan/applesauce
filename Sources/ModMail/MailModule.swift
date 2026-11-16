import AppleSauceCore
import Foundation
import MCP

/// Mail tools. Reads use the Envelope Index and the `.emlx` files (Full Disk Access).
/// Writes use AppleScript. All of it goes through a `MailStore`.
public struct MailModule: Module {
    public static let moduleName = "mail"
    public var name: String { Self.moduleName }
    public static let requiredPermissions: [Permission] = [.automationMail, .fullDiskAccess]
    public var permissions: [Permission] { Self.requiredPermissions }

    let store: any MailStore
    let backendTimeout: Double
    let writeTimeout: Double
    /// Where `get_mail_attachment` saves files, and the largest file it saves.
    let attachmentRoot: URL
    let attachmentLimit: Int

    /// The real module, backed by the Envelope Index and AppleScript.
    #if os(macOS)
    public init() {
        self.init(store: AppleMailStore())
    }
    #endif

    init(
        store: any MailStore, backendTimeout: Double = 30, writeTimeout: Double = 60,
        attachmentRoot: URL = AttachmentCache.defaultRoot, attachmentLimit: Int = AttachmentCache.maxBytes
    ) {
        self.store = store
        self.backendTimeout = backendTimeout
        self.writeTimeout = writeTimeout
        self.attachmentRoot = attachmentRoot
        self.attachmentLimit = attachmentLimit
    }

    /// Most messages that one call may change.
    static let batchLimit = 100
    /// A delete or a move to Trash or Junk of more messages than this needs 'confirm' true.
    static let confirmLimit = 10

    // MARK: tools

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static let dateNote = "ISO 8601, for example 2026-11-12 or 2026-11-12T09:30:00+01:00"
    private static let idsProperty: Value = [
        "type": "array", "items": ["type": "string"],
        "description": "Message ids from search_mail. At most \(batchLimit).",
    ]
    private static let inMailbox = property(
        "string",
        "Mailbox path of the message (the 'mailbox' field of search_mail). Only needed when Full Disk Access is missing. Give 'in_account' too."
    )
    private static let inAccount = property(
        "string", "Account id of the message (the 'account_id' field of search_mail). Only needed with 'in_mailbox'.")
    private static let confirmNoteForDelete =
        "More than \(confirmLimit) messages, or any message already in the Trash (that delete is final), needs 'confirm' true."
    private static let confirmNoteForMove =
        "A move of more than \(confirmLimit) messages to Trash or Junk needs 'confirm' true."
    private static let confirmDeleteProperty = property(
        "boolean", "Must be true for a large or final delete. Without it, nothing changes and the result says why.")

    private static func colorProperty(_ description: String) -> Value {
        .object([
            "type": "string", "enum": .array(FlagColor.allCases.map { .string($0.rawValue) }),
            "description": .string(description),
        ])
    }

    private static let attachmentNote =
        "Needs 'confirm' true on every call. Ask the user first, because the file is copied to ~/Library/Caches/applesauce/attachments."

    private static let openNote =
        "If Mail is not running, applesauce opens it hidden in the background and leaves it open."

    private static let fromNote =
        "With more than one Mail account, 'from' must say which one sends. Ask the user when it is not clear."
    private static let fromProperty = property(
        "string", "Sender: an account name, or one address of an account (from list_accounts).")

    private static let confirmNote =
        "Without 'confirm' true nothing is sent: the message is saved as a draft."

    private static let attachmentsProperty: Value = [
        "type": "array", "items": ["type": "string"],
        "description":
            "Absolute paths of files to attach. At most \(OutgoingFiles.maxCount) files, 25 MB for each file and 25 MB in all. Folders, app bundles and files in secret folders (~/.ssh, ~/Library/Keychains and similar) are refused.",
    ]

    public var tools: [ToolSpec] { Self.toolSpecs }

    public static var toolSpecs: [ToolSpec] {
        let recipients = { (what: String) in
            Value.object([
                "type": "array", "items": ["type": "string"],
                "description": "\(what) addresses. Each must contain @.",
            ])
        }
        return [
            ToolSpec(
                name: "list_accounts",
                description: "List the mail accounts with their id, name and email addresses."),
            ToolSpec(
                name: "list_mailboxes",
                description:
                    "List mailboxes with their path and unread count, for all accounts or one. Gmail labels show as mailboxes.",
                properties: ["account": Self.property("string", "Account id or name. Default: all accounts.")]),
            ToolSpec(
                name: "search_mail",
                description:
                    "Search mail, newest first. All filters combine. With Full Disk Access the search is fast and covers all mail. Without it, the search is slower, needs 'mailbox', and covers the date range only (default: last 30 days); 'to' and 'has_attachments' do not work then. Dates are \(Self.dateNote).",
                properties: [
                    "query": Self.property("string", "Words in the subject or the sender. Ignores case."),
                    "from": Self.property("string", "Part of the sender address or name."),
                    "to": Self.property("string", "Part of a recipient address or name."),
                    "subject": Self.property("string", "Part of the subject."),
                    "mailbox": Self.property("string", "Mailbox name or path, for example INBOX. Ignores case."),
                    "account": Self.property("string", "Account id or name."),
                    "unread": Self.property("boolean", "true for unread only, false for read only."),
                    "flagged": Self.property("boolean", "true for flagged only, false for not flagged."),
                    "flag_color": Self.colorProperty(
                        "Only messages flagged with this color. Do not combine it with 'flagged' false."),
                    "since": Self.property("string", "Received at or after this. \(Self.dateNote)"),
                    "before": Self.property(
                        "string", "Received before this. A date-only value means the start of that day."),
                    "has_attachments": Self.property("boolean", "true or false."),
                    "limit": Self.property("integer", "Most results to return. Default 25, maximum 200."),
                ]),
            ToolSpec(
                name: "get_message",
                description:
                    "Get one message: headers, plain text body (cut at 100000 characters) and the numbered names and sizes of attachments. Attachment content is not returned here. Use get_mail_attachment for that.",
                properties: [
                    "id": Self.property("string", "Message id from search_mail."),
                    "in_mailbox": Self.inMailbox, "in_account": Self.inAccount,
                ],
                required: ["id"]),
            ToolSpec(
                name: "get_mail_attachment",
                description:
                    "Save one attachment of a message as a file on this Mac and return its absolute path. Images (JPEG, PNG, GIF, WebP, HEIC) are also returned as an image. PDF, text, RTF, DOC and DOCX files are also returned as text (cut at 100000 characters). Other types return the path only. Files above 25 MB are refused. Attachments of Mail that are not downloaded yet cannot be saved. The file is kept for 24 hours. Give the attachment by 'name' or 'index' from get_message. \(Self.attachmentNote)",
                properties: [
                    "id": Self.property("string", "Message id from search_mail."),
                    "name": Self.property(
                        "string", "Attachment name from get_message. Give 'name' or 'index', not both."),
                    "index": Self.property("integer", "Attachment number from get_message. The first is 1."),
                    "confirm": Self.property(
                        "boolean",
                        "Must be true. Ask the user first: the call copies the attachment to this Mac."),
                    "in_mailbox": Self.inMailbox, "in_account": Self.inAccount,
                ],
                required: ["id"],
                // It writes a file to the Mac and can copy private content out of Mail, so `--read-only` hides it.
                write: true),
            ToolSpec(
                name: "create_draft",
                description:
                    "Save a plain text draft in Mail, with files attached when 'attachments' is given. Nothing is sent. \(Self.fromNote) \(Self.openNote)",
                properties: [
                    "to": recipients("To"), "cc": recipients("Cc"), "bcc": recipients("Bcc"),
                    "from": Self.fromProperty,
                    "subject": Self.property("string", "Subject."),
                    "body": Self.property("string", "Plain text body."),
                    "attachments": Self.attachmentsProperty,
                ],
                required: ["subject", "body"], write: true),
            ToolSpec(
                name: "send_mail",
                description:
                    "Send a plain text email, with files attached when 'attachments' is given. \(Self.confirmNote) \(Self.fromNote) \(Self.openNote) Sending cannot be undone. On Gmail accounts, Mail may leave a copy in Drafts.",
                properties: [
                    "to": recipients("To"), "cc": recipients("Cc"), "bcc": recipients("Bcc"),
                    "from": Self.fromProperty,
                    "subject": Self.property("string", "Subject."),
                    "body": Self.property("string", "Plain text body."),
                    "attachments": Self.attachmentsProperty,
                    "confirm": Self.property("boolean", "Must be true to send."),
                ],
                required: ["to", "subject", "body"], destructive: true),
            ToolSpec(
                name: "forward_message",
                description:
                    "Forward a message as plain text. The new message has the subject 'Fwd: ...', your 'body' (if any), a header block (From, Date, Subject, To) and the original text. The attachments of the original are included unless 'include_attachments' is false. An attachment that cannot be fetched or is above 25 MB is skipped, and the result lists it. 'attachments' adds more files. Forwarded attachments are copied to ~/Library/Caches/applesauce/attachments and kept for 24 hours. \(Self.confirmNote) \(Self.fromNote) \(Self.openNote) Sending cannot be undone.",
                properties: [
                    "id": Self.property("string", "Message id from search_mail."),
                    "to": recipients("To"), "cc": recipients("Cc"), "bcc": recipients("Bcc"),
                    "from": Self.fromProperty,
                    "body": Self.property("string", "Plain text that goes above the forwarded message."),
                    "include_attachments": Self.property(
                        "boolean", "true to forward the attachments of the original. Default true."),
                    "attachments": Self.attachmentsProperty,
                    "confirm": Self.property("boolean", "Must be true to send."),
                    "in_mailbox": Self.inMailbox, "in_account": Self.inAccount,
                ],
                required: ["id", "to"], destructive: true),
            ToolSpec(
                name: "reply",
                description:
                    "Reply to a message with plain text. Mail adds the quoted original. \(Self.confirmNote) \(Self.openNote)",
                properties: [
                    "id": Self.property("string", "Message id from search_mail."),
                    "body": Self.property("string", "Plain text of the reply."),
                    "reply_all": Self.property("boolean", "true to reply to all recipients. Default false."),
                    "confirm": Self.property("boolean", "Must be true to send."),
                    "in_mailbox": Self.inMailbox, "in_account": Self.inAccount,
                ],
                required: ["id", "body"], destructive: true),
            ToolSpec(
                name: "move_message",
                description:
                    "Move messages (at most \(Self.batchLimit)) to a mailbox. Each moved message gets a new id. \(Self.confirmNoteForMove) \(Self.openNote)",
                properties: [
                    "ids": Self.idsProperty,
                    "mailbox": Self.property("string", "Name or path of the target mailbox."),
                    "account": Self.property(
                        "string", "Account name or id of the target mailbox. Default: the account of each message."),
                    "confirm": Self.confirmDeleteProperty,
                    "in_mailbox": Self.inMailbox, "in_account": Self.inAccount,
                ],
                required: ["ids", "mailbox"], destructive: true),
            ToolSpec(
                name: "flag_message",
                description:
                    "Flag or unflag messages (at most \(Self.batchLimit)). Give 'color' to flag with a color. Without 'color', Mail uses its default flag. \(Self.openNote)",
                properties: [
                    "ids": Self.idsProperty,
                    "flagged": Self.property("boolean", "true to flag, false to remove the flag."),
                    "color": Self.colorProperty("Flag color. Needs 'flagged' true."),
                    "in_mailbox": Self.inMailbox, "in_account": Self.inAccount,
                ],
                required: ["ids", "flagged"], write: true, idempotent: true),
            ToolSpec(
                name: "mark_read",
                description: "Mark messages (at most \(Self.batchLimit)) as read or unread. \(Self.openNote)",
                properties: [
                    "ids": Self.idsProperty,
                    "read": Self.property("boolean", "true for read, false for unread."),
                    "in_mailbox": Self.inMailbox, "in_account": Self.inAccount,
                ],
                required: ["ids", "read"], write: true, idempotent: true),
            ToolSpec(
                name: "delete_message",
                description:
                    "Delete messages (at most \(Self.batchLimit)). Mail moves them to the Trash mailbox. Each deleted message gets a new id. \(Self.confirmNoteForDelete) \(Self.openNote)",
                properties: [
                    "ids": Self.idsProperty,
                    "confirm": Self.confirmDeleteProperty,
                    "in_mailbox": Self.inMailbox, "in_account": Self.inAccount,
                ],
                required: ["ids"], destructive: true),
        ]
    }

    // MARK: routing

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        switch tool {
        case "list_accounts": return try await listAccounts()
        case "list_mailboxes": return try await listMailboxes(args)
        case "search_mail": return try await searchMail(args)
        case "get_message": return try await getMessage(args)
        case "get_mail_attachment": return try await getAttachment(args)
        case "create_draft": return try await composeMail(args, tool: tool)
        case "send_mail": return try await composeMail(args, tool: tool)
        case "reply": return try await replyToMessage(args)
        case "forward_message": return try await forwardMessage(args)
        case "move_message": return try await changeMessages(args, tool: tool)
        case "flag_message": return try await changeMessages(args, tool: tool)
        case "mark_read": return try await changeMessages(args, tool: tool)
        case "delete_message": return try await changeMessages(args, tool: tool)
        default:
            throw ToolError(.unknownTool, "The mail module has no tool named '\(tool)'.")
        }
    }

    // MARK: backend access

    /// One backend call. The limit is `seconds`, or `backendTimeout` when `seconds` is nil.
    /// `onTimeout` replaces the timeout error, for a write that may have worked.
    private func backend<T: Sendable>(
        seconds: Double? = nil, onTimeout: ToolError? = nil,
        _ operation: @escaping @Sendable (any MailStore) async throws -> T
    ) async throws -> T {
        let store = store
        do {
            return try await withTimeout(seconds: seconds ?? backendTimeout) { try await operation(store) }
        } catch let error as ToolError where error.code == .timeout {
            // The timer or Mail itself (error -1712) gave up. For a write, the work may still have happened.
            throw onTimeout ?? error
        }
    }

    /// For a send or a reply that sends: Mail may have sent the message before the answer was late.
    static let sendTimeout = ToolError(
        .timeout, "Mail did not answer in time. The message may have been sent.",
        fix: "Check the Sent mailbox before you try again.")

    /// For a batch change: some of the messages may already be changed.
    static let batchTimeout = ToolError(
        .timeout, "Mail did not answer in time. The batch may be partly applied.",
        fix: "Check the messages before you try again.")

    // MARK: output

    private struct AccountList: Encodable {
        let accounts: [MailAccount]
    }
    private struct MailboxList: Encodable {
        let mailboxes: [MailboxInfo]
    }
    private struct SearchResult: Encodable {
        let messages: [MessageSummary]
        let count: Int
        let truncated: Bool
        /// `index` (fast) or `applescript` (slower, scoped).
        let source: String
        let since: Date?
        let before: Date?
        let fix: String?
    }
    private struct ActionResult: Encodable {
        let action: String
        let count: Int?
        let ids: [String]?
        /// For send_mail and reply: true when the message was sent, false when it was saved as a draft.
        let sent: Bool?
        let draftSaved: Bool?
        /// True when nothing changed because the call needs 'confirm' true.
        var confirmRequired: Bool? = nil
        /// File names that the message carries. Only for a message with attachments.
        var attached: [String]? = nil
        /// Attachments of a forwarded message that were left out, each with the reason.
        var skipped: [String]? = nil
    }

    static func describe(_ item: MessageSummary) -> String {
        var flags: [String] = []
        if !item.read { flags.append("unread") }
        if item.flagged { flags.append(item.flagColor.map { "flagged \($0)" } ?? "flagged") }
        if item.hasAttachments == true { flags.append("attachment") }
        let date = item.date.map { ISODate.string($0) } ?? "no date"
        let tail = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
        return
            "- \(item.id) | \(date) | \(item.from) | \(item.subject.isEmpty ? "(no subject)" : item.subject)\(tail) | \(item.mailbox)"
    }

    // MARK: input

    private func trimmed(_ args: Arguments, _ key: String) throws -> String? {
        guard let text = try args.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard !text.isEmpty else { throw ToolError.invalidInput("'\(key)' must not be empty.") }
        return text
    }

    /// Addresses must contain `@` and no spaces. This is a loose check, not full email syntax.
    private func addresses(_ args: Arguments, _ key: String, required: Bool = false) throws -> [String] {
        let list =
            try args.stringArray(key)?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        if required && list.isEmpty { throw ToolError.invalidInput("'\(key)' needs at least one address.") }
        for address in list {
            guard address.contains("@"), address.count >= 3, !address.contains(where: \.isWhitespace) else {
                throw ToolError(
                    .invalidInput, "'\(key)' has an address that is not valid: '\(address)'.",
                    fix: "Use plain addresses such as name@example.com.")
            }
        }
        return list
    }

    /// Message ids as text. Numbers are accepted too. Ids are whole numbers.
    private func messageID(_ value: Value, key: String) throws -> String {
        let text = value.stringValue ?? value.intValue.map(String.init) ?? ""
        let id = text.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else {
            throw ToolError(
                .invalidInput, "'\(key)' has a message id that is not valid: '\(text)'.",
                fix: "Use ids from search_mail. An id is a whole number.")
        }
        return id
    }

    /// An optional flag color name (any case).
    private func flagColor(_ args: Arguments, key: String) throws -> FlagColor? {
        guard let text = try trimmed(args, key) else { return nil }
        guard let color = FlagColor(rawValue: text.lowercased()) else {
            throw ToolError(
                .invalidInput, "'\(key)' is not a flag color: '\(text)'.",
                fix: "Use one of: \(FlagColor.names).")
        }
        return color
    }

    private func requiredID(_ args: Arguments) throws -> String {
        guard let value = args.raw["id"], !value.isNull else { throw ToolError.invalidInput("'id' is required.") }
        return try messageID(value, key: "id")
    }

    private func idList(_ args: Arguments) throws -> [String] {
        guard let value = args.raw["ids"], !value.isNull else { throw ToolError.invalidInput("'ids' is required.") }
        guard let items = value.arrayValue else {
            throw ToolError.invalidInput("'ids' must be an array of message ids.")
        }
        guard !items.isEmpty else { throw ToolError.invalidInput("'ids' needs at least one id.") }
        guard items.count <= Self.batchLimit else {
            throw ToolError(
                .invalidInput, "'ids' has \(items.count) ids. The limit is \(Self.batchLimit).",
                fix: "Split the request into batches of \(Self.batchLimit) or fewer.")
        }
        var seen = Set<String>()
        return try items.map { try messageID($0, key: "ids") }.filter { seen.insert($0).inserted }
    }

    /// `in_mailbox` and `in_account` go together.
    private func location(_ args: Arguments) throws -> (mailbox: String, account: String)? {
        let mailbox = try trimmed(args, "in_mailbox")
        let account = try trimmed(args, "in_account")
        guard mailbox != nil || account != nil else { return nil }
        guard let mailbox, let account else {
            throw ToolError.invalidInput("'in_mailbox' and 'in_account' must be given together.")
        }
        return (mailbox, account)
    }

    /// Starts Mail hidden in the background when it is not running, and waits until it answers.
    private func requireRunning() async throws {
        try await backend(seconds: writeTimeout) { try await $0.ensureRunning() }
    }

    private static var fullDiskFix: String {
        Permission.fullDiskAccess.fix(for: .denied) ?? "Grant Full Disk Access."
    }

    /// An index problem that the AppleScript path can cover: no access, or a layout that is not the expected one.
    private static func canFallBack(_ error: ToolError) -> Bool {
        error.code == .permissionDenied || error.code == .internalError
    }

    /// Where the messages are. The index knows. Without it, the caller must say.
    private func refs(_ ids: [String], at place: (mailbox: String, account: String)?) async throws -> [MessageRef] {
        var failure: ToolError?
        if store.hasFullDiskAccess() {
            do { return try await backend { try await $0.locate(ids: ids) } } catch let error as ToolError {
                guard Self.canFallBack(error) else { throw error }
                failure = error
            }
        }
        guard let place else {
            throw ToolError(
                .permissionDenied,
                "Mail's index cannot be read, so applesauce cannot find where the message is\(failure.map { " (\($0.message))" } ?? "").",
                fix:
                    "\(Self.fullDiskFix) Or give 'in_mailbox' and 'in_account' (from search_mail) to say where the message is."
            )
        }
        return ids.map { MessageRef(id: $0, accountId: place.account, mailbox: place.mailbox) }
    }

    private func accountID(_ query: String?) async throws -> String? {
        guard let query else { return nil }
        let all = try await backend { try await $0.accounts() }
        return try resolveByIdOrName(query, kind: "account", in: all).id
    }

    // MARK: read tools

    private func listAccounts() async throws -> ToolOutput {
        let accounts = try await backend { try await $0.accounts() }
        var lines = ["\(accounts.count) accounts."]
        lines += accounts.map {
            "- \($0.name) | id: \($0.id)\($0.emails.isEmpty ? "" : " | \($0.emails.joined(separator: ", "))")"
        }
        return try ToolOutput(text: lines.joined(separator: "\n"), payload: AccountList(accounts: accounts))
    }

    private func listMailboxes(_ args: Arguments) async throws -> ToolOutput {
        let account = try await accountID(try trimmed(args, "account"))
        let mailboxes = try await backend { try await $0.mailboxes(account: account) }
        var lines = ["\(mailboxes.count) mailboxes."]
        lines += mailboxes.map {
            "- \($0.path) | \($0.account ?? $0.accountId)\($0.unread.map { " | \($0) unread" } ?? "")"
        }
        return try ToolOutput(text: lines.joined(separator: "\n"), payload: MailboxList(mailboxes: mailboxes))
    }

    private func searchMail(_ args: Arguments) async throws -> ToolOutput {
        var query = MailSearchQuery()
        query.text = try trimmed(args, "query")
        query.from = try trimmed(args, "from")
        query.to = try trimmed(args, "to")
        query.subject = try trimmed(args, "subject")
        query.mailbox = try trimmed(args, "mailbox")
        let accountText = try trimmed(args, "account")
        query.unread = try args.bool("unread")
        query.flagged = try args.bool("flagged")
        query.flagColor = try flagColor(args, key: "flag_color")
        if query.flagColor != nil, query.flagged == false {
            throw ToolError(
                .invalidInput, "'flag_color' cannot be used with 'flagged' false.",
                fix: "Remove 'flagged', or remove 'flag_color'. A color filter returns flagged messages only.")
        }
        query.since = try args.date("since")?.date
        query.before = try args.date("before")?.date
        query.hasAttachments = try args.bool("has_attachments")
        query.limit = try args.int("limit", default: 25, range: 1...200)
        if let since = query.since, let before = query.before, before <= since {
            throw ToolError(
                .invalidInput, "'before' must be after 'since'.", fix: "Use a 'before' that is later than 'since'.")
        }
        query.account = try await accountID(accountText)

        var reason: ToolError
        if store.hasFullDiskAccess() {
            let wanted = query
            do {
                let page = try await backend { try await $0.searchIndex(wanted) }
                return try Self.searchOutput(page, source: "index", since: query.since, before: query.before, fix: nil)
            } catch let error as ToolError {
                guard Self.canFallBack(error) else { throw error }
                reason = error
            }
        } else {
            reason = ToolError.permission(.fullDiskAccess, state: .denied)
        }
        return try await scopedSearch(query, reason: reason)
    }

    /// The slower search through Mail. It needs a mailbox and uses a date range (default: the last 30 days).
    private func scopedSearch(_ asked: MailSearchQuery, reason: ToolError) async throws -> ToolOutput {
        let fix = reason.fix ?? Self.fullDiskFix
        guard asked.mailbox != nil else {
            throw ToolError(
                .permissionDenied,
                "Fast mail search is not available (\(reason.message)). The slower search needs 'mailbox'.",
                fix: "\(fix) Or give 'mailbox' (and optionally 'since', 'before') to use the slower search.")
        }
        if asked.to != nil || asked.hasAttachments != nil {
            throw ToolError(
                .invalidInput,
                "'to' and 'has_attachments' need the fast search, which is not available (\(reason.message)).",
                fix: fix)
        }
        var query = asked
        let now = Date()
        query.before = asked.before ?? now
        query.since = asked.since ?? query.before?.addingTimeInterval(-30 * 24 * 3600)
        let wanted = query
        let page = try await backend { try await $0.searchScripted(wanted) }
        return try Self.searchOutput(
            page, source: "applescript", since: query.since, before: query.before,
            fix: "For fast search over all mail: \(fix)")
    }

    private static func searchOutput(
        _ page: SearchPage, source: String, since: Date?, before: Date?, fix: String?
    ) throws -> ToolOutput {
        var lines: [String] = []
        if source == "applescript", let since, let before {
            lines.append(
                "This is the slower scoped search through Mail, not the fast search. It looked in one mailbox from \(ISODate.string(since)) to \(ISODate.string(before))."
            )
        }
        lines.append(
            page.truncated
                ? "Showing the first \(page.items.count) messages (newest first). More match. Raise 'limit' (maximum 200) or add filters."
                : "\(page.items.count) messages (newest first).")
        lines += page.items.map(describe)
        if let fix { lines.append("fix: \(fix)") }
        return try ToolOutput(
            text: lines.joined(separator: "\n"),
            payload: SearchResult(
                messages: page.items, count: page.items.count, truncated: page.truncated, source: source,
                since: source == "applescript" ? since : nil, before: source == "applescript" ? before : nil,
                fix: fix))
    }

    private func getMessage(_ args: Arguments) async throws -> ToolOutput {
        let id = try requiredID(args)
        let place = try location(args)
        let final = try await loadMessage(id: id, place: place)
        return try ToolOutput(text: Self.messageText(final), payload: final)
    }

    /// One message with its body: from the index and the message file, or through Mail without Full Disk Access.
    private func loadMessage(id: String, place: (mailbox: String, account: String)?) async throws -> MailMessage {
        var message: MailMessage?
        var reason: ToolError?
        if store.hasFullDiskAccess() {
            do { message = try await backend { try await $0.indexMessage(id: id) } } catch let error as ToolError {
                guard Self.canFallBack(error) else { throw error }
                reason = error
            }
        }
        if message == nil {
            guard let place else {
                throw ToolError(
                    .permissionDenied,
                    "Mail's index cannot be read\(reason.map { " (\($0.message))" } ?? ""), so applesauce cannot find the message.",
                    fix:
                        "\(Self.fullDiskFix) Or give 'in_mailbox' and 'in_account' (from search_mail) to read it through Mail."
                )
            }
            try await requireRunning()
            let ref = MessageRef(id: id, accountId: place.account, mailbox: place.mailbox)
            message = try await backend { try await $0.scriptedMessage(ref) }
        } else if let found = message, found.body == nil {
            message = await withScriptedBody(found)
        }
        guard let final = message else {
            throw ToolError(.internalError, "No message was read.", fix: "Report this error.")
        }
        return final
    }

    /// The file was not on disk. Ask Mail for the body, which also makes Mail download it. It never fails the call.
    private func withScriptedBody(_ message: MailMessage) async -> MailMessage {
        guard store.isMailRunning() else {
            return message.with(note: "The message file is not on disk. Open Mail to read the body.")
        }
        let ref = MessageRef(id: message.id, accountId: message.accountId, mailbox: message.mailbox)
        do {
            let scripted = try await backend { try await $0.scriptedMessage(ref) }
            return message.with(body: scripted, note: nil)
        } catch {
            return message.with(note: "The message file is not on disk, and Mail did not give the body.")
        }
    }

    static func messageText(_ message: MailMessage) -> String {
        var lines = ["Subject: \(message.subject.isEmpty ? "(no subject)" : message.subject)", "From: \(message.from)"]
        if !message.to.isEmpty { lines.append("To: \(message.to.joined(separator: ", "))") }
        if !message.cc.isEmpty { lines.append("Cc: \(message.cc.joined(separator: ", "))") }
        if let date = message.date { lines.append("Date: \(ISODate.string(date))") }
        let flag = message.flagged ? " (\(message.flagColor.map { "flagged \($0)" } ?? "flagged"))" : ""
        lines.append("Mailbox: \(message.mailbox)\(message.read ? "" : " (unread)")\(flag)")
        if !message.attachments.isEmpty {
            let list = message.attachments.enumerated().map { offset, attachment in
                let size = attachment.size.map {
                    " (\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)))"
                }
                return "\(offset + 1). \(attachment.name)\(size ?? "")"
            }
            lines.append("Attachments: \(list.joined(separator: ", "))")
        }
        if let note = message.note { lines.append("Note: \(note)") }
        lines.append("")
        lines.append(message.body ?? "(No body available.)")
        if message.truncated { lines.append("\n(Body cut at \(MailScripts.bodyLimit) characters.)") }
        return lines.joined(separator: "\n")
    }

    // MARK: attachments

    static let confirmAttachmentError = ToolError(
        .invalidInput, "Saving an attachment needs the user's OK, and 'confirm' is not true. Nothing was saved.",
        fix:
            "Ask the user whether applesauce may save this attachment on this Mac. If the user agrees, call again with 'confirm' true."
    )

    private func getAttachment(_ args: Arguments) async throws -> ToolOutput {
        let id = try requiredID(args)
        let pick = try AttachmentPick(args)
        let confirmed = try args.bool("confirm") == true
        let place = try location(args)
        guard confirmed else { throw Self.confirmAttachmentError }

        AttachmentCache.sweep(root: attachmentRoot)
        let ref = try await refs([id], at: place)[0]
        let folder = try AttachmentCache.makeFolder(root: attachmentRoot)
        let limit = attachmentLimit
        do {
            let saved = try await backend(seconds: writeTimeout) {
                try await $0.saveAttachment(ref, pick: pick, into: folder, limit: limit)
            }
            // The store checks the size before it reads. This is a second check of the file that it wrote.
            guard saved.size <= limit else {
                throw AttachmentCache.tooLarge(name: saved.name, bytes: saved.size, limit: limit)
            }
            return try await backend {
                _ in
                try AttachmentOutput.make(
                    file: saved.file, name: saved.name, size: saved.size, textLimit: MailScripts.bodyLimit)
            }
        } catch {
            // Nothing stays behind for a failed call.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    // MARK: write tools

    /// Longest message body that a write tool takes, in bytes of UTF-8 text.
    static let bodyInputLimit = 500_000

    private func requiredBody(_ args: Arguments) throws -> String {
        let body = try args.requiredString("body")
        guard body.utf8.count <= Self.bodyInputLimit else {
            throw ToolError(
                .invalidInput,
                "'body' is too long (\(body.utf8.count) bytes). The limit is \(Self.bodyInputLimit) bytes.",
                fix: "Send a shorter text.")
        }
        return body
    }

    /// An optional body. Empty text is the same as none.
    private func optionalBody(_ args: Arguments) throws -> String? {
        guard let body = try args.string("body"), !body.isEmpty else { return nil }
        guard body.utf8.count <= Self.bodyInputLimit else {
            throw ToolError(
                .invalidInput,
                "'body' is too long (\(body.utf8.count) bytes). The limit is \(Self.bodyInputLimit) bytes.",
                fix: "Send a shorter text.")
        }
        return body
    }

    private func composeMail(_ args: Arguments, tool: String) async throws -> ToolOutput {
        let sending = tool == "send_mail"
        var mail = OutgoingMail(
            to: try addresses(args, "to", required: sending), cc: try addresses(args, "cc"),
            bcc: try addresses(args, "bcc"), subject: try args.requiredString("subject"),
            body: try requiredBody(args))
        let files = try attachmentFiles(args)
        mail.attachments = files.map(\.path)
        let requestedSender = try trimmed(args, "from")
        let confirm = sending ? try args.bool("confirm") : nil
        let confirmed = confirm == true
        try await requireRunning()
        let sender = try await senderAddress(requestedSender)
        mail.from = sender
        let outgoing = mail
        try await backend(seconds: writeTimeout, onTimeout: confirmed ? Self.sendTimeout : nil) {
            try await $0.compose(outgoing, send: confirmed)
        }
        let names = files.map(\.name)
        let attachedText = Self.attachedText(names)
        let attached = names.isEmpty ? nil : names
        if confirmed {
            return try ToolOutput(
                text: "Sent from \(sender) to \(mail.to.joined(separator: ", ")).\(attachedText)",
                payload: ActionResult(
                    action: "send", count: nil, ids: nil, sent: true, draftSaved: false, attached: attached))
        }
        let text =
            sending
            ? "Not sent: 'confirm' was not true. The message is saved as a draft in Mail. Call send_mail again with 'confirm' true to send.\(attachedText)"
            : "Draft saved in Mail, from \(sender). Nothing was sent.\(attachedText)"
        return try ToolOutput(
            text: text,
            payload: ActionResult(
                action: sending ? "draft" : "create_draft", count: nil, ids: nil, sent: sending ? false : nil,
                draftSaved: true, attached: attached))
    }

    /// ` Attached: a.pdf, b.png.`, or nothing when no file is attached.
    private static func attachedText(_ names: [String]) -> String {
        names.isEmpty ? "" : " Attached: \(names.joined(separator: ", "))."
    }

    /// The optional 'attachments' argument, checked: every file exists, is a regular file, is readable, and the
    /// count and the sizes are inside the limits. Nothing is sent to Mail before this passes.
    private func attachmentFiles(_ args: Arguments) throws -> [OutgoingFile] {
        guard let paths = try args.stringArray("attachments") else { return [] }
        return try OutgoingFiles.check(paths, limit: attachmentLimit)
    }

    // MARK: forward

    /// "Fwd: " and the original subject. A subject that starts with "Fwd:" or "Fw:" keeps its prefix.
    static func forwardSubject(_ original: String) -> String {
        let subject = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = subject.lowercased()
        if lower.hasPrefix("fwd:") || lower.hasPrefix("fw:") { return subject }
        return subject.isEmpty ? "Fwd:" : "Fwd: \(subject)"
    }

    /// Your text, then the header block of the original (From, Date, Subject, To, and Cc when there is one),
    /// then the original plain text.
    static func forwardBody(intro: String?, original: MailMessage, text: String) -> String {
        var lines: [String] = []
        if let intro, !intro.isEmpty { lines += [intro, ""] }
        lines += ["Begin forwarded message:", "", "From: \(original.from)"]
        if let date = original.date { lines.append("Date: \(ISODate.string(date))") }
        lines.append("Subject: \(original.subject.isEmpty ? "(no subject)" : original.subject)")
        if !original.to.isEmpty { lines.append("To: \(original.to.joined(separator: ", "))") }
        if !original.cc.isEmpty { lines.append("Cc: \(original.cc.joined(separator: ", "))") }
        lines += ["", text]
        if original.truncated {
            lines += ["", "(The original text was cut at \(MailScripts.bodyLimit) characters.)"]
        }
        return lines.joined(separator: "\n")
    }

    /// The attachments of the original, saved as files. An attachment that cannot be saved is skipped and named.
    /// Each file gets its own folder, because two attachments can have the same name.
    private func saveOriginalAttachments(of original: MailMessage) async throws -> (
        files: [SavedAttachment], skipped: [String]
    ) {
        guard !original.attachments.isEmpty else { return ([], []) }
        AttachmentCache.sweep(root: attachmentRoot)
        let ref = MessageRef(id: original.id, accountId: original.accountId, mailbox: original.mailbox)
        let limit = attachmentLimit
        var files: [SavedAttachment] = []
        var skipped: [String] = []
        for (offset, attachment) in original.attachments.enumerated() {
            let folder = try AttachmentCache.makeFolder(root: attachmentRoot)
            do {
                let saved = try await backend(seconds: writeTimeout) {
                    try await $0.saveAttachment(ref, pick: .index(offset + 1), into: folder, limit: limit)
                }
                guard saved.size <= limit else {
                    throw AttachmentCache.tooLarge(name: saved.name, bytes: saved.size, limit: limit)
                }
                files.append(saved)
            } catch let error as ToolError {
                try? FileManager.default.removeItem(at: folder)
                skipped.append("\(attachment.name) (\(error.message))")
            }
        }
        return (files, skipped)
    }

    private func forwardMessage(_ args: Arguments) async throws -> ToolOutput {
        let id = try requiredID(args)
        let to = try addresses(args, "to", required: true)
        let cc = try addresses(args, "cc")
        let bcc = try addresses(args, "bcc")
        let intro = try optionalBody(args)
        let includeAttachments = try args.bool("include_attachments") ?? true
        let extra = try attachmentFiles(args)
        let requestedSender = try trimmed(args, "from")
        let confirmed = (try args.bool("confirm")) == true
        let place = try location(args)
        try await requireRunning()
        // The sender check comes first: an unclear sender stops the call before any file is saved.
        let sender = try await senderAddress(requestedSender)
        let original = try await loadMessage(id: id, place: place)
        guard let text = original.body else {
            throw ToolError(
                .notFound,
                "The text of message \(id) is not available (\(original.note ?? "Mail has not downloaded it")), so it cannot be forwarded.",
                fix: "Open the message in Mail so that it downloads, then try again.")
        }
        let body = Self.forwardBody(intro: intro, original: original, text: text)
        guard body.utf8.count <= Self.bodyInputLimit else {
            throw ToolError(
                .invalidInput,
                "The forwarded text is too long (\(body.utf8.count) bytes). The limit is \(Self.bodyInputLimit) bytes.",
                fix: "Use a shorter 'body'.")
        }
        let saved = includeAttachments ? try await saveOriginalAttachments(of: original) : (files: [], skipped: [])
        let mail = OutgoingMail(
            to: to, cc: cc, bcc: bcc, subject: Self.forwardSubject(original.subject), body: body, from: sender,
            attachments: saved.files.map(\.file.path) + extra.map(\.path))
        try await backend(seconds: writeTimeout, onTimeout: confirmed ? Self.sendTimeout : nil) {
            try await $0.compose(mail, send: confirmed)
        }
        let names = saved.files.map(\.name) + extra.map(\.name)
        var summary =
            confirmed
            ? "Forwarded message \(id) from \(sender) to \(to.joined(separator: ", "))."
            : "Not sent: 'confirm' was not true. The forward is saved as a draft in Mail. Call forward_message again with 'confirm' true to send."
        summary += Self.attachedText(names)
        if !saved.skipped.isEmpty { summary += " Skipped: \(saved.skipped.joined(separator: "; "))." }
        return try ToolOutput(
            text: summary,
            payload: ActionResult(
                action: "forward", count: nil, ids: [id], sent: confirmed, draftSaved: !confirmed,
                attached: names.isEmpty ? nil : names, skipped: saved.skipped.isEmpty ? nil : saved.skipped))
    }

    /// The address a new message comes from. One account with an address: that one, unasked.
    /// More than one: 'from' must name an account or an address, and an account with several addresses is not enough.
    private func senderAddress(_ requested: String?) async throws -> String {
        let accounts = try await backend { try await $0.accounts() }.filter { !$0.emails.isEmpty }
        let choices = accounts.map { "'\($0.name)' (\($0.emails.joined(separator: ", ")))" }.joined(separator: ", ")
        guard let requested else {
            if accounts.count == 1, accounts[0].emails.count == 1 { return accounts[0].emails[0] }
            if accounts.isEmpty {
                throw ToolError(
                    .notFound, "Mail has no account with an email address.",
                    fix: "Add an account in Mail settings, then try again.")
            }
            throw ToolError(
                .ambiguous, "More than one address can send this message: \(choices).",
                fix: "Ask the user which address to send from, then call again with 'from'.")
        }
        if requested.contains("@") {
            for account in accounts {
                if let match = account.emails.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
                    return match
                }
            }
            throw ToolError(
                .notFound, "No Mail account has the address '\(requested)'. Accounts: \(choices).",
                fix: "Use an account name or one of these addresses in 'from'.")
        }
        let account = try resolveByIdOrName(requested, kind: "account", in: accounts)
        guard account.emails.count == 1 else {
            throw ToolError(
                .ambiguous,
                "The account '\(account.name)' has more than one address: \(account.emails.joined(separator: ", ")).",
                fix: "Ask the user which address to send from, then call again with that address in 'from'.")
        }
        return account.emails[0]
    }

    private func replyToMessage(_ args: Arguments) async throws -> ToolOutput {
        let id = try requiredID(args)
        let body = try requiredBody(args)
        let replyAll = try args.bool("reply_all") ?? false
        let confirmed = (try args.bool("confirm")) == true
        let place = try location(args)
        try await requireRunning()
        let ref = try await refs([id], at: place)[0]
        try await backend(seconds: writeTimeout, onTimeout: confirmed ? Self.sendTimeout : nil) {
            try await $0.reply(to: ref, body: body, replyAll: replyAll, send: confirmed)
        }
        let text =
            confirmed
            ? "Reply sent."
            : "Not sent: 'confirm' was not true. The reply is saved as a draft in Mail. Call reply again with 'confirm' true to send."
        return try ToolOutput(
            text: text,
            payload: ActionResult(action: "reply", count: nil, ids: [id], sent: confirmed, draftSaved: !confirmed))
    }

    private func changeMessages(_ args: Arguments, tool: String) async throws -> ToolOutput {
        let ids = try idList(args)
        let place = try location(args)
        let confirmed = try args.bool("confirm") == true
        var target: String?
        var targetAccount: String?
        var flag = false
        var color: FlagColor?
        switch tool {
        case "move_message":
            target = try trimmed(args, "mailbox")
            if target == nil { throw ToolError.invalidInput("'mailbox' is required.") }
            targetAccount = try trimmed(args, "account")
        case "flag_message":
            guard let value = try args.bool("flagged") else { throw ToolError.invalidInput("'flagged' is required.") }
            flag = value
            color = try flagColor(args, key: "color")
            if color != nil, !flag {
                throw ToolError(
                    .invalidInput, "'color' needs 'flagged' true.",
                    fix: "Set 'flagged' true to flag with a color, or remove 'color' to remove the flag.")
            }
        case "mark_read":
            guard let value = try args.bool("read") else { throw ToolError.invalidInput("'read' is required.") }
            flag = value
        default:
            break
        }
        try await requireRunning()
        let found = try await refs(ids, at: place)
        if !confirmed, let reason = Self.confirmReason(tool: tool, refs: found, target: target) {
            return try ToolOutput(
                text: "Nothing changed. \(reason) Call again with 'confirm' true.",
                payload: ActionResult(
                    action: tool, count: ids.count, ids: ids, sent: nil, draftSaved: nil, confirmRequired: true))
        }
        let (target0, account0, flag0, color0) = (target, targetAccount, flag, color)
        let summary: String
        switch tool {
        case "move_message":
            try await backend(seconds: writeTimeout, onTimeout: Self.batchTimeout) {
                try await $0.move(found, mailbox: target0 ?? "", account: account0)
            }
            summary = "Moved \(ids.count) messages to '\(target0 ?? "")'."
        case "flag_message":
            try await backend(seconds: writeTimeout, onTimeout: Self.batchTimeout) {
                try await $0.setFlagged(found, flag0, color: color0)
            }
            summary =
                "\(flag0 ? "Flagged" : "Unflagged") \(ids.count) messages\(color0.map { " \($0.rawValue)" } ?? "")."
        case "mark_read":
            try await backend(seconds: writeTimeout, onTimeout: Self.batchTimeout) {
                try await $0.setRead(found, flag0)
            }
            summary = "Marked \(ids.count) messages as \(flag0 ? "read" : "unread")."
        default:
            try await backend(seconds: writeTimeout, onTimeout: Self.batchTimeout) { try await $0.delete(found) }
            summary = "Deleted \(ids.count) messages. Mail moved them to the Trash."
        }
        return try ToolOutput(
            text: summary,
            payload: ActionResult(action: tool, count: ids.count, ids: ids, sent: nil, draftSaved: nil))
    }

    /// Why a delete or move needs 'confirm', or nil when it can run as is.
    static func confirmReason(tool: String, refs: [MessageRef], target: String?) -> String? {
        let mailboxes = Set(refs.map(\.mailbox)).sorted().map { "'\($0)'" }.joined(separator: ", ")
        switch tool {
        case "delete_message":
            if refs.contains(where: { isTrash($0.mailbox) }) {
                return "Some messages are already in the Trash (\(mailboxes)), so this delete is final."
            }
            if refs.count > confirmLimit {
                return "This moves \(refs.count) messages from \(mailboxes) to the Trash."
            }
        case "move_message":
            if let target, isTrash(target) || isJunk(target), refs.count > confirmLimit {
                return "This moves \(refs.count) messages from \(mailboxes) to '\(target)'."
            }
        default:
            break
        }
        return nil
    }

    /// Trash names across Mail, iCloud, Exchange and Gmail. Only the last part of a path counts.
    static func isTrash(_ mailbox: String) -> Bool {
        ["trash", "bin", "deleted messages", "deleted items"].contains(lastPart(mailbox))
    }

    static func isJunk(_ mailbox: String) -> Bool {
        ["junk", "spam", "junk e-mail", "junk email"].contains(lastPart(mailbox))
    }

    private static func lastPart(_ mailbox: String) -> String {
        (mailbox.split(separator: "/").last.map(String.init) ?? mailbox).lowercased()
    }
}

extension MailMessage {
    func with(note: String?) -> MailMessage {
        MailMessage(
            id: id, subject: subject, from: from, to: to, cc: cc, date: date, mailbox: mailbox, accountId: accountId,
            read: read, flagged: flagged, messageId: messageId, body: body, bodySource: bodySource,
            truncated: truncated, partial: partial, attachments: attachments, note: note, flagColor: flagColor)
    }

    /// This message with the body (and the attachment list, which has sizes) of a message read through Mail.
    func with(body other: MailMessage, note: String?) -> MailMessage {
        MailMessage(
            id: id, subject: subject, from: from, to: to, cc: cc, date: date, mailbox: mailbox, accountId: accountId,
            read: read, flagged: flagged, messageId: messageId, body: other.body, bodySource: other.bodySource,
            truncated: other.truncated, partial: false,
            attachments: other.attachments.isEmpty ? attachments : other.attachments, note: note,
            flagColor: flagColor ?? other.flagColor)
    }
}
