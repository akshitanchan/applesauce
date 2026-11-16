import AppleSauceCore
import MCP
import Testing

@Suite struct RegistryTests {
    func registry(_ arguments: [String] = []) throws -> Registry {
        let config = try Config.parse(arguments: arguments, environment: [:])
        return try Registry(
            available: [FakeModule(), OtherModule()],
            alwaysOn: [DoctorModule(modules: [], readOnly: false, checker: FakeChecker())],
            config: config)
    }

    @Test func listsAllToolsInOrderWithDoctorFirst() throws {
        let names = try registry().tools.map(\.name)
        #expect(names == ["doctor", "fake_read", "fake_write", "fake_delete", "fake_crash", "other_read"])
    }

    @Test func annotationsFollowWriteAndDestructive() throws {
        let tools = Dictionary(uniqueKeysWithValues: try registry().tools.map { ($0.name, $0.annotations) })
        #expect(tools["fake_read"]?.readOnlyHint == true)
        #expect(tools["fake_write"]?.readOnlyHint == false)
        #expect(tools["fake_write"]?.destructiveHint == false)
        #expect(tools["fake_delete"]?.destructiveHint == true)
    }

    @Test func readOnlyHidesWriteToolsAndExplainsCalls() async throws {
        let registry = try registry(["--read-only"])
        #expect(registry.tools.map(\.name) == ["doctor", "fake_read", "fake_crash", "other_read"])
        #expect(errorCode(await registry.call("fake_delete", arguments: nil)) == "READ_ONLY")
    }

    @Test func modulesAndDisableFilterButKeepDoctor() throws {
        #expect(try registry(["--modules", "other"]).tools.map(\.name) == ["doctor", "other_read"])
        #expect(try registry(["--disable", "fake"]).tools.map(\.name) == ["doctor", "other_read"])
    }

    @Test func unknownModuleNameThrows() {
        #expect(throws: Config.ParseError.self) { try registry(["--modules", "nope"]) }
    }

    @Test func callRoutesAndMapsErrors() async throws {
        let registry = try registry()
        let ok = await registry.call("fake_read", arguments: ["q": "x"])
        #expect(ok.isError == nil)
        #expect(text(ok) == "read x")
        #expect(errorCode(await registry.call("fake_read", arguments: [:])) == "INVALID_INPUT")
        #expect(errorCode(await registry.call("fake_crash", arguments: nil)) == "INTERNAL_ERROR")
        #expect(errorCode(await registry.call("missing", arguments: nil)) == "UNKNOWN_TOOL")
    }

    @Test func callLimitReturnsTimeout() async throws {
        struct Slow: Module {
            let name = "slow"
            let permissions: [Permission] = []
            var tools: [ToolSpec] { [ToolSpec(name: "slow", description: "slow")] }
            func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return ToolOutput(text: "late")
            }
        }
        let registry = try Registry(available: [Slow()], config: Config(), callLimit: 0.1)
        #expect(errorCode(await registry.call("slow", arguments: nil)) == "TIMEOUT")
    }
}
