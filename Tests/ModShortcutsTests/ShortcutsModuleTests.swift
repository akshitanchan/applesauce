import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModShortcuts

@Suite struct ShortcutsModuleTests {
    func store(_ edit: (inout FakeShortcutsStore.State) -> Void = { _ in }) -> FakeShortcutsStore {
        var state = FakeShortcutsStore.State()
        state.shortcuts = ["Morning Routine", "Resize Image", "resize photo", "Send Report"]
        state.folders = ["Work": ["Send Report"], "Home": ["Morning Routine"]]
        edit(&state)
        return FakeShortcutsStore(state)
    }

    func module(_ store: FakeShortcutsStore, runTimeout: Double = 125) -> ShortcutsModule {
        ShortcutsModule(store: store, runTimeout: runTimeout)
    }

    func run(_ tool: String, _ args: [String: Value], on store: FakeShortcutsStore) async throws -> ToolOutput {
        try await module(store).call(tool, Arguments(args))
    }

    func failure(
        _ tool: String, _ args: [String: Value], on store: FakeShortcutsStore, using module: ShortcutsModule? = nil
    ) async -> ToolError? {
        do {
            _ = try await (module ?? self.module(store)).call(tool, Arguments(args))
            return nil
        } catch {
            return error as? ToolError
        }
    }

    // MARK: tools

    @Test func toolNamesAndFlags() {
        let tools = module(store()).tools
        #expect(tools.map(\.tool.name) == ["list_shortcuts", "run_shortcut"])
        #expect(tools.filter(\.isWrite).map(\.tool.name) == ["run_shortcut"])
        #expect(tools.last?.tool.annotations.destructiveHint == true)
        #expect(module(store()).permissions.isEmpty)
    }

    @Test func readOnlyRegistryHidesWriteTools() async throws {
        let config = try Config.parse(arguments: ["--read-only"], environment: [:])
        let registry = try Registry(available: [module(store())], config: config)
        #expect(registry.tools.map(\.name) == ["list_shortcuts"])
        let result = await registry.call("run_shortcut", arguments: ["name": "Send Report"])
        #expect(result.isError == true)
    }

    // MARK: input checks

    @Test func badInputNeverReachesTheStore() async {
        let fake = store()
        let bad: [(String, [String: Value])] = [
            ("list_shortcuts", ["folder": ""]),
            ("list_shortcuts", ["folder": 3]),
            ("run_shortcut", [:]),
            ("run_shortcut", ["name": ""]),
            ("run_shortcut", ["name": " "]),
            ("run_shortcut", ["name": "x", "input": 5]),
        ]
        for (tool, args) in bad {
            let error = await failure(tool, args, on: fake)
            #expect(error?.code == .invalidInput, "\(tool) \(args)")
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    // MARK: list

    @Test func listsAllShortcutsSorted() async throws {
        let output = try await run("list_shortcuts", [:], on: store())
        let names = output.structured?.objectValue?["shortcuts"]?.arrayValue?.compactMap(\.stringValue)
        #expect(names == ["Morning Routine", "Resize Image", "resize photo", "Send Report"])
        #expect(output.text.hasPrefix("4 shortcuts."))
    }

    @Test func listsOneFolderIgnoringCase() async throws {
        let fake = store()
        let output = try await run("list_shortcuts", ["folder": "wORk"], on: fake)
        let names = output.structured?.objectValue?["shortcuts"]?.arrayValue?.compactMap(\.stringValue)
        #expect(names == ["Send Report"])
        #expect(output.structured?.objectValue?["folder"]?.stringValue == "Work")
    }

    @Test func unknownFolderListsTheFolders() async {
        let error = await failure("list_shortcuts", ["folder": "Nope"], on: store())
        #expect(error?.code == .notFound)
        #expect(error?.message.contains("No folder has a similar name") == true)
    }

    // MARK: run

    @Test func runsByExactNameWithInput() async throws {
        let fake = store { $0.output = .text("done", truncated: false) }
        let output = try await run("run_shortcut", ["name": "send report", "input": "hello"], on: fake)
        #expect(fake.read(\.ran)?.name == "Send Report")
        #expect(fake.read(\.ran)?.input == "hello")
        #expect(output.text.contains("Output:\ndone"))
        #expect(output.structured?.objectValue?["output"]?.stringValue == "done")
        #expect(output.structured?.objectValue?["output_kind"]?.stringValue == "text")
    }

    @Test func runWithoutInputPassesNil() async throws {
        let fake = store()
        let output = try await run("run_shortcut", ["name": "Morning Routine"], on: fake)
        #expect(fake.read(\.ran)?.input == nil)
        #expect(output.text.contains("no output"))
    }

    @Test func nonTextOutputIsDescribed() async throws {
        let fake = store { $0.output = .other(type: "image/png", bytes: 2048) }
        let output = try await run("run_shortcut", ["name": "Resize Image"], on: fake)
        #expect(output.text.contains("image/png"))
        #expect(output.text.contains("2048 bytes"))
        #expect(output.structured?.objectValue?["output"] == nil)
        #expect(output.structured?.objectValue?["output_bytes"]?.intValue == 2048)
    }

    @Test func unknownNameIsNotFoundWithCloseNames() async {
        let fake = store()
        let error = await failure("run_shortcut", ["name": "resize"], on: fake)
        #expect(error?.code == .notFound)
        #expect(error?.message.contains("'Resize Image'") == true)
        #expect(error?.message.contains("'resize photo'") == true)
        #expect(error?.message.contains("Morning") == false)
        #expect(!fake.read(\.calls).contains("run"))
    }

    @Test func unknownNameWithNoCloseNamesSaysSo() async {
        let error = await failure("run_shortcut", ["name": "zzz"], on: store())
        #expect(error?.code == .notFound)
        #expect(error?.message.contains("No shortcut has a similar name") == true)
    }

    @Test func nameThatContainsAShortcutNameIsClose() async {
        let error = await failure("run_shortcut", ["name": "Send Report Now"], on: store())
        #expect(error?.message.contains("'Send Report'") == true)
    }

    @Test func caseOnlyDuplicatesAreAmbiguousUnlessExact() async throws {
        let fake = store { $0.shortcuts = ["Go", "go"] }
        let error = await failure("run_shortcut", ["name": "GO"], on: fake)
        #expect(error?.code == .ambiguous)
        _ = try await run("run_shortcut", ["name": "go"], on: fake)
        #expect(fake.read(\.ran)?.name == "go")
    }

    @Test func slowRunGivesTimeout() async {
        let fake = store { $0.runDelay = 5 }
        let error = await failure(
            "run_shortcut", ["name": "Send Report"], on: fake, using: module(fake, runTimeout: 0.1))
        #expect(error?.code == .timeout)
    }
}
