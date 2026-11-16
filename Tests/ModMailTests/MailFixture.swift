import AppleSauceCore
import Foundation
import SQLite3

@testable import ModMail

/// A tiny Envelope Index in a temp folder. It has the tables and columns that the mail module reads.
/// The test never opens the real Envelope Index.
struct MailFixture {
    let folder: URL
    var path: String { folder.appendingPathComponent("Envelope Index").path }

    struct Options {
        var messageColumns =
            "ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, date_received INTEGER, mailbox INTEGER, read INTEGER, flagged INTEGER, deleted INTEGER, subject_prefix TEXT"
        var withLabels = true
        var withRecipients = true
        var withAttachments = true
        var mailboxColumns = "ROWID INTEGER PRIMARY KEY, url TEXT, unread_count INTEGER"
    }

    static let account1 = "11111111-AAAA-4AAA-8AAA-111111111111"
    static let account2 = "22222222-BBBB-4BBB-8BBB-222222222222"

    private init(folder: URL) { self.folder = folder }

    private static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "applesauce-mail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func run(_ statements: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw ToolError(.internalError, "fixture open failed") }
        defer { sqlite3_close(db) }
        for statement in statements {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
                throw ToolError(.internalError, "fixture failed: \(statement) \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    /// A database with none of the mail tables.
    static func empty() throws -> MailFixture {
        let fixture = MailFixture(folder: try makeFolder())
        try fixture.run(["CREATE TABLE other (x INTEGER)"])
        return fixture
    }

    init(_ options: Options = Options()) throws {
        self.init(folder: try Self.makeFolder())
        var statements = [
            "CREATE TABLE messages (\(options.messageColumns))",
            "CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT)",
            "CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT)",
            "CREATE TABLE mailboxes (\(options.mailboxColumns))",
            "INSERT INTO subjects VALUES (1, 'Lunch tomorrow'), (2, 'Invoice 100% paid'), (3, 'Gmail labelled'), (4, 'Other account'), (5, 'Deleted one'), (6, 'Old news'), (7, 'Under_score')",
            "INSERT INTO addresses VALUES (1, 'ann@example.com', 'Ann Lee'), (2, 'bob@example.com', ''), (3, 'shop@example.com', 'Shop')",
        ]
        // Rows are inserted by column name, so a test can drop a column from the options.
        func insert(_ table: String, columns: String, _ values: [String: String]) -> String {
            let names = columns.split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) }
                .filter { values[$0] != nil }
            return
                "INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(names.map { values[$0] ?? "NULL" }.joined(separator: ", ")))"
        }
        let mailboxes: [(Int, String, Int)] = [
            (1, "imap://\(Self.account1)/INBOX", 2),
            (2, "imap://\(Self.account1)/%5BGmail%5D/All%20Mail", 0),
            (3, "imap://\(Self.account1)/Archive", 0),
            (4, "imap://\(Self.account2)/INBOX", 1),
        ]
        for box in mailboxes {
            statements.append(
                insert(
                    "mailboxes", columns: options.mailboxColumns,
                    ["ROWID": "\(box.0)", "url": "'\(box.1)'", "unread_count": "\(box.2)"]))
        }
        let rows: [(Int, Int, Int, Int, Int, Int, Int, Int)] = [
            // rowid, subject, sender, date, mailbox, read, flagged, deleted
            (1, 1, 1, 1_700_000_000, 1, 0, 0, 0),
            (2, 2, 3, 1_700_100_000, 1, 1, 1, 0),
            (3, 3, 2, 1_700_200_000, 2, 0, 0, 0),
            (4, 4, 1, 1_700_300_000, 4, 0, 0, 0),
            (5, 5, 2, 1_700_400_000, 1, 0, 0, 1),
            (6, 6, 3, 1_600_000_000, 3, 1, 0, 0),
            (7, 7, 2, 1_700_050_000, 3, 1, 0, 0),
        ]
        for row in rows {
            statements.append(
                insert(
                    "messages", columns: options.messageColumns,
                    [
                        "ROWID": "\(row.0)", "subject": "\(row.1)", "sender": "\(row.2)",
                        "date_received": "\(row.3)", "mailbox": "\(row.4)", "read": "\(row.5)",
                        "flagged": "\(row.6)", "deleted": "\(row.7)",
                        "subject_prefix": row.0 == 4 ? "'Fwd: '" : "NULL",
                    ]))
        }
        if options.withLabels {
            statements += [
                "CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER)",
                // Message 3 lives in All Mail and carries the INBOX label.
                "INSERT INTO labels VALUES (3, 1)",
            ]
        }
        if options.withRecipients {
            statements += [
                "CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER)",
                "INSERT INTO recipients (message, address, type, position) VALUES (1, 2, 0, 0), (1, 1, 1, 1), (2, 1, 0, 0)",
            ]
        }
        if options.withAttachments {
            statements += [
                "CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INTEGER, attachment_id TEXT, name TEXT)",
                "INSERT INTO attachments (message, attachment_id, name) VALUES (2, '1', 'report.pdf'), (2, '2', 'photo.png')",
            ]
        }

        try run(statements)
    }

    func index() throws -> EnvelopeIndex { try EnvelopeIndex(db: SQLiteReader(path: path)) }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}
