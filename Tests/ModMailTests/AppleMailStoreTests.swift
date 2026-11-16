import AppleSauceCore
import Foundation
import Testing

@testable import ModMail

@Suite struct AppleMailStoreTests {
    func folder(_ names: [String], index: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "applesauce-root-\(UUID().uuidString)", isDirectory: true)
        for name in names {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in index {
            let data = root.appendingPathComponent("\(name)/MailData")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try Data().write(to: data.appendingPathComponent("Envelope Index"))
        }
        return root
    }

    @Test func picksTheHighestVersionWithAnIndex() throws {
        let root = try folder(["V9", "V10", "V11", "Other", "V2x"], index: ["V9", "V10"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try AppleMailStore.latestVersionFolder(in: root).lastPathComponent == "V10")
    }

    @Test func versionsCompareAsNumbers() throws {
        let root = try folder(["V9", "V10"], index: ["V9", "V10"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try AppleMailStore.latestVersionFolder(in: root).lastPathComponent == "V10")
    }

    @Test func missingFolderOrIndexIsAClearError() throws {
        let none = FileManager.default.temporaryDirectory.appendingPathComponent("applesauce-no-\(UUID())")
        do {
            _ = try AppleMailStore.latestVersionFolder(in: none)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .permissionDenied)
            #expect(error.fix == Permission.fullDiskAccess.fix(for: .denied))
        }
        let empty = try folder(["V10"])
        defer { try? FileManager.default.removeItem(at: empty) }
        do {
            _ = try AppleMailStore.latestVersionFolder(in: empty)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .notFound)
        }
    }

    @Test func fullDiskAccessIsFalseWhenTheFolderCannotBeListed() {
        let none = FileManager.default.temporaryDirectory.appendingPathComponent("applesauce-no-\(UUID())")
        #expect(AppleMailStore(mailRoot: none).hasFullDiskAccess() == false)
    }
}
