// Reads Mail's index through SQLite3, which ships with macOS only.
#if os(macOS)
import AppleSauceCore
import Foundation

/// A mailbox row of the Envelope Index.
struct IndexMailbox: Sendable, Equatable {
    let rowid: Int64
    let url: String
    let accountId: String
    /// For example `INBOX` or `[Gmail]/All Mail`.
    let path: String
    let unread: Int?

    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

enum MailURL {
    /// `imap://ACCOUNT-ID/%5BGmail%5D/All%20Mail` gives account id `ACCOUNT-ID` and path `[Gmail]/All Mail`.
    /// Returns nil for text that has no `://` or no host.
    static func parse(_ url: String) -> (accountId: String, path: String)? {
        guard let scheme = url.range(of: "://") else { return nil }
        let rest = url[scheme.upperBound...]
        let host = rest.prefix { $0 != "/" }
        guard !host.isEmpty else { return nil }
        let path = rest.dropFirst(host.count).drop { $0 == "/" }
        return (
            String(host).removingPercentEncoding ?? String(host),
            String(path).removingPercentEncoding ?? String(path)
        )
    }
}

/// The read-only SQL layer over Mail's `Envelope Index` database.
///
/// Layout this code expects (macOS 13 and later, all of it checked at run time):
/// - `messages`: ROWID, subject (ROWID in `subjects`), sender (ROWID in `addresses`), date_received,
///   mailbox (ROWID in `mailboxes`), read, flagged. Optional: deleted, date_sent, subject_prefix (for example `Re: `).
/// - `subjects`: ROWID, subject. `addresses`: ROWID, address, comment (the display name).
/// - `mailboxes`: ROWID, url. Optional: unread_count.
/// - Optional tables: `recipients` (message, address, type; 0 is To, 1 is Cc),
///   `attachments` (message, name), `labels` (message_id, mailbox_id) for Gmail labels.
/// - Dates are seconds since 1970-01-01 UTC (Unix time) in recent versions. Older versions may differ.
///
/// A missing required column gives `INTERNAL_ERROR` that names it. Values go only through placeholders.
struct EnvelopeIndex {
    let db: SQLiteReader
    private let hasDeleted: Bool
    private let hasSubjectPrefix: Bool
    private let hasUnreadCount: Bool
    private let hasRecipients: Bool
    private let hasAttachments: Bool
    private let hasLabels: Bool

    init(db: SQLiteReader) throws {
        self.db = db
        let required: [(String, [String])] = [
            ("messages", ["ROWID", "subject", "sender", "date_received", "mailbox", "read", "flagged"]),
            ("subjects", ["ROWID", "subject"]),
            ("addresses", ["ROWID", "address", "comment"]),
            ("mailboxes", ["ROWID", "url"]),
        ]
        for (table, columns) in required {
            let present = try db.columns(of: table)
            if present.isEmpty { throw Self.schemaError("The Mail index has no table '\(table)'.") }
            if let missing = columns.first(where: { !present.contains($0) }) {
                throw Self.schemaError("The Mail index has no column '\(table).\(missing)'.")
            }
        }
        let messageColumns = try db.columns(of: "messages")
        hasDeleted = messageColumns.contains("deleted")
        hasSubjectPrefix = messageColumns.contains("subject_prefix")
        hasUnreadCount = try db.columns(of: "mailboxes").contains("unread_count")
        hasRecipients = try db.missingColumns(in: "recipients", ["message", "address", "type"]).isEmpty
        hasAttachments = try db.missingColumns(in: "attachments", ["message", "name"]).isEmpty
        hasLabels = try db.missingColumns(in: "labels", ["message_id", "mailbox_id"]).isEmpty
    }

    static func schemaError(_ detail: String) -> ToolError {
        ToolError(
            .internalError, "\(detail) Mail's database layout may have changed in this macOS version.",
            fix: "Report this error. Search uses the slower scoped search through Mail where it can.")
    }

    // MARK: mailboxes

    func mailboxes() throws -> [IndexMailbox] {
        let unread = hasUnreadCount ? "unread_count" : "NULL"
        return try db.rows("SELECT ROWID, url, \(unread) FROM mailboxes") { row in
            guard let rowid = row.int(0), let url = row.text(1), let parts = MailURL.parse(url) else { return nil }
            return IndexMailbox(
                rowid: rowid, url: url, accountId: parts.accountId, path: parts.path,
                unread: row.int(2).map(Int.init))
        }.compactMap { $0 }
    }

