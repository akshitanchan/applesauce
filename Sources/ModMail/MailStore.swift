import AppleSauceCore
import Foundation

struct MailAccount: Encodable, Sendable, Equatable, Identified {
    /// The account id Mail uses. It is the host part of every mailbox URL, a UUID in current macOS versions.
    let id: String
    let name: String
    let emails: [String]
    var title: String { name }
}

struct MailboxInfo: Encodable, Sendable, Equatable {
    /// Last part of the path, for example `Sent Mail`.
    let name: String
    /// Full path inside the account, for example `[Gmail]/Sent Mail`. Parts are separated by `/`.
    let path: String
    let accountId: String
    let account: String?
    let unread: Int?
}

struct MessageSummary: Encodable, Sendable, Equatable {
    /// The Envelope Index ROWID, as text.
    let id: String
    let subject: String
    let from: String
    let date: Date?
    /// Path of the mailbox that holds the message.
    let mailbox: String
    let accountId: String
    let read: Bool
    let flagged: Bool
    let hasAttachments: Bool?
}

struct MailMessage: Encodable, Sendable, Equatable {
    let id: String
    let subject: String
    let from: String
    let to: [String]
    let cc: [String]
    let date: Date?
    let mailbox: String
    let accountId: String
    let read: Bool
    let flagged: Bool
    let messageId: String?
    /// Plain text. Nil when the body is not available (not downloaded, or no way to read it).
    let body: String?
    /// `emlx` (read from the file), `applescript` (read through Mail) or `none`.
    let bodySource: String
    /// True when the body was cut at the character limit.
    let truncated: Bool
    /// True when the file is a `.partial.emlx`: Mail has not downloaded everything.
    let partial: Bool
    let attachments: [MailAttachment]
    let note: String?
}

struct MailAttachment: Encodable, Sendable, Equatable {
    let name: String
    /// Decoded size in bytes. Nil when only the index knows the attachment.
    let size: Int?
}

struct SearchPage: Sendable, Equatable {
    var items: [MessageSummary]
    /// More messages match than were returned.
    var truncated: Bool
}

/// Where one message lives, so a script can find it.
struct MessageRef: Sendable, Equatable {
    let id: String
    let accountId: String
    /// Mailbox path inside the account.
    let mailbox: String
}

struct MailSearchQuery: Sendable, Equatable {
    /// Words in the subject or the sender.
    var text: String?
    var from: String?
    var to: String?
    var subject: String?
    /// A mailbox name or path (any case).
    var mailbox: String?
    /// An account id.
    var account: String?
    var unread: Bool?
    var flagged: Bool?
    var since: Date?
    var before: Date?
    var hasAttachments: Bool?
    var limit: Int = 25
}

struct OutgoingMail: Sendable, Equatable {
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String
    /// The sender address. It picks the account that sends. Nil means Mail's default account.
    var from: String? = nil
}

/// The only way the mail module reaches Mail. The real store reads the Envelope Index and the `.emlx` files,
/// and runs AppleScript. Tests use a fake.
protocol MailStore: Sendable {
    /// Writes need a running Mail. The script would start Mail by itself, so the module checks first.
    func isMailRunning() -> Bool
    /// True when macOS lets applesauce read the Mail folder (Full Disk Access).
    func hasFullDiskAccess() -> Bool

    func accounts() async throws -> [MailAccount]
    /// `account` is an account id.
    func mailboxes(account: String?) async throws -> [MailboxInfo]

    /// The fast search in the Envelope Index. It throws `PERMISSION_DENIED` when the file cannot be read
    /// and `INTERNAL_ERROR` when the layout is not the expected one.
    func searchIndex(_ query: MailSearchQuery) async throws -> SearchPage
    /// The slow search through Mail. It needs `mailbox`. It uses `since` and `before` as the range.
    func searchScripted(_ query: MailSearchQuery) async throws -> SearchPage

    /// A message from the index, with its body from the `.emlx` file when there is one.
    func indexMessage(id: String) async throws -> MailMessage
    /// A message read through Mail. Needs a running Mail.
    func scriptedMessage(_ ref: MessageRef) async throws -> MailMessage
    /// Where messages live (from the index). Throws `NOT_FOUND` for an unknown id.
    func locate(ids: [String]) async throws -> [MessageRef]

    func compose(_ mail: OutgoingMail, send: Bool) async throws
    func reply(to ref: MessageRef, body: String, replyAll: Bool, send: Bool) async throws
    /// `account` is an account name or id. Nil means the account of each message.
    func move(_ refs: [MessageRef], mailbox: String, account: String?) async throws
    func setFlagged(_ refs: [MessageRef], _ flagged: Bool) async throws
    func setRead(_ refs: [MessageRef], _ read: Bool) async throws
    func delete(_ refs: [MessageRef]) async throws
}
