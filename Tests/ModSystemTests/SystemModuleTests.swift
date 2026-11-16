import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModSystem

@Suite struct SystemModuleTests {
    func store(_ edit: (inout FakeSystemStore.State) -> Void = { _ in }) -> FakeSystemStore {
        var state = FakeSystemStore.State()
        edit(&state)
        return FakeSystemStore(state)
    }

    func module(_ store: FakeSystemStore, backendTimeout: Double = 30) -> SystemModule {
        SystemModule(store: store, backendTimeout: backendTimeout)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeSystemStore) async throws -> ToolOutput {
        try await module(store).call(tool, Arguments(args))
    }

    func failure(
        _ tool: String, _ args: [String: Value], on store: FakeSystemStore, using module: SystemModule? = nil
    ) async -> ToolError? {
        do {
            _ = try await (module ?? self.module(store)).call(tool, Arguments(args))
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func withTempFile(_ body: (String) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-test-\(UUID()).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url.path)
    }

    // MARK: tools

    @Test func toolNamesAndFlags() {
        let system = module(store())
        #expect(system.tools.map(\.tool.name) == ["get_clipboard", "set_clipboard", "notify", "open"])
        #expect(system.tools.filter(\.isWrite).map(\.tool.name) == ["set_clipboard", "notify", "open"])
        #expect(system.tools.filter { $0.tool.annotations.destructiveHint == true }.map(\.tool.name) == ["open"])
        #expect(system.permissions.isEmpty)
    }

    @Test func readOnlyRegistryHidesWriteTools() async throws {
        let config = try Config.parse(arguments: ["--read-only"], environment: [:])
        let registry = try Registry(available: [module(store())], config: config)
        #expect(registry.tools.map(\.name) == ["get_clipboard"])
    }

    // MARK: input checks

    @Test func badInputNeverReachesTheStore() async throws {
        let fake = store()
        try await withTempFile { file in
            let bad: [(String, [String: Value])] = [
                ("set_clipboard", [:]),
                ("set_clipboard", ["text": ""]),
                ("set_clipboard", ["text": 3]),
                ("notify", ["message": "m"]),
                ("notify", ["title": "t"]),
                ("notify", ["title": "", "message": "m"]),
                ("notify", ["title": "t", "message": "m", "subtitle": 1]),
                ("open", [:]),
                ("open", ["url": "https://example.com", "path": .string(file)]),
                ("open", ["url": "not a url"]),
                ("open", ["url": "ftp://example.com"]),
                ("open", ["url": "javascript:alert(1)"]),
                ("open", ["url": "file:///etc/hosts"]),
                ("open", ["url": "https://"]),
                ("open", ["path": "relative/file.txt"]),
                ("open", ["path": "/no/such/applesauce/file.txt"]),
            ]
            for (tool, args) in bad {
                let error = await failure(tool, args, on: fake)
                #expect(error != nil, "\(tool) \(args)")
            }
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func missingPathIsNotFoundAndFileURLPointsToPath() async {
        let missing = await failure("open", ["path": "/no/such/applesauce/file.txt"], on: store())
        #expect(missing?.code == .notFound)
        let file = await failure("open", ["url": "file:///etc/hosts"], on: store())
        #expect(file?.code == .invalidInput)
        #expect(file?.fix?.contains("path") == true)
    }

    // MARK: clipboard

    @Test func readsClipboardText() async throws {
        let fake = store { $0.clipboard = ClipboardContent(text: "hello", types: ["public.utf8-plain-text"]) }
        let output = try await run("get_clipboard", [:], on: fake)
        #expect(output.text == "hello")
        #expect(output.structured?.objectValue?["has_text"]?.boolValue == true)
        #expect(output.structured?.objectValue?["text"]?.stringValue == "hello")
    }

    @Test func saysWhenClipboardHoldsNoText() async throws {
        let image = store { $0.clipboard = ClipboardContent(text: nil, types: ["public.png"]) }
        let output = try await run("get_clipboard", [:], on: image)
        #expect(output.text.contains("no text"))
        #expect(output.text.contains("public.png"))
        #expect(output.structured?.objectValue?["has_text"]?.boolValue == false)
        let empty = try await run("get_clipboard", [:], on: store())
        #expect(empty.text.contains("it is empty"))
    }

    @Test func longClipboardTextIsCut() async throws {
        let long = String(repeating: "a", count: SystemModule.clipboardLimit + 10)
        let fake = store { $0.clipboard = ClipboardContent(text: long, types: ["public.utf8-plain-text"]) }
        let output = try await run("get_clipboard", [:], on: fake)
        #expect(output.structured?.objectValue?["truncated"]?.boolValue == true)
        #expect(output.structured?.objectValue?["text"]?.stringValue?.count == SystemModule.clipboardLimit)
        #expect(output.text.contains("cut at"))
    }

    @Test func setsClipboardText() async throws {
        let fake = store()
        let output = try await run("set_clipboard", ["text": "new text"], on: fake)
        #expect(fake.read(\.clipboard.text) == "new text")
        #expect(output.text.contains("8 characters"))
    }

    // MARK: notify

    @Test func notifyPassesValuesAsGiven() async throws {
        let fake = store()
        _ = try await run(
            "notify", ["title": #"T "quoted" \ "#, "message": "line1\nline2", "subtitle": "sub"], on: fake)
        let sent = try #require(fake.read(\.notified))
        #expect(sent.title == #"T "quoted" \ "#)
        #expect(sent.message == "line1\nline2")
        #expect(sent.subtitle == "sub")
        _ = try await run("notify", ["title": "t", "message": "m", "subtitle": ""], on: fake)
        #expect(fake.read(\.notified)?.subtitle == nil)
    }

    @Test func notifyScriptTakesValuesFromArgvOnly() {
        let script = AppKitSystemStore.notifyScript
        #expect(script.contains("on run argv"))
        #expect(script.contains("item 1 of argv"))
        #expect(!script.contains("\\("))
    }

    // MARK: open

    @Test func opensAllowedURLs() async throws {
        let fake = store()
        for text in ["https://example.com/a?b=1", "HTTP://example.com", "mailto:someone@example.com"] {
            _ = try await run("open", ["url": .string(text)], on: fake)
        }
        #expect(
            fake.read(\.opened).map(\.absoluteString) == [
                "https://example.com/a?b=1", "HTTP://example.com", "mailto:someone@example.com",
            ])
    }

    @Test func opensAnExistingPath() async throws {
        let fake = store()
        try await withTempFile { file in
            let output = try await run("open", ["path": .string(file)], on: fake)
            #expect(fake.read(\.opened).first?.path == file)
            #expect(output.text.contains(file))
        }
    }

    @Test func refusesRunnableAndBundlePaths() async throws {
        let fake = store()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("system-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Files: the extension list covers some, the content type covers the rest (js).
        let files = ["run.sh", "run.PY", "run.command", "Setup.pkg", "disk.dmg", "link.webloc", "run.js"]
        for name in files {
            let url = root.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        // Directories: an app, a bundle and a framework are all packages.
        let folders = ["Thing.app", "Thing.bundle", "Thing.framework", "Flow.workflow"]
        for name in folders {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // A link to a script is refused too.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("harmless.txt"), withDestinationURL: root.appendingPathComponent("run.sh"))
        for name in files + folders + ["harmless.txt"] {
            let error = await failure("open", ["path": .string(root.appendingPathComponent(name).path)], on: fake)
            #expect(error?.code == .invalidInput, "\(name)")
            #expect(error?.message.contains("script") == true, "\(name)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    @Test func plainFoldersAndDocumentsStillOpen() async throws {
        let fake = store()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("system-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("notes.pdf")
        FileManager.default.createFile(atPath: doc.path, contents: Data("x".utf8))
        for url in [root, doc] {
            _ = try await run("open", ["path": .string(url.path)], on: fake)
        }
        #expect(fake.read(\.opened).count == 2)
    }

    @Test func backendFailureReachesTheCaller() async {
        let boom = ToolError(.internalError, "macOS could not open it.")
        let fake = store { $0.failure = boom }
        let error = await failure("open", ["url": "https://example.com"], on: fake)
        #expect(error == boom)
    }

    @Test func slowBackendGivesTimeout() async {
        let fake = store { $0.delay = 5 }
        let error = await failure(
            "notify", ["title": "t", "message": "m"], on: fake, using: module(fake, backendTimeout: 0.1))
        #expect(error?.code == .timeout)
    }
}