    // MARK: search

    private static let selectSummary = """
        SELECT m.ROWID, %S, a.address, a.comment, m.date_received, m.mailbox, m.read, m.flagged, %@
        FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        """

    private var summarySelect: String {
        let attachments =
            hasAttachments ? "EXISTS (SELECT 1 FROM attachments t WHERE t.message = m.ROWID)" : "NULL"
        // Mail keeps "Re: " and "Fwd: " apart from the subject text.
        let subject = hasSubjectPrefix ? "COALESCE(m.subject_prefix, '') || COALESCE(s.subject, '')" : "s.subject"
        return Self.selectSummary.replacingOccurrences(of: "%@", with: attachments)
            .replacingOccurrences(of: "%S", with: subject)
    }

    /// `%` and `_` in the user's text must not act as wildcards.
    static func likePattern(_ text: String) -> SQLiteValue {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return .text("%\(escaped)%")
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    /// The mailboxes that a mailbox name (or path) and an account id select. Throws `NOT_FOUND` for none.
    private func selectedMailboxes(_ all: [IndexMailbox], account: String?, mailbox: String?) throws
        -> [IndexMailbox]
    {
        let inAccount = all.filter {
            account == nil || $0.accountId.caseInsensitiveCompare(account ?? "") == .orderedSame
        }
        if let account, inAccount.isEmpty {
            throw ToolError(
                .notFound, "No account has the id '\(account)'.", fix: "Use an account id from list_accounts.")
        }
        guard let mailbox else { return inAccount }
        let wanted = mailbox.lowercased()
        let matched = inAccount.filter { $0.path.lowercased() == wanted || $0.name.lowercased() == wanted }
        guard matched.isEmpty else { return matched }
        let names = Set(inAccount.map(\.path)).sorted().prefix(30).map { "'\($0)'" }.joined(separator: ", ")
        throw ToolError(
            .notFound, "No mailbox is named '\(mailbox)'. Mailboxes: \(names.isEmpty ? "none" : names).",
            fix: "Use a name or path from list_mailboxes.")
    }

    func search(_ query: MailSearchQuery) throws -> SearchPage {
        let all = try mailboxes()
        var conditions: [String] = []
        var bindings: [SQLiteValue] = []
        let like = "LIKE ? ESCAPE '\\'"

        if hasDeleted { conditions.append("m.deleted = 0") }

        if query.account != nil || query.mailbox != nil {
            let ids = try selectedMailboxes(all, account: query.account, mailbox: query.mailbox).map(\.rowid)
            let marks = Self.placeholders(ids.count)
            var clause = "m.mailbox IN (\(marks))"
            bindings += ids.map { .integer($0) }
            // Gmail shows one message in many mailboxes through labels.
            if hasLabels {
                clause += " OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(marks)))"
                bindings += ids.map { .integer($0) }
            }
            conditions.append("(\(clause))")
        }
        if let text = query.text {
            conditions.append("(s.subject \(like) OR a.address \(like) OR a.comment \(like))")
            bindings += Array(repeating: Self.likePattern(text), count: 3)
        }
        if let from = query.from {
            conditions.append("(a.address \(like) OR a.comment \(like))")
            bindings += Array(repeating: Self.likePattern(from), count: 2)
        }
        if let subject = query.subject {
            conditions.append("s.subject \(like)")
            bindings.append(Self.likePattern(subject))
        }
        if let to = query.to {
            guard hasRecipients else { throw Self.schemaError("The Mail index has no table 'recipients'.") }
            conditions.append(
                """
                EXISTS (SELECT 1 FROM recipients r JOIN addresses ra ON ra.ROWID = r.address \
                WHERE r.message = m.ROWID AND (ra.address \(like) OR ra.comment \(like)))
                """)
            bindings += Array(repeating: Self.likePattern(to), count: 2)
        }
        if let unread = query.unread { conditions.append(unread ? "m.read = 0" : "m.read <> 0") }
        if let flagged = query.flagged { conditions.append(flagged ? "m.flagged <> 0" : "m.flagged = 0") }
        if let since = query.since {
            conditions.append("m.date_received >= ?")
            bindings.append(.integer(Int64(since.timeIntervalSince1970)))
        }
        if let before = query.before {
            conditions.append("m.date_received < ?")
            bindings.append(.integer(Int64(before.timeIntervalSince1970)))
        }
        if let wanted = query.hasAttachments {
            guard hasAttachments else { throw Self.schemaError("The Mail index has no table 'attachments'.") }
            conditions.append(
                "\(wanted ? "" : "NOT ")EXISTS (SELECT 1 FROM attachments t WHERE t.message = m.ROWID)")
        }

        let filter = conditions.isEmpty ? "" : "\nWHERE " + conditions.joined(separator: " AND ")
        let sql = summarySelect + filter + "\nORDER BY m.date_received DESC, m.ROWID DESC LIMIT ?"
        bindings.append(.integer(Int64(query.limit + 1)))

        let byID = Dictionary(all.map { ($0.rowid, $0) }, uniquingKeysWith: { first, _ in first })
        var items = try db.rows(sql, bindings) { Self.summary($0, mailboxes: byID) }
        let truncated = items.count > query.limit
        if truncated { items.removeLast(items.count - query.limit) }
        return SearchPage(items: items, truncated: truncated)
    }

    private static func summary(_ row: SQLiteRow, mailboxes: [Int64: IndexMailbox]) -> MessageSummary {
        let mailbox = row.int(5).flatMap { mailboxes[$0] }
        return MessageSummary(
            id: String(row.int(0) ?? 0), subject: row.text(1) ?? "",
            from: formatAddress(row.text(2), name: row.text(3)),
            date: row.double(4).map { Date(timeIntervalSince1970: $0) },
            mailbox: mailbox?.path ?? "", accountId: mailbox?.accountId ?? "",
            read: (row.int(6) ?? 0) != 0, flagged: (row.int(7) ?? 0) != 0,
            hasAttachments: row.int(8).map { $0 != 0 })
    }

    static func formatAddress(_ address: String?, name: String?) -> String {
        let address = address ?? ""
        guard let name, !name.isEmpty, name != address else { return address }
        return address.isEmpty ? name : "\(name) <\(address)>"
    }

    // MARK: one message

    struct Detail {
        let summary: MessageSummary
        let to: [String]
        let cc: [String]
        /// Attachment names from the index (no sizes).
        let attachmentNames: [String]
    }

    /// The message row with recipients. Returns nil when the id is not in the index.
    func message(rowid: Int64) throws -> Detail? {
        let byID = Dictionary(try mailboxes().map { ($0.rowid, $0) }, uniquingKeysWith: { first, _ in first })
        guard
            let summary = try db.rows(
                summarySelect + "\nWHERE m.ROWID = ?", [.integer(rowid)],
                {
                    Self.summary($0, mailboxes: byID)
                }
            ).first
        else { return nil }

        var to: [String] = []
        var cc: [String] = []
        if hasRecipients {
            let rows = try db.rows(
                """
                SELECT r.type, a.address, a.comment FROM recipients r JOIN addresses a ON a.ROWID = r.address \
                WHERE r.message = ? ORDER BY r.ROWID
                """, [.integer(rowid)]
            ) { ($0.int(0) ?? 0, Self.formatAddress($0.text(1), name: $0.text(2))) }
            to = rows.filter { $0.0 == 0 }.map(\.1)
            cc = rows.filter { $0.0 == 1 }.map(\.1)
        }
        var names: [String] = []
        if hasAttachments {
            names = try db.rows(
                "SELECT name FROM attachments WHERE message = ? ORDER BY ROWID", [.integer(rowid)]
            ) { $0.text(0) }.compactMap { $0 }
        }
        return Detail(summary: summary, to: to, cc: cc, attachmentNames: names)
    }

    /// The home mailbox of each message id. Ids that are not in the index are left out.
    func refs(rowids: [Int64]) throws -> [MessageRef] {
        guard !rowids.isEmpty else { return [] }
        let byID = Dictionary(try mailboxes().map { ($0.rowid, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = try db.rows(
            "SELECT ROWID, mailbox FROM messages WHERE ROWID IN (\(Self.placeholders(rowids.count)))",
            rowids.map { .integer($0) }
        ) { ($0.int(0) ?? 0, $0.int(1) ?? 0) }
        let found = Dictionary(rows, uniquingKeysWith: { first, _ in first })
        return rowids.compactMap { id in
            guard let mailboxID = found[id], let mailbox = byID[mailboxID] else { return nil }
            return MessageRef(id: String(id), accountId: mailbox.accountId, mailbox: mailbox.path)
        }
    }
}
#endif
