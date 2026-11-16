import AppleSauceCore
import Foundation
import Testing

@testable import ModMail

/// The checks for files that a mail carries. The tests use a temp folder as the home folder.
@Suite struct OutgoingFilesTests {
    let home: URL
    let fileManager = FileManager.default

    init() throws {
        let base = fileManager.temporaryDirectory.appendingPathComponent(
            "applesauce-files-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        // The real path, so that the checks compare the same text (/var is a link to /private/var).
        home = URL(fileURLWithPath: OutgoingFiles.realPath(base.path) ?? base.path, isDirectory: true)
    }

    func file(_ relative: String, bytes: Int = 4) throws -> String {
        let url = home.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: url)
        return url.path
    }

    func check(_ paths: [String], limit: Int = AttachmentCache.maxBytes) throws -> [OutgoingFile] {
        try OutgoingFiles.check(paths, limit: limit, home: home.path)
    }

    func error(_ paths: [String], limit: Int = AttachmentCache.maxBytes) -> ToolError? {
        do {
            _ = try check(paths, limit: limit)
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func cleanUp() { try? fileManager.removeItem(at: home) }

    @Test func goodFilesPassAndKeepTheirOrder() throws {
        defer { cleanUp() }
        let a = try file("docs/a.pdf", bytes: 10)
        let b = try file("b.txt", bytes: 3)
        let files = try check([a, b])
        #expect(files.map(\.name) == ["a.pdf", "b.txt"])
        #expect(files.map(\.size) == [10, 3])
        #expect(files.map(\.path) == [a, b])
        #expect(try check([]).isEmpty)
    }

    @Test func pathsMustBeAbsoluteAndMustExist() throws {
        defer { cleanUp() }
        #expect(error(["a.txt"])?.code == .invalidInput)
        #expect(error(["~/a.txt"])?.code == .invalidInput)
        #expect(error([""])?.code == .invalidInput)
        #expect(error(["/a\0b"])?.code == .invalidInput)
        let missing = error([home.appendingPathComponent("nothing.txt").path])
        #expect(missing?.code == .notFound && missing?.message.contains("nothing.txt") == true)
        #expect(missing?.fix?.isEmpty == false)
    }

    @Test func foldersBundlesAndLinksToFoldersAreRefused() throws {
        defer { cleanUp() }
        _ = try file("folder/inside.txt")
        let folder = home.appendingPathComponent("folder").path
        #expect(error([folder])?.message.contains("folder or an app bundle") == true)
        let bundle = home.appendingPathComponent("Tool.app/Contents")
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(error([home.appendingPathComponent("Tool.app").path])?.code == .invalidInput)
        let link = home.appendingPathComponent("link-to-folder").path
        try fileManager.createSymbolicLink(atPath: link, withDestinationPath: folder)
        #expect(error([link])?.code == .invalidInput)
    }

    @Test func aLinkToAFileIsResolvedToItsRealPath() throws {
        defer { cleanUp() }
        let real = try file("real/data.bin")
        let link = home.appendingPathComponent("short.bin").path
        try fileManager.createSymbolicLink(atPath: link, withDestinationPath: real)
        let files = try check([link])
        #expect(files.first?.path == real && files.first?.name == "data.bin")
    }

    @Test func unreadableFilesAreRefused() throws {
        defer { cleanUp() }
        let path = try file("secret.txt")
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        // A process that runs as root can read the file anyway.
        if !fileManager.isReadableFile(atPath: path) { #expect(error([path])?.code == .permissionDenied) }
    }

    @Test func limitsOnCountAndSizes() throws {
        defer { cleanUp() }
        let small = try file("small.txt", bytes: 10)
        let big = try file("big.txt", bytes: 11)
        #expect(error([big], limit: 10)?.message.contains("each file") == true)
        #expect(try check([small], limit: 10).count == 1)
        // Each file is inside the limit. All together they are not.
        let total = error([small, small], limit: 15)
        #expect(total?.code == .invalidInput && total?.message.contains("in all") == true)
        #expect(try check([small, small], limit: 20).count == 2)

        let ten = Array(repeating: small, count: OutgoingFiles.maxCount)
        #expect(try check(ten).count == OutgoingFiles.maxCount)
        let eleven = ten + [small]
        #expect(error(eleven)?.message.contains("limit is 10") == true)
    }

    @Test func secretFoldersAreRefusedEvenThroughALink() throws {
        defer { cleanUp() }
        let key = try file(".ssh/id_ed25519")
        let keychain = try file("Library/Keychains/login.keychain-db")
        let mcp = try file(".config/applesauce-mcp/token.json")
        let netrc = try file(".netrc")
        for path in [key, keychain, mcp, netrc] {
            let refused = error([path])
            #expect(refused?.code == .invalidInput && refused?.message.contains("does not attach") == true, "\(path)")
        }
        #expect(error([key])?.message.contains("~/.ssh") == true)
        // The real path decides: a link in an allowed folder does not help.
        let link = home.appendingPathComponent("innocent.txt").path
        try fileManager.createSymbolicLink(atPath: link, withDestinationPath: key)
        #expect(error([link])?.message.contains("~/.ssh") == true)
        // Names ignore case, as on the default Mac disk.
        #expect(OutgoingFiles.blockedReason("\(home.path.uppercased())/.SSH/id", homes: [home.path]) != nil)
        // A similar name is fine.
        let other = try file(".ssh-notes/readme.txt")
        #expect(try check([other]).count == 1)
        let docs = try file("Documents/.ssh.txt")
        #expect(try check([docs]).count == 1)
    }
}
