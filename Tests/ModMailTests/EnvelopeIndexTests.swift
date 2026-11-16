import AppleSauceCore
import Foundation
import Testing

@testable import ModMail

@Suite struct EnvelopeIndexTests {
    func ids(_ page: SearchPage) -> [String] { page.items.map(\.id) }

    func search(_ edit: (inout MailSearchQuery) -> Void, options: MailFixture.Options = .init()) throws -> SearchPage {
        let fixture = try MailFixture(options)
        defer { fixture.remove() }
        var query = MailSearchQuery()
        edit(&query)
        return try fixture.index().search(query)
    }

    // MARK: mailbox urls

    @Test func parsesMailboxUrls() {
        let gmail = MailURL.parse("imap://ABC-123/%5BGmail%5D/All%20Mail")
        #expect(gmail?.accountId == "ABC-123")
        #expect(gmail?.path == "[Gmail]/All Mail")
        #expect(MailURL.parse("ews://X/INBOX")?.path == "INBOX")
        #expect(MailURL.parse("local://Y")?.path == "")
        #expect(MailURL.parse("not a url") == nil)
        #expect(MailURL.parse("imap:///INBOX") == nil)
    }

    @Test func listsMailboxes() throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        let boxes = try fixture.index().mailboxes()
        #expect(boxes.count == 4)
        let inbox = boxes.first { $0.rowid == 1 }
        #expect(inbox?.accountId == MailFixture.account1 && inbox?.path == "INBOX" && inbox?.unread == 2)
        #expect(boxes.first { $0.rowid == 2 }?.path == "[Gmail]/All Mail")
        #expect(boxes.first { $0.rowid == 2 }?.name == "All Mail")
    }

    // MARK: search

    @Test func newestFirstAndDeletedLeftOut() throws {
        let page = try search { _ in }
        #expect(ids(page) == ["4", "3", "2", "7", "1", "6"])
        #expect(page.truncated == false)
        #expect(page.items.first?.date == Date(timeIntervalSince1970: 1_700_300_000))
    }

    @Test func limitAndTruncatedFlag() throws {
        let page = try search { $0.limit = 2 }
        #expect(ids(page) == ["4", "3"])
        #expect(page.truncated)
        let exact = try search { $0.limit = 6 }
        #expect(exact.items.count == 6 && exact.truncated == false)
    }

    @Test func summaryFields() throws {
        let page = try search { $0.text = "Invoice" }
        let item = try #require(page.items.first)
        #expect(item.id == "2" && item.subject == "Invoice 100% paid")
        #expect(item.from == "Shop <shop@example.com>")
        #expect(item.mailbox == "INBOX" && item.accountId == MailFixture.account1)
        #expect(item.read && item.flagged && item.hasAttachments == true)
        let plain = try search { $0.text = "Lunch" }
        #expect(plain.items.first?.hasAttachments == false)
        #expect(try search { $0.subject = "Other" }.items.first?.from == "Ann Lee <ann@example.com>")
        #expect(try search { $0.text = "Gmail" }.items.first?.from == "bob@example.com")
    }

    @Test func subjectKeepsMailsPrefix() throws {
        #expect(try search { $0.subject = "Other" }.items.first?.subject == "Fwd: Other account")
        // A search that includes the prefix finds the message too.
        #expect(try search { $0.subject = "fwd: other" }.items.first?.id == "4")
        #expect(try search { $0.text = "Fwd: Other" }.items.first?.id == "4")
        #expect(try search { $0.text = "Lunch" }.items.first?.subject == "Lunch tomorrow")
        var options = MailFixture.Options()
        options.messageColumns = options.messageColumns.replacingOccurrences(of: ", subject_prefix TEXT", with: "")
        #expect(try search({ $0.subject = "Other" }, options: options).items.first?.subject == "Other account")
    }

    @Test func mailboxFilterByNameAcrossAccountsAndWithAccount() throws {
        #expect(ids(try search { $0.mailbox = "inbox" }) == ["4", "3", "2", "1"])
        #expect(
            ids(
                try search {
                    $0.mailbox = "INBOX"
                    $0.account = MailFixture.account1.lowercased()
                }) == ["3", "2", "1"])
        #expect(ids(try search { $0.account = MailFixture.account2 }) == ["4"])
    }

    @Test func gmailLabelsJoinIncludesLabelledMessages() throws {
        // Message 3 is stored in All Mail. It shows up in INBOX through the labels table.
        #expect(ids(try search { $0.mailbox = "[Gmail]/All Mail" }) == ["3"])
        #expect(ids(try search { $0.mailbox = "All Mail" }) == ["3"])
        var options = MailFixture.Options()
        options.withLabels = false
        #expect(ids(try search({ $0.mailbox = "INBOX" }, options: options)) == ["4", "2", "1"])
    }

    @Test func unknownMailboxIsNotFound() throws {
        do {
            _ = try search { $0.mailbox = "Nope" }
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .notFound)
            #expect(error.message.contains("Archive"))
        }
        #expect(throws: ToolError.self) { _ = try search { $0.account = "missing-account" } }
    }

    @Test func flagFilters() throws {
        #expect(ids(try search { $0.unread = true }) == ["4", "3", "1"])
        #expect(ids(try search { $0.unread = false }) == ["2", "7", "6"])
        #expect(ids(try search { $0.flagged = true }) == ["2"])
        #expect(ids(try search { $0.flagged = false }) == ["4", "3", "7", "1", "6"])
        #expect(ids(try search { $0.hasAttachments = true }) == ["2"])
        #expect(ids(try search { $0.hasAttachments = false }) == ["4", "3", "7", "1", "6"])
    }

    @Test func flagColorFilterAndSummary() throws {
        #expect(ids(try search { $0.flagColor = .orange }) == ["2"])
        // Message 3 has yellow bits but is not flagged, so it never matches.
        #expect(ids(try search { $0.flagColor = .yellow }).isEmpty)
        #expect(ids(try search { $0.flagColor = .red }).isEmpty)
        let flagged = try #require(try search { $0.text = "Invoice" }.items.first)
        #expect(flagged.flagColor == "orange")
        let unflagged = try #require(try search { $0.text = "Gmail" }.items.first)
        #expect(unflagged.flagged == false && unflagged.flagColor == nil)
    }

    @Test func flagColorBitsDecode() {
        let flagBit: Int64 = 0x10
        for color in FlagColor.allCases {
            let flags = (Int64(color.index) << Int64(EnvelopeIndex.flagColorShift)) | flagBit | 0x1_0000_0001
            #expect(EnvelopeIndex.flagColor(flags: flags, flagged: true) == color)
            #expect(EnvelopeIndex.flagColor(flags: flags, flagged: false) == nil)
        }
        // Real values from a Mail index: a flagged message without color bits is red, bit 39 is orange.
        #expect(EnvelopeIndex.flagColor(flags: 8_590_195_857, flagged: true) == .red)
        #expect(EnvelopeIndex.flagColor(flags: 558_346_009_745, flagged: true) == .orange)
        #expect(EnvelopeIndex.flagColor(flags: 575_525_878_929, flagged: true) == .orange)
        // Value 7 is not a color.
        #expect(EnvelopeIndex.flagColor(flags: 7 << 39, flagged: true) == nil)
    }

    @Test func flagColorFilterNeedsTheFlagsColumn() throws {
        var options = MailFixture.Options()
        options.messageColumns =
            "ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, date_received INTEGER, mailbox INTEGER, read INTEGER, flagged INTEGER, deleted INTEGER"
        let fixture = try MailFixture(options)
        defer { fixture.remove() }
        let index = try fixture.index()
        #expect(throws: ToolError.self) { _ = try index.search(MailSearchQuery(flagColor: .red)) }
        let page = try index.search(MailSearchQuery(flagged: true))
        #expect(page.items.first?.flagColor == nil)
    }

    @Test func dateRange() throws {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let before = Date(timeIntervalSince1970: 1_700_200_000)
        #expect(ids(try search { $0.since = since }) == ["4", "3", "2", "7", "1"])
        #expect(ids(try search { $0.before = before }) == ["2", "7", "1", "6"])
        #expect(
            ids(
                try search {
                    $0.since = since
                    $0.before = before
                }) == ["2", "7", "1"])
    }

    @Test func textFilters() throws {
        #expect(ids(try search { $0.from = "ann@example" }) == ["4", "1"])
        #expect(ids(try search { $0.from = "Ann Lee" }) == ["4", "1"])
        #expect(ids(try search { $0.text = "shop" }) == ["2", "6"])
        #expect(ids(try search { $0.text = "LUNCH" }) == ["1"])
        #expect(ids(try search { $0.to = "bob@" }) == ["1"])
        #expect(ids(try search { $0.to = "ann" }) == ["2", "1"])
        #expect(
            ids(
                try search {
                    $0.from = "ann"
                    $0.unread = true
                    $0.subject = "lunch"
                }) == ["1"])
    }

    @Test func wildcardsAndQuotesInUserTextAreLiteral() throws {
        #expect(ids(try search { $0.text = "100%" }) == ["2"])
        #expect(ids(try search { $0.text = "%" }) == ["2"])
        #expect(ids(try search { $0.text = "Under_score" }) == ["7"])
        #expect(ids(try search { $0.text = "Und_rscore" }).isEmpty)
        #expect(try search { $0.text = "x'; DROP TABLE messages; --" }.items.isEmpty)
        #expect(ids(try search { _ in }).count == 6)
    }

    // MARK: schema

    @Test func missingRequiredColumnNamesTheColumn() throws {
        var options = MailFixture.Options()
        options.messageColumns =
            "ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, date_received INTEGER, mailbox INTEGER, flagged INTEGER"
        let fixture = try MailFixture(options)
        defer { fixture.remove() }
        do {
            _ = try fixture.index()
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("messages.read"))
        }
    }

    @Test func missingTableIsNamed() throws {
        let empty = try MailFixture.empty()
        defer { empty.remove() }
        do {
            _ = try empty.index()
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("table 'messages'"))
        }
    }

    @Test func optionalPartsMayBeMissing() throws {
        var options = MailFixture.Options()
        options.messageColumns =
            "ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER, date_received INTEGER, mailbox INTEGER, read INTEGER, flagged INTEGER"
        options.withLabels = false
        options.withRecipients = false
        options.withAttachments = false
        options.mailboxColumns = "ROWID INTEGER PRIMARY KEY, url TEXT"
        let fixture = try MailFixture(options)
        defer { fixture.remove() }
        let index = try fixture.index()
        let page = try index.search(MailSearchQuery())
        // Without a deleted column nothing is filtered out, so message 5 shows.
        #expect(ids(page) == ["5", "4", "3", "2", "7", "1", "6"])
        #expect(page.items.allSatisfy { $0.hasAttachments == nil })
        #expect(try index.mailboxes().allSatisfy { $0.unread == nil })
        // Filters that need a missing table are an error, so the module can fall back.
        #expect(throws: ToolError.self) { _ = try index.search(MailSearchQuery(to: "bob")) }
        #expect(throws: ToolError.self) { _ = try index.search(MailSearchQuery(hasAttachments: true)) }
    }

    // MARK: one message

    @Test func messageDetail() throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        let index = try fixture.index()
        let one = try #require(try index.message(rowid: 1))
        #expect(one.summary.subject == "Lunch tomorrow")
        #expect(one.to == ["bob@example.com"])
        #expect(one.cc == ["Ann Lee <ann@example.com>"])
        #expect(try index.message(rowid: 2)?.attachmentNames == ["report.pdf", "photo.png"])
        #expect(try index.message(rowid: 999) == nil)
    }

    @Test func refsUseTheHomeMailbox() throws {
        let fixture = try MailFixture()
        defer { fixture.remove() }
        let refs = try fixture.index().refs(rowids: [3, 1, 999])
        #expect(
            refs == [
                MessageRef(id: "3", accountId: MailFixture.account1, mailbox: "[Gmail]/All Mail"),
                MessageRef(id: "1", accountId: MailFixture.account1, mailbox: "INBOX"),
            ])
    }
}
