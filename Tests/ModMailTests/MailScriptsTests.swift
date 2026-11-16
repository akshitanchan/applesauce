import AppleSauceCore
import Foundation
import Testing

@testable import ModMail

@Suite struct MailScriptsTests {
    let fs = String(MailScripts.fieldSeparator)
    let rs = String(MailScripts.recordSeparator)

    @Test func userValuesStayInArgvAndNeverEnterTheScript() {
        let evil = "x\" & (do shell script \"rm -rf ~\") & \"\n'; end tell"
        let mail = OutgoingMail(to: [evil], cc: [], bcc: ["b@c.d"], subject: evil, body: evil)
        let args = MailScripts.composeArguments(mail, send: false)
        #expect(args == ["draft", evil, evil, "1", "0", "1", "0", MailScripts.none, evil, "b@c.d"])
        let withFile = OutgoingMail(to: ["a@b.c"], cc: [], bcc: [], subject: "s", body: "b", attachments: [evil])
        #expect(
            MailScripts.composeArguments(withFile, send: true) == [
                "send", "s", "b", "1", "0", "0", "1", MailScripts.none, "a@b.c", evil,
            ])
        // A file path is only ever read from argv, and the script attaches it as a POSIX file.
        #expect(
            MailScripts.compose.contains(
                "make new attachment with properties {file name:(POSIX file (item pos of argv))}"))
        #expect(MailScripts.compose.contains("rm -rf") == false)
        #expect(MailScripts.composeArguments(mail, send: true).first == "send")

        let ref = MessageRef(id: "5", accountId: "ACC", mailbox: evil)
        #expect(
            MailScripts.replyArguments(ref: ref, body: evil, replyAll: true, send: false)
                == ["draft", "true", evil, "ACC", evil, "5"])
        let change = MailScripts.changeArguments(action: "move", value: evil, targetAccount: nil, refs: [ref, ref])
        #expect(change == ["move", evil, MailScripts.none, "2", "ACC", evil, "5", "ACC", evil, "5"])
    }

    @Test func scriptsStripSeparatorsFromValues() {
        // Subjects and senders go through `safeText`, which removes characters 30 and 31.
        #expect(MailScripts.prelude.contains("set AppleScript's text item delimiters to {fs, rs}"))
        #expect(MailScripts.search.contains("my safeText(item i of cols's msgSubjects)"))
        #expect(MailScripts.search.contains("my safeText(item i of cols's msgSenders)"))
    }

    @Test func everyScriptIsBuiltFromConstantsOnly() {
        for script in [
            MailScripts.accounts, MailScripts.mailboxes, MailScripts.search, MailScripts.message,
            MailScripts.change, MailScripts.compose, MailScripts.reply,
        ] {
            #expect(script.contains("on run argv"))
            // The message lookup lives in one place.
            #expect(script.components(separatedBy: "on findMessage").count == 2)
            // No interpolation marker was left in the text.
            #expect(script.contains("\\(") == false)
        }
    }

    @Test func mailboxLookupsOnlySwallowNotFoundErrors() {
        let start = MailScripts.prelude.range(of: "on findMailbox")!.lowerBound
        let end = MailScripts.prelude.range(of: "end findMailbox")!.upperBound
        let reraise = "if errNum is not -1728 and errNum is not -1719 then error errMsg number errNum"
        #expect(MailScripts.prelude[start..<end].contains("on error errMsg number errNum"))
        #expect(MailScripts.prelude[start..<end].contains(reraise))
        // The search looks up a mailbox too.
        #expect(MailScripts.search.contains("on error errMsg number errNum"))
        #expect(MailScripts.search.contains(reraise))
    }

    @Test func parsesAccountsMailboxesAndSearch() {
        let accounts = MailScripts.parseAccounts("A1\(fs)Work\(fs)a@w.example,b@w.example\(rs)A2\(fs)Home\(fs)")
        #expect(
            accounts == [
                MailAccount(id: "A1", name: "Work", emails: ["a@w.example", "b@w.example"]),
                MailAccount(id: "A2", name: "Home", emails: []),
            ])
        let boxes = MailScripts.parseMailboxes("A1\(fs)Work\(fs)[Gmail]/All Mail\(fs)4\(rs)A1\(fs)Work\(fs)INBOX\(fs)x")
        #expect(
            boxes.first
                == MailboxInfo(name: "All Mail", path: "[Gmail]/All Mail", accountId: "A1", account: "Work", unread: 4))
        #expect(boxes.last?.unread == nil)

        let row =
            "42\(fs)Subject, with: tab\t\(fs)Ann <a@b.c>\(fs)2026-11-12 09:30:00\(fs)false\(fs)true\(fs)INBOX\(fs)A1\(fs)1"
        let found = MailScripts.parseSearch(row + rs + "broken\(fs)row")
        #expect(found.count == 1)
        #expect(found[0].flagColor == "orange")
        #expect(found[0].id == "42" && found[0].read == false && found[0].flagged == true)
        #expect(found[0].subject == "Subject, with: tab\t" && found[0].accountId == "A1")
        let date = found[0].date.map { MailScripts.dateText($0) }
        #expect(date == "2026-11-12 09:30:00")
        #expect(MailScripts.parseSearch("").isEmpty)
    }

    @Test func flagColorFromAppleScriptOutput() {
        #expect(MailScripts.colorName("0", flagged: true) == "red")
        #expect(MailScripts.colorName("6", flagged: true) == "gray")
        #expect(MailScripts.colorName("-1", flagged: true) == nil)
        #expect(MailScripts.colorName("2", flagged: false) == nil)
        #expect(MailScripts.colorName("", flagged: true) == nil)
        // An older row without the color field still parses.
        let old = "1\(fs)S\(fs)a@b.c\(fs)2026-11-12 09:30:00\(fs)true\(fs)true\(fs)INBOX\(fs)A1"
        #expect(MailScripts.parseSearch(old).first?.flagColor == nil)
    }

    @Test func scopedFilterByFlagColor() {
        func item(_ id: String, flagged: Bool, color: String?) -> MessageSummary {
            MessageSummary(
                id: id, subject: "s", from: "a@b.c", date: Date(timeIntervalSince1970: Double(id) ?? 0),
                mailbox: "INBOX", accountId: "A", read: true, flagged: flagged, hasAttachments: nil, flagColor: color)
        }
        let items = [
            item("1", flagged: true, color: "red"), item("2", flagged: true, color: "orange"),
            item("3", flagged: false, color: nil),
        ]
        #expect(MailScripts.filter(items, MailSearchQuery(flagColor: .orange, limit: 10)).items.map(\.id) == ["2"])
        #expect(MailScripts.filter(items, MailSearchQuery(flagColor: .green, limit: 10)).items.isEmpty)
    }

    @Test func scopedFilterSortsNewestFirstAndCuts() {
        func item(
            _ id: String, _ subject: String, from: String = "a@b.c", day: Int, read: Bool = false, flagged: Bool = false
        ) -> MessageSummary {
            MessageSummary(
                id: id, subject: subject, from: from, date: Date(timeIntervalSince1970: Double(day) * 86400),
                mailbox: "INBOX", accountId: "A", read: read, flagged: flagged, hasAttachments: nil)
        }
        let items = [
            item("1", "Café menu", day: 1), item("2", "Report", from: "Boss <boss@x.y>", day: 3, read: true),
            item("3", "Report two", day: 2, flagged: true), item("4", "Other", day: 4),
        ]
        var query = MailSearchQuery(limit: 10)
        #expect(MailScripts.filter(items, query).items.map(\.id) == ["4", "2", "3", "1"])
        query.text = "report"
        #expect(MailScripts.filter(items, query).items.map(\.id) == ["2", "3"])
        query.text = "cafe"
        #expect(MailScripts.filter(items, query).items.map(\.id) == ["1"])
        query = MailSearchQuery(from: "boss", limit: 10)
        #expect(MailScripts.filter(items, query).items.map(\.id) == ["2"])
        query = MailSearchQuery(unread: true, limit: 10)
        #expect(MailScripts.filter(items, query).items.map(\.id) == ["4", "3", "1"])
        query = MailSearchQuery(flagged: true, limit: 10)
        #expect(MailScripts.filter(items, query).items.map(\.id) == ["3"])
        query = MailSearchQuery(limit: 2)
        let page = MailScripts.filter(items, query)
        #expect(page.items.map(\.id) == ["4", "2"] && page.truncated)
    }

    @Test func parsesTheMessageScriptOutput() {
        let us = "\u{1C}"
        let gs = "\u{1D}"
        let text = [
            "Hi", "Ann <a@b.c>", "2026-11-12 09:30:00", "true", "false", "-1", "x@y.z,q@y.z", "",
            "a.pdf\(us)100\(gs)b.png\(us)5", "Line1\nLine2 \(fs) rest",
        ]
        .joined(separator: fs)
        let ref = MessageRef(id: "7", accountId: "A", mailbox: "INBOX")
        let message = MailScripts.parseMessage(text, ref: ref)
        #expect(message?.subject == "Hi" && message?.read == true && message?.flagged == false)
        #expect(message?.to == ["x@y.z", "q@y.z"] && message?.cc == [])
        #expect(
            message?.attachments == [MailAttachment(name: "a.pdf", size: 100), MailAttachment(name: "b.png", size: 5)])
        #expect(message?.body == "Line1\nLine2 \(fs) rest")
        #expect(message?.bodySource == "applescript")
        #expect(message?.flagColor == nil)
        let flaggedText = text.replacingOccurrences(of: "true\(fs)false\(fs)-1", with: "true\(fs)true\(fs)4")
        #expect(MailScripts.parseMessage(flaggedText, ref: ref)?.flagColor == "blue")
        #expect(MailScripts.parseMessage("too few\(fs)fields", ref: ref) == nil)
    }

    @Test func bodyIsCutAt100000Characters() {
        let (same, cutSame) = MailScripts.limitBody(String(repeating: "a", count: 100_000))
        #expect(same.count == 100_000 && cutSame == false)
        let (cut, truncated) = MailScripts.limitBody(String(repeating: "é", count: 100_001))
        #expect(cut.count == 100_000 && truncated)
    }

    @Test func notFoundScriptErrorsAreMapped() {
        let message = MailScripts.cleanMessage(
            "12:40: execution error: No message with id 5 in mailbox 'INBOX'. (1001)\n")
        #expect(message == "No message with id 5 in mailbox 'INBOX'.")
        #expect(AppleScript.errorNumber(in: "execution error: x (1001)") == 1001)
    }

    @Test func dateTextRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let text = MailScripts.dateText(date)
        #expect(text.count == 19)
        #expect(MailScripts.parseDate(text) == date)
        #expect(MailScripts.parseDate("") == nil)
        #expect(
            MailScripts.searchArguments(account: nil, mailbox: "INBOX", since: date, before: date)
                == [MailScripts.none, "INBOX", text, text])
    }
}
