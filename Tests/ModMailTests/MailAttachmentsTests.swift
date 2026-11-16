import AppleSauceCore
import Foundation
import Testing

@testable import ModMail

/// The attachment code that reads message files. The tests build `.emlx` files in a temp folder. They never open the
/// real Mail folder.
@Suite struct MailAttachmentsTests {
    // MARK: fixtures

    static let hello = Data("hello attachment".utf8)

    /// A message with a plain text part and two attachments: a base64 text file and a quoted-printable one.
    static let fullMessage = """
        From: Ann <ann@example.com>
        Subject: Files
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        See the files.
        --B
        Content-Type: text/plain; name="a.txt"
        Content-Disposition: attachment; filename="a.txt"
        Content-Transfer-Encoding: base64

        \(Self.hello.base64EncodedString())
        --B
        Content-Type: text/plain; name="b.txt"
        Content-Disposition: attachment; filename="b.txt"
        Content-Transfer-Encoding: quoted-printable

        caf=C3=A9 =
        au lait
        --B--

        """

    /// Mail's `.partial.emlx` form: the attachment parts have no bytes, only `X-Apple-Content-Length`.
    static let partialMessage = """
        From: Ann <ann@example.com>
        Subject: Files
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: multipart/related; boundary="R"

        --R
        Content-Type: text/plain

        See the picture.
        --R
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="pic.png"
        Content-Type: image/png
        X-Apple-Content-Length: 4


        --R--
        --B
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="report.pdf"
        Content-Type: application/pdf
        X-Apple-Content-Length: 2000000


        --B--

        """

    func emlx(_ message: String) -> Data {
        let body = message.replacingOccurrences(of: "\n", with: "\r\n")
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict></dict></plist>"
        return Data("\(body.utf8.count)\n\(body)\(plist)".utf8)
    }

    struct Tree {
        let root: URL
        let messages: URL
        var attachments: URL { messages.deletingLastPathComponent().appendingPathComponent("Attachments") }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func tree() throws -> Tree {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "applesauce-att-\(UUID().uuidString)", isDirectory: true)
        let messages = root.appendingPathComponent("Data/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        return Tree(root: root, messages: messages)
    }

    func write(_ message: String, rowid: String, partial: Bool = false, in tree: Tree) throws -> EmlxLocator.Found {
        let url = tree.messages.appendingPathComponent("\(rowid)\(partial ? ".partial" : "").emlx")
        try emlx(message).write(to: url)
        return EmlxLocator.Found(url: url, partial: partial)
    }

    func folder() throws -> URL {
        try AttachmentCache.makeFolder(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(
                "applesauce-out-\(UUID().uuidString)", isDirectory: true))
    }

    func failure(_ body: () throws -> Void) -> ToolError? {
        do {
            try body()
            return nil
        } catch {
            return error as? ToolError
        }
    }

    // MARK: MIME parts

