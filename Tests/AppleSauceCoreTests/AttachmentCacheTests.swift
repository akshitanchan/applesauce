import Foundation
import Testing

@testable import AppleSauceCore

@Suite struct AttachmentCacheTests {
    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "applesauce-cache-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: names

    @Test func sanitizeKeepsPlainNames() {
        #expect(AttachmentCache.sanitize("report.pdf") == "report.pdf")
        #expect(AttachmentCache.sanitize("My Photo (1).JPG") == "My Photo (1).JPG")
        #expect(AttachmentCache.sanitize("Rechnung für März.pdf") == "Rechnung für März.pdf")
    }

    @Test func sanitizeStopsPathTraversal() {
        let names = [
            "../../etc/passwd", "..", "../", "/etc/passwd", "a/../b", "..\\..\\windows\\evil.exe", "....//x",
            "/", "\\", "...", ".hidden", "..hidden.txt", "a/b/c.txt", "name:with:colons.txt", "x/..",
            " .. ", "../.ssh/authorized_keys",
        ]
        for name in names {
            let safe = AttachmentCache.sanitize(name)
            #expect(!safe.contains("/") && !safe.contains("\\") && !safe.contains(":"), "\(name) -> \(safe)")
            #expect(!safe.contains(".."), "\(name) -> \(safe)")
            #expect(!safe.hasPrefix("."), "\(name) -> \(safe)")
            #expect(!safe.isEmpty, "\(name)")
            // The name stays inside the folder when it is joined to it.
            let folder = URL(fileURLWithPath: "/tmp/cache/abc", isDirectory: true)
            let joined = folder.appendingPathComponent(safe).standardizedFileURL
            #expect(joined.deletingLastPathComponent().path == folder.path, "\(name) -> \(safe)")
        }
        #expect(AttachmentCache.sanitize("../../etc/passwd") == "_._etc_passwd")
        #expect(AttachmentCache.sanitize("..") == "attachment")
        #expect(AttachmentCache.sanitize("") == "attachment")
        #expect(AttachmentCache.sanitize(".hidden") == "hidden")
        #expect(AttachmentCache.sanitize("a/b.txt") == "a_b.txt")
    }

    @Test func sanitizeRemovesControlCharactersAndCutsLongNames() {
        #expect(AttachmentCache.sanitize("a\u{0}b\nc.txt") == "a_b_c.txt")
        let long = String(repeating: "x", count: 400) + ".pdf"
        let safe = AttachmentCache.sanitize(long)
        #expect(safe.utf8.count <= AttachmentCache.maxNameBytes && safe.hasSuffix(".pdf"))
        let wide = String(repeating: "é", count: 200) + ".txt"
        #expect(AttachmentCache.sanitize(wide).utf8.count <= AttachmentCache.maxNameBytes)
    }

    // MARK: folders and files

    @Test func makeFolderAndWriteAreForTheUserOnly() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try AttachmentCache.makeFolder(root: root)
        let second = try AttachmentCache.makeFolder(root: root)
        #expect(first != second && first.deletingLastPathComponent().path == root.path)
        func permissions(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(first) == 0o700)
        let file = try AttachmentCache.write(Data("hi".utf8), name: "../../evil.txt", into: first)
        #expect(file.deletingLastPathComponent().path == first.path)
        #expect(try permissions(file) == 0o600)
        #expect(try Data(contentsOf: file) == Data("hi".utf8))
    }

    @Test func sweepRemovesOnlyItemsOlderThan24Hours() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let now = Date()
        func folder(hoursOld: Double) throws -> URL {
            let url = try AttachmentCache.makeFolder(root: root)
            _ = try AttachmentCache.write(Data("x".utf8), name: "a.txt", into: url)
            try fileManager.setAttributes(
                [.modificationDate: now.addingTimeInterval(-hoursOld * 3600)], ofItemAtPath: url.path)
            return url
        }
        let old = try folder(hoursOld: 25)
        let older = try folder(hoursOld: 200)
        let fresh = try folder(hoursOld: 23)
        let justNow = try folder(hoursOld: 0)
        let looseOld = root.appendingPathComponent("loose.txt")
        try Data("x".utf8).write(to: looseOld)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-48 * 3600)], ofItemAtPath: looseOld.path)

        #expect(AttachmentCache.sweep(root: root, now: now) == 3)
        #expect(!fileManager.fileExists(atPath: old.path) && !fileManager.fileExists(atPath: older.path))
        #expect(!fileManager.fileExists(atPath: looseOld.path))
        #expect(fileManager.fileExists(atPath: fresh.path) && fileManager.fileExists(atPath: justNow.path))
        // A second sweep has nothing to do. A missing root is not an error.
        #expect(AttachmentCache.sweep(root: root, now: now) == 0)
        #expect(AttachmentCache.sweep(root: tempRoot(), now: now) == 0)
        // A later clock makes the fresh folders old.
        #expect(AttachmentCache.sweep(root: root, now: now.addingTimeInterval(30 * 3600)) == 2)
    }

    @Test func limitIs25MegabytesAndTheErrorSaysSo() {
        #expect(AttachmentCache.maxBytes == 26_214_400)
        let error = AttachmentCache.tooLarge(name: "big.zip", bytes: 30 * 1_048_576)
        #expect(error.code == .invalidInput)
        #expect(error.message.contains("big.zip") && error.message.contains("30.0 MB"))
        #expect(error.message.contains("25.0 MB") && error.fix?.isEmpty == false)
    }
}
