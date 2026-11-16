import Foundation
import Testing

@testable import ModMail

@Suite struct MIMEReaderTests {
    func parse(_ text: String) -> ParsedMail {
        MIMEReader.parse(Array(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    func parse(bytes: [UInt8]) -> ParsedMail { MIMEReader.parse(bytes) }

    @Test func plainMessageWithHeaders() {
        let mail = parse(
            """
            From: Ann Lee <ann@example.com>
            To: bob@example.com
            Cc: cy@example.com
            Subject: Hello
             there
            Date: Thu, 12 Nov 2026 09:30:00 +0100
            Message-ID: <abc@example.com>

            Line one
            Line two
            """)
        #expect(mail.subject == "Hello there")
        #expect(mail.from == "Ann Lee <ann@example.com>")
        #expect(mail.to == "bob@example.com")
        #expect(mail.cc == "cy@example.com")
        #expect(mail.messageID == "<abc@example.com>")
        #expect(mail.body == "Line one\r\nLine two")
        #expect(mail.attachments.isEmpty)
    }

    @Test func multipartAlternativePrefersPlainText() {
        let mail = parse(
            """
            Subject: Alt
            Content-Type: multipart/alternative; boundary="xyz"

            --xyz
            Content-Type: text/plain; charset=utf-8

            plain version
            --xyz
            Content-Type: text/html; charset=utf-8

            <p>html version</p>
            --xyz--
            """)
        #expect(mail.body == "plain version")
    }

    @Test func quotedPrintableUTF8() {
        let mail = parse(
            """
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            Caf=C3=A9 au lait, this line is long and =
            continues here.
            """)
        #expect(mail.body.hasPrefix("Café au lait, this line is long and continues here."))
    }

    @Test func base64Body() {
        let encoded = Data("Hello base64 world".utf8).base64EncodedString()
        let mail = parse(
            """
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: base64

            \(encoded)
            """)
        #expect(mail.body == "Hello base64 world")
    }

    @Test func latin1AndWindows1252() {
        let latin = parse(
            bytes: Array("Content-Type: text/plain; charset=iso-8859-1\r\n\r\nna".utf8) + [0xEF, 0x76, 0x65])
        #expect(latin.body == "naïve")
        let win = parse(
            bytes: Array("Content-Type: text/plain; charset=windows-1252\r\n\r\nprice ".utf8) + [0x80, 0x35])
        #expect(win.body == "price €5")
        // A bad UTF-8 body is read as windows-1252.
        let bad = parse(bytes: Array("Content-Type: text/plain; charset=utf-8\r\n\r\ncaf".utf8) + [0xE9])
        #expect(bad.body == "café")
    }

    @Test func htmlOnlyBecomesText() {
        let mail = parse(
            """
            Content-Type: text/html; charset=utf-8

            <html><head><style>p { color: red }</style></head><body>
            <p>Hello &amp; welcome&nbsp;&#169; <b>Ann</b></p><p>Second<br>line</p>
            <ul><li>one</li><li>two</li></ul>
            <script>alert(1)</script></body></html>
            """)
        #expect(mail.body == "Hello & welcome © Ann\nSecond\nline\n\n- one\n\n- two")
        #expect(!mail.body.contains("alert"))
        #expect(!mail.body.contains("color"))
    }

    @Test func listsAttachmentsWithoutReturningBytes() {
        let payload = Data(repeating: 7, count: 300).base64EncodedString(options: .lineLength76Characters)
        let mail = parse(
            """
            Content-Type: multipart/mixed; boundary="b1"

            --b1
            Content-Type: text/plain

            See attached.
            --b1
            Content-Type: application/pdf; name="report.pdf"
            Content-Disposition: attachment; filename="report.pdf"
            Content-Transfer-Encoding: base64

            \(payload.replacingOccurrences(of: "\r\n", with: "\n"))
            --b1
            Content-Type: image/png
            Content-Disposition: attachment; filename*=UTF-8''na%C3%AFve%20pic.png
            Content-Transfer-Encoding: 7bit

            12345
            --b1--
            """)
        #expect(mail.body == "See attached.")
        #expect(
            mail.attachments == [
                MailAttachment(name: "report.pdf", size: 300), MailAttachment(name: "naïve pic.png", size: 5),
            ])
        #expect(!mail.body.contains("report"))
    }

    @Test func nestedMultipartAndInlineImageWithoutName() {
        let mail = parse(
            """
            Content-Type: multipart/mixed; boundary="outer"

            --outer
            Content-Type: multipart/related; boundary="inner"

            --inner
            Content-Type: text/html

            <p>Hi</p>
            --inner
            Content-Type: image/png
            Content-ID: <img1>
            Content-Transfer-Encoding: base64

            AAAA
            --inner--
            --outer
            Content-Type: message/rfc822

            Subject: forwarded
            --outer--
            """)
        #expect(mail.body == "Hi")
        #expect(mail.attachments.map(\.name) == ["message.eml"])
    }

    @Test func encodedHeaderWords() {
        #expect(MIMEReader.decodeWords("=?UTF-8?B?Q2Fmw6k=?=") == "Café")
        #expect(MIMEReader.decodeWords("=?iso-8859-1?Q?Caf=E9_au_lait?=") == "Café au lait")
        #expect(MIMEReader.decodeWords("=?utf-8?Q?a?= =?utf-8?Q?b?=") == "ab")
        #expect(MIMEReader.decodeWords("Re: =?utf-8?Q?x?= tail") == "Re: x tail")
        let mail = parse("Subject: =?UTF-8?B?SGVsbG8g8J+Ymg==?=\nFrom: =?utf-8?Q?Zo=C3=AB?= <z@example.com>\n\nbody")
        #expect(mail.subject == "Hello 😚")
        #expect(mail.from == "Zoë <z@example.com>")
    }

    @Test func rfc2231ContinuationNames() {
        let value = MIMEReader.headerValue(
            "attachment; filename*0*=UTF-8''long%20na; filename*1*=me%20%C3%A9.txt")
        #expect(value.value == "attachment")
        #expect(value.params["filename"] == "long name é.txt")
    }

    @Test func emlxWrapperCutsTheMessageAndPlist() {
        let message = "Subject: Hi\r\n\r\nbody"
        let data = Data("\(message.utf8.count)\n\(message)<?xml version=\"1.0\"?><plist></plist>".utf8)
        let bytes = MIMEReader.messageBytes(inEmlx: data)
        #expect(String(decoding: bytes, as: UTF8.self) == message)
        #expect(MIMEReader.parse(bytes).body == "body")
        // No length line: the file is a plain message.
        let raw = MIMEReader.messageBytes(inEmlx: Data(message.utf8))
        #expect(String(decoding: raw, as: UTF8.self) == message)
    }

    @Test func hugeHTMLIsCutBeforeTheRegexRuns() {
        let html = "<p>" + String(repeating: "a", count: MIMEReader.htmlLimit + 5_000) + "</p><p>tail</p>"
        let text = MIMEReader.htmlToText(html)
        #expect(text.count == MIMEReader.htmlLimit - 3)
        #expect(!text.contains("tail"))
        #expect(MIMEReader.htmlToText("<p>Hi</p>") == "Hi")
    }

    @Test func emlxFilesOverTheLimitAreNotRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID()).emlx")
        try Data("12345678".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .data(let data) = MIMEReader.readEmlx(at: url, limit: 8) else {
            Issue.record("expected the file to be read")
            return
        }
        #expect(data.count == 8)
        guard case .tooLarge(let bytes) = MIMEReader.readEmlx(at: url, limit: 7) else {
            Issue.record("expected tooLarge")
            return
        }
        #expect(bytes == 8)
        let missing = url.appendingPathExtension("none")
        guard case .unreadable = MIMEReader.readEmlx(at: missing) else {
            Issue.record("expected unreadable")
            return
        }
        #expect(MIMEReader.emlxLimit == 50_000_000)
    }

    @Test func brokenInputDoesNotCrash() {
        #expect(parse("").body == "")
        #expect(parse("Content-Type: multipart/mixed\n\nno boundary").body == "")
        #expect(
            parse("Content-Type: multipart/mixed; boundary=q\n\n--q\nContent-Type: text/plain\n\nopen part").body
                == "open part")
        #expect(MIMEReader.decodeBase64(Array("!!!".utf8)).isEmpty)
    }
}
