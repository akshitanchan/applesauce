import AppleSauceCore
import Foundation
import Testing

@testable import ModShortcuts

/// These tests run a fake `shortcuts` script from a temporary folder. The real tool never runs.
@Suite struct ShortcutsCLIStoreTests {
    /// Writes an executable shell script and returns its path.
    func script(_ body: String) throws -> (path: String, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fake-shortcuts-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("shortcuts")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url.path, { try? FileManager.default.removeItem(at: folder) })
    }

    /// The fake tool finds the value that follows a flag. $2 is the shortcut name.
    static let findFlag = """
        next=""; out=""; in=""
        for a in "$@"; do
          if [ "$next" = out ]; then out="$a"; fi
          if [ "$next" = in ]; then in="$a"; fi
          case "$a" in --output-path) next=out;; --input-path) next=in;; *) next="";; esac
        done
        """

    @Test func parsesListOutput() async throws {
        let fake = try script("printf 'One\\n\\n  Two  \\nThree\\n'")
        defer { fake.cleanup() }
        let store = ShortcutsCLIStore(executable: fake.path)
        #expect(try await store.list(folder: nil) == ["One", "Two", "Three"])
    }

    @Test func passesFolderAndFoldersFlags() async throws {
        let fake = try script("echo \"$@\"")
        defer { fake.cleanup() }
        let store = ShortcutsCLIStore(executable: fake.path)
        #expect(try await store.list(folder: "My Folder") == ["list --folder-name My Folder"])
        #expect(try await store.folders() == ["list --folders"])
    }

    @Test func runsWithInputFileAndReadsOutputFile() async throws {
        let fake = try script(Self.findFlag + "\ncp \"$in\" \"$out\"; echo \" via $2\" >> \"$out\"")
        defer { fake.cleanup() }
        let store = ShortcutsCLIStore(executable: fake.path)
        let output = try await store.run(name: "My Shortcut", input: "hello $HOME 'x'")
        #expect(output == .text("hello $HOME 'x' via My Shortcut\n", truncated: false))
    }

    @Test func tempFilesAreRemoved() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID())")
        let fake = try script(Self.findFlag + "\necho \"$out\" > \"\(marker.path)\"; echo hi > \"$out\"")
        defer {
            fake.cleanup()
            try? FileManager.default.removeItem(at: marker)
        }
        let store = ShortcutsCLIStore(executable: fake.path)
        _ = try await store.run(name: "x", input: "in")
        let outPath = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = URL(fileURLWithPath: outPath).deletingLastPathComponent().path
        #expect(folder.contains("applesauce-shortcut-"))
        #expect(!FileManager.default.fileExists(atPath: folder))
    }

    @Test func outputFileOverTheLimitIsNotRead() async throws {
        let size = ShortcutsCLIStore.outputFileLimit + 1
        let fake = try script(Self.findFlag + "\nhead -c \(size) /dev/zero > \"$out\"")
        defer { fake.cleanup() }
        let output = try await ShortcutsCLIStore(executable: fake.path).run(name: "x", input: nil)
        #expect(output == .other(type: nil, bytes: size))
    }

    @Test func noOutputFileMeansNone() async throws {
        let fake = try script("exit 0")
        defer { fake.cleanup() }
        let output = try await ShortcutsCLIStore(executable: fake.path).run(name: "x", input: nil)
        #expect(output == .none)
    }

    @Test func nonZeroExitIsAnInternalErrorWithStderr() async throws {
        let fake = try script("echo 'Error: boom' >&2; exit 1")
        defer { fake.cleanup() }
        do {
            _ = try await ShortcutsCLIStore(executable: fake.path).run(name: "x", input: nil)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("boom"))
        }
    }

    @Test func runTimeoutStopsTheShortcut() async throws {
        let fake = try script("sleep 30")
        defer { fake.cleanup() }
        let store = ShortcutsCLIStore(executable: fake.path, runTimeout: 0.3)
        do {
            _ = try await store.run(name: "Slow", input: nil)
            Issue.record("expected a timeout")
        } catch let error as ToolError {
            #expect(error.code == .timeout)
            #expect(error.message.contains("'Slow'"))
        }
    }

    // MARK: pure helpers

    @Test func classifiesOutput() {
        #expect(ShortcutsCLIStore.classify(Data()) == .none)
        #expect(ShortcutsCLIStore.classify(Data("text".utf8)) == .text("text", truncated: false))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3])
        #expect(ShortcutsCLIStore.classify(png) == .other(type: "image/png", bytes: 8))
        #expect(ShortcutsCLIStore.classify(Data([0xFF, 0xFE, 0x00, 0x01])) == .other(type: nil, bytes: 4))
        let long = Data(String(repeating: "a", count: ShortcutsCLIStore.textLimit + 5).utf8)
        guard case .text(let text, let truncated) = ShortcutsCLIStore.classify(long) else {
            Issue.record("expected text")
            return
        }
        #expect(truncated && text.count == ShortcutsCLIStore.textLimit)
    }
}
