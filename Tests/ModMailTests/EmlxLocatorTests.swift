import Foundation
import Testing

@testable import ModMail

@Suite struct EmlxLocatorTests {
    func tree(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "applesauce-emlx-\(UUID().uuidString)", isDirectory: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return root
    }

    @Test func findsFileInTheLikelyFolders() throws {
        let root = try tree([
            "ACC/INBOX.mbox/STORE/Data/Messages/12.emlx",
            "ACC/INBOX.mbox/STORE/Data/3/2/1/Messages/123456.emlx",
            "ACC/INBOX.mbox/Info.plist",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = EmlxLocator(root: root)
        #expect(locator.find(accountId: "ACC", mailbox: "INBOX", rowid: "12")?.url.lastPathComponent == "12.emlx")
        #expect(locator.find(accountId: "ACC", mailbox: "INBOX", rowid: "123456")?.partial == false)
    }

    @Test func handlesPartialFilesAndNestedMailboxes() throws {
        let root = try tree([
            "ACC/[Gmail].mbox/All Mail.mbox/S1/Data/Messages/77.partial.emlx",
            "ACC/[Gmail].mbox/All Mail.mbox/S1/Data/9/9/Messages/99.emlx",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = EmlxLocator(root: root)
        let partial = locator.find(accountId: "ACC", mailbox: "[Gmail]/All Mail", rowid: "77")
        #expect(partial?.partial == true)
        #expect(partial?.url.lastPathComponent == "77.partial.emlx")
        // The middle folders differ by version, so the walk finds files in other folders too.
        #expect(locator.find(accountId: "ACC", mailbox: "[Gmail]/All Mail", rowid: "99")?.partial == false)
    }

    @Test func fullFileBeatsPartialAndMissingGivesNil() throws {
        let root = try tree([
            "ACC/INBOX.mbox/S/Data/Messages/5.partial.emlx", "ACC/INBOX.mbox/S/Data/Messages/5.emlx",
            "ACC/INBOX.mbox/Child.mbox/S/Data/Messages/8.emlx",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = EmlxLocator(root: root)
        #expect(locator.find(accountId: "ACC", mailbox: "INBOX", rowid: "5")?.partial == false)
        #expect(locator.find(accountId: "ACC", mailbox: "INBOX", rowid: "6") == nil)
        #expect(locator.find(accountId: "ACC", mailbox: "Nope", rowid: "5") == nil)
        // A file of a nested mailbox is not found through its parent.
        #expect(locator.find(accountId: "ACC", mailbox: "INBOX", rowid: "8") == nil)
        #expect(locator.find(accountId: "ACC", mailbox: "INBOX/Child", rowid: "8") != nil)
    }
}
