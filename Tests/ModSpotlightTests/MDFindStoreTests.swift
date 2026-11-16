import AppleSauceCore
import Foundation
import Testing

@testable import ModSpotlight

/// These tests use a fake `mdfind` script and files in a temporary folder. The real index is never read.
@Suite struct MDFindStoreTests {
    func withTempFolder(_ body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdfind-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    func script(in folder: URL, _ body: String) throws -> String {
        let url = folder.appendingPathComponent("mdfind")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func buildsArgvWithTheQueryLast() {
        #expect(MDFindStore.arguments(query: "q q", folder: nil) == ["-0", "q q"])
        #expect(MDFindStore.arguments(query: "q", folder: "/a b") == ["-0", "-onlyin", "/a b", "q"])
    }

    @Test func splitsNulSeparatedPaths() async throws {
        try await withTempFolder { folder in
            let path = try script(in: folder, #"printf '/a/one\0/a/two words\0/a/line\nbreak\0'"#)
            let found = try await MDFindStore(executable: path).search(query: "x", folder: nil)
            #expect(found == SearchHits(paths: ["/a/one", "/a/two words", "/a/line\nbreak"]))
        }
    }

    @Test func bigOutputIsCutAtACompletePath() async throws {
        try await withTempFolder { folder in
            // 20 paths of 10 bytes with the NUL, 200 bytes in all. Then the script would go on for a long time.
            let path = try script(
                in: folder, #"i=0; while [ $i -lt 20 ]; do printf '/path/%03d\0' $i; i=$((i+1)); done; sleep 30"#)
            // 95 bytes: 9 whole paths and 5 bytes of the tenth.
            let store = MDFindStore(executable: path, timeout: 10, outputLimit: 95)
            let started = Date()
            let found = try await store.search(query: "x", folder: nil)
            #expect(Date().timeIntervalSince(started) < 8)
            #expect(found.truncated)
            #expect(found.paths == (0..<9).map { String(format: "/path/%03d", $0) })
        }
    }

    @Test func outputUnderTheLimitIsNotMarkedCut() async throws {
        try await withTempFolder { folder in
            let path = try script(in: folder, #"printf '/a/one\0/a/two\0'"#)
            let found = try await MDFindStore(executable: path, outputLimit: 1000).search(query: "x", folder: nil)
            #expect(found == SearchHits(paths: ["/a/one", "/a/two"], truncated: false))
        }
    }

    @Test func badQueryIsInvalidInput() async throws {
        try await withTempFolder { folder in
            let path = try script(in: folder, "echo \"Failed to create query for 'x'.\" >&2; exit 1")
            do {
                _ = try await MDFindStore(executable: path).search(query: "x", folder: nil)
                Issue.record("expected an error")
            } catch let error as ToolError {
                #expect(error.code == .invalidInput)
            }
        }
    }

    @Test func otherFailureIsInternalError() async throws {
        try await withTempFolder { folder in
            let path = try script(in: folder, "echo oops >&2; exit 2")
            do {
                _ = try await MDFindStore(executable: path).search(query: "x", folder: nil)
                Issue.record("expected an error")
            } catch let error as ToolError {
                #expect(error.code == .internalError)
                #expect(error.message.contains("oops"))
            }
        }
    }

    @Test func describesFilesAndFoldersAndSkipsMissing() async throws {
        try await withTempFolder { folder in
            let file = folder.appendingPathComponent("note.txt")
            try Data("12345".utf8).write(to: file)
            let store = MDFindStore()
            let info = try #require(await store.describe(path: file.path))
            #expect(info.name == "note.txt")
            #expect(info.size == 5)
            #expect(!info.kind.isEmpty)
            #expect(info.modified != nil)
            let dir = try #require(await store.describe(path: folder.path))
            #expect(dir.size == nil)
            #expect(await store.describe(path: folder.path + "/nothing.txt") == nil)
        }
    }
}