    @Test func partsKeepBytesAndMailsPartNumbers() {
        let parts = MIMEReader.attachmentParts(
            Array(Self.fullMessage.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        #expect(parts.map(\.name) == ["a.txt", "b.txt"] && parts.map(\.partID) == ["2", "3"])
        #expect(Data(parts[0].decoded()) == Self.hello && parts[0].size == Self.hello.count)
        #expect(String(decoding: parts[1].decoded(), as: UTF8.self) == "café au lait")
        // The list that get_message shows has the same order and names.
        let listed = MIMEReader.parse(Array(Self.fullMessage.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        #expect(listed.attachments.map(\.name) == parts.map(\.name))
    }

    @Test func nestedPartsGetDottedNumbersAndPartialPartsGetTheDeclaredSize() {
        let bytes = Array(Self.partialMessage.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let parts = MIMEReader.attachmentParts(bytes)
        #expect(parts.map(\.partID) == ["1.2", "2"] && parts.map(\.name) == ["pic.png", "report.pdf"])
        #expect(parts.map(\.size) == [4, 2_000_000])
        #expect(parts.allSatisfy { $0.decoded().isEmpty })
        // The size shows in get_message too.
        #expect(MIMEReader.parse(bytes).attachments.map(\.size) == [4, 2_000_000])
    }

    @Test func parseNeverKeepsBytes() {
        // `parse` has no `parts`: it returns names and sizes only.
        let parsed = MIMEReader.parse(Array(Self.fullMessage.utf8))
        #expect(parsed.attachments.count == 2)
    }

    // MARK: choosing

    @Test func resolveByIndexAndName() throws {
        let names = ["a.txt", "B.TXT", "dup.png", "dup.png"]
        #expect(try MailAttachments.resolve(.index(1), in: names) == 0)
        #expect(try MailAttachments.resolve(.index(4), in: names) == 3)
        #expect(try MailAttachments.resolve(.name("a.txt"), in: names) == 0)
        // A name matches in any case when no exact name exists.
        #expect(try MailAttachments.resolve(.name("b.txt"), in: names) == 1)
        let outOfRange = failure { _ = try MailAttachments.resolve(.index(5), in: names) }
        #expect(outOfRange?.code == .notFound && outOfRange?.message.contains("4 attachments") == true)
        #expect(failure { _ = try MailAttachments.resolve(.index(0), in: names) }?.code == .notFound)
        let missing = failure { _ = try MailAttachments.resolve(.name("zzz"), in: names) }
        #expect(missing?.code == .notFound && missing?.message.contains("1. a.txt") == true)
        let ambiguous = failure { _ = try MailAttachments.resolve(.name("dup.png"), in: names) }
        #expect(ambiguous?.code == .ambiguous && ambiguous?.message.contains("3, 4") == true)
        #expect(ambiguous?.fix?.contains("index") == true)
        #expect(failure { _ = try MailAttachments.resolve(.index(1), in: []) }?.code == .notFound)
    }

    // MARK: saving from the message file

    @Test func savesBase64AndQuotedPrintableAttachments() throws {
        let tree = try tree()
        let out = try folder()
        defer {
            tree.remove()
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }
        let found = try write(Self.fullMessage, rowid: "100", in: tree)
        let first = try MailAttachments.save(
            emlx: found, rowid: "100", pick: .name("a.txt"), into: out, limit: 1000)
        #expect(first.name == "a.txt" && first.size == Self.hello.count)
        #expect(first.file.deletingLastPathComponent().path == out.path)
        #expect(try Data(contentsOf: first.file) == Self.hello)
        let second = try MailAttachments.save(emlx: found, rowid: "100", pick: .index(2), into: out, limit: 1000)
        #expect(try String(contentsOf: second.file, encoding: .utf8) == "café au lait")
    }

    @Test func refusesALargeAttachmentBeforeWritingAnything() throws {
        let tree = try tree()
        let out = try folder()
        defer {
            tree.remove()
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }
        let found = try write(Self.fullMessage, rowid: "100", in: tree)
        let error = failure {
            _ = try MailAttachments.save(emlx: found, rowid: "100", pick: .name("a.txt"), into: out, limit: 10)
        }
        #expect(error?.code == .invalidInput && error?.message.contains("a.txt") == true)
        #expect(error?.message.contains("MB") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func aNameWithPathPartsStaysInsideTheFolder() throws {
        let tree = try tree()
        let out = try folder()
        defer {
            tree.remove()
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }
        let evil = Self.fullMessage.replacingOccurrences(of: "filename=\"a.txt\"", with: "filename=\"../../evil.txt\"")
        let found = try write(evil, rowid: "100", in: tree)
        let saved = try MailAttachments.save(emlx: found, rowid: "100", pick: .index(1), into: out, limit: 1000)
        #expect(saved.file.deletingLastPathComponent().path == out.path)
        #expect(!saved.file.lastPathComponent.contains("/") && !saved.file.lastPathComponent.hasPrefix("."))
        #expect(saved.name == "../../evil.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).count == 1)
    }

    @Test func copiesDownloadedAttachmentsOfAPartialMessage() throws {
        let tree = try tree()
        let out = try folder()
        defer {
            tree.remove()
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }
        let found = try write(Self.partialMessage, rowid: "200", partial: true, in: tree)
        let place = tree.attachments.appendingPathComponent("200/1.2", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let picture = Data([0x89, 0x50, 0x4E, 0x47])
        try picture.write(to: place.appendingPathComponent("pic.png"))
        let saved = try MailAttachments.save(
            emlx: found, rowid: "200", pick: .name("pic.png"), into: out, limit: 1000)
        #expect(saved.size == 4 && saved.file.deletingLastPathComponent().path == out.path)
        #expect(try Data(contentsOf: saved.file) == picture)
        // The copy is the user's own: the file in Mail's folder stays.
        #expect(FileManager.default.fileExists(atPath: place.appendingPathComponent("pic.png").path))
    }

    @Test func aPartialAttachmentThatIsNotDownloadedGivesAClearError() throws {
        let tree = try tree()
        let out = try folder()
        defer {
            tree.remove()
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }
        let found = try write(Self.partialMessage, rowid: "200", partial: true, in: tree)
        let error = failure {
            _ = try MailAttachments.save(emlx: found, rowid: "200", pick: .index(1), into: out, limit: 1000)
        }
        #expect(error?.code == .notFound && error?.message.contains("not downloaded") == true)
        #expect(error?.fix?.contains("Open the message in Mail") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func aDeclaredSizeAboveTheLimitIsRefusedWithoutAFile() throws {
        let tree = try tree()
        let out = try folder()
        defer {
            tree.remove()
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }
        let found = try write(Self.partialMessage, rowid: "200", partial: true, in: tree)
        let error = failure {
            _ = try MailAttachments.save(
                emlx: found, rowid: "200", pick: .name("report.pdf"), into: out, limit: AttachmentCache.maxBytes)
        }
        // 2 MB is under the limit: only a missing file stops it. A lower limit refuses it by size.
        #expect(error?.code == .notFound)
        let tooBig = failure {
            _ = try MailAttachments.save(
                emlx: found, rowid: "200", pick: .name("report.pdf"), into: out, limit: 1_000_000)
        }
        #expect(tooBig?.code == .invalidInput && tooBig?.message.contains("1.9 MB") == true)
    }

    @Test func aDownloadedFileAboveTheLimitIsRefusedBeforeTheCopy() throws {
        let tree = try tree()
        let out = try folder()
        defer {
            tree.remove()
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }
        let found = try write(Self.partialMessage, rowid: "200", partial: true, in: tree)
        let place = tree.attachments.appendingPathComponent("200/1.2", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        try Data(count: 5000).write(to: place.appendingPathComponent("pic.png"))
        let error = failure {
            _ = try MailAttachments.save(emlx: found, rowid: "200", pick: .index(1), into: out, limit: 1000)
        }
        #expect(error?.code == .invalidInput)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func theDownloadedFileComesFromTheFolderListingNotFromTheMessage() throws {
        let tree = try tree()
        let out = try folder()
        defer {
            tree.remove()
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }
        let evil = Self.partialMessage.replacingOccurrences(
            of: "filename=\"pic.png\"", with: "filename=\"../../../x.png\"")
        let found = try write(evil, rowid: "200", partial: true, in: tree)
        let place = tree.attachments.appendingPathComponent("200/1.2", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: place.appendingPathComponent("real name.png"))
        let saved = try MailAttachments.save(emlx: found, rowid: "200", pick: .index(1), into: out, limit: 1000)
        #expect(saved.file.deletingLastPathComponent().path == out.path)
        #expect(try Data(contentsOf: saved.file) == Data([1, 2, 3]))
    }

    @Test func aMessageWithoutAttachmentsSaysSo() throws {
        let tree = try tree()
        let out = try folder()
        defer {
            tree.remove()
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }
        let found = try write("Subject: Plain\n\nJust text.\n", rowid: "300", in: tree)
        let error = failure {
            _ = try MailAttachments.save(emlx: found, rowid: "300", pick: .index(1), into: out, limit: 1000)
        }
        #expect(error?.code == .notFound && error?.message == "The message has no attachments.")
    }

    // MARK: the real store, on a temp Mail folder

    func mailRoot(rowid: String, message: String, partial: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "applesauce-mail-\(UUID().uuidString)", isDirectory: true)
        let data = root.appendingPathComponent("V10/MailData", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data().write(to: data.appendingPathComponent("Envelope Index"))
        let messages = root.appendingPathComponent(
            "V10/ACC/INBOX.mbox/STORE/Data/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        try emlx(message).write(to: messages.appendingPathComponent("\(rowid)\(partial ? ".partial" : "").emlx"))
        return root
    }

    @Test func theStoreFindsTheMessageFileAndSavesTheAttachment() async throws {
        let root = try mailRoot(rowid: "42", message: Self.fullMessage)
        let out = try folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: out.deletingLastPathComponent())
        }
        let store = AppleMailStore(mailRoot: root)
        let ref = MessageRef(id: "42", accountId: "ACC", mailbox: "INBOX")
        let saved = try await store.saveAttachment(ref, pick: .name("a.txt"), into: out, limit: 1000)
        #expect(try Data(contentsOf: saved.file) == Self.hello)

        let missing = MessageRef(id: "43", accountId: "ACC", mailbox: "INBOX")
        do {
            _ = try await store.saveAttachment(missing, pick: .index(1), into: out, limit: 1000)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .notFound && error.message.contains("not on this Mac"))
        }
    }

    // MARK: script errors

    @Test func scriptErrorsBecomeToolErrors() {
        func make(_ text: String, _ number: Int) -> ToolError {
            MailScripts.scriptError(
                ToolError(.internalError, "12:40: execution error: \(text) (\(number))\n"))
        }
        let notFound = make("The message has no attachment named 'x'.", 1001)
        #expect(notFound.code == .notFound && notFound.message == "The message has no attachment named 'x'.")
        #expect(notFound.fix?.contains("get_message") == true)
        #expect(make("No message with id 5.", 1001).fix?.contains("search_mail") == true)
        #expect(make("The attachment 'a' is 30000000 bytes.", 1003).code == .invalidInput)
        #expect(make("More than one attachment is named 'a'.", 1004).code == .ambiguous)
        let notDownloaded = make("Mail has not downloaded the attachment 'a' yet.", 1005)
        #expect(notDownloaded.code == .notFound && notDownloaded.message.hasSuffix("yet."))
        let other = ToolError(.internalError, "something else (-1728)")
        #expect(MailScripts.scriptError(other) == other)
    }

    @Test func theAttachmentScriptTakesValuesOnlyThroughArgv() {
        #expect(
            MailScripts.saveAttachment.contains("item 5 of argv")
                && MailScripts.saveAttachment.contains("item 6 of argv"))
        #expect(MailScripts.saveAttachment.contains("save att in (POSIX file (item 6 of argv))"))
    }
}
