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

/// The seven flag colors of Mail. `index` is the value of Mail's AppleScript property `flag index`.
enum FlagColor: String, CaseIterable, Sendable, Equatable {
    case red, orange, yellow, green, blue, purple, gray

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    init?(index: Int) {
        guard Self.allCases.indices.contains(index) else { return nil }
        self = Self.allCases[index]
    }

    static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
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
    /// The flag color name, for example `orange`. Nil when the message is not flagged or the color is not known.
    var flagColor: String? = nil
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
    /// The flag color name. Nil when the message is not flagged or the color is not known.
    var flagColor: String? = nil
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
    /// Only flagged messages with this color.
    var flagColor: FlagColor?
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
    /// Real paths of the files to attach. The module has checked them (see `OutgoingFiles`).
    var attachments: [String] = []
}

/// A saved draft with what `send_draft` needs to build it again.
struct DraftMessage: Sendable, Equatable {
    /// Subject, sender, to, cc, plain text body and attachments of the draft.
    let message: MailMessage
    let bcc: [String]
    /// The address part of the sender, for example `me@work.example`. Empty when the draft has none.
    let senderAddress: String
}

/// The only way the mail module reaches Mail. The real store reads the Envelope Index and the `.emlx` files,
/// and runs AppleScript. Tests use a fake.
protocol MailStore: Sendable {
    /// True when Mail is running now. Nothing is started.
    func isMailRunning() -> Bool
    /// Makes sure Mail is running. When it is not, Mail is started hidden in the background, and the call waits
    /// (about 20 seconds at most) until Mail answers. Mail stays open. Throws `APP_NOT_RUNNING` when it does not start.
    func ensureRunning() async throws
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
    /// A saved draft, read through Mail (it has Bcc, which the index does not). Needs a running Mail.
    func draft(_ ref: MessageRef) async throws -> DraftMessage
    /// Where messages live (from the index). Throws `NOT_FOUND` for an unknown id.
    func locate(ids: [String]) async throws -> [MessageRef]

    /// Saves one attachment of a message as a file in `folder` (the folder exists). It reads the message file, or,
    /// without Full Disk Access, asks Mail to save it. It refuses an attachment above `limit` bytes before it reads
    /// the bytes. It throws `NOT_FOUND` when the attachment does not exist or Mail has not downloaded it.
    func saveAttachment(_ ref: MessageRef, pick: AttachmentPick, into folder: URL, limit: Int) async throws
        -> SavedAttachment

    func compose(_ mail: OutgoingMail, send: Bool) async throws
    func reply(to ref: MessageRef, body: String, replyAll: Bool, send: Bool) async throws
    /// `account` is an account name or id. Nil means the account of each message.
    func move(_ refs: [MessageRef], mailbox: String, account: String?) async throws
    /// `color` is only used when `flagged` is true. Nil keeps Mail's default flag.
    func setFlagged(_ refs: [MessageRef], _ flagged: Bool, color: FlagColor?) async throws
    func setRead(_ refs: [MessageRef], _ read: Bool) async throws
    func delete(_ refs: [MessageRef]) async throws
}
