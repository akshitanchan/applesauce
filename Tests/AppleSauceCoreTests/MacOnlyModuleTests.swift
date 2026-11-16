import AppleSauceCore
import MCP
import Testing

@Suite struct MacOnlyModuleTests {
    let module = MacOnlyModule(
        name: "fake", tools: FakeModule().tools, permissions: [.calendars])

    @Test func listsTheRealToolsAndPermissions() {
        #expect(module.name == "fake")
        #expect(module.tools.map(\.tool.name) == FakeModule().tools.map(\.tool.name))
        #expect(module.permissions == [.calendars])
    }

    @Test func everyCallIsUnsupported() async throws {
        let registry = try Registry(available: [module], config: Config())
        for name in ["fake_read", "fake_write", "fake_delete"] {
            let result = await registry.call(name, arguments: ["q": "x"])
            #expect(errorCode(result) == "UNSUPPORTED_PLATFORM", "\(name)")
        }
    }

    @Test func readOnlyStillHidesWriteTools() throws {
        let registry = try Registry(
            available: [module], config: Config.parse(arguments: ["--read-only"], environment: [:]))
        #expect(registry.tools.map(\.name).contains("fake_write") == false)
    }

    @Test func doctorReportsUnsupportedPermissions() {
        let fix = Permission.calendars.fix(for: .unsupported)
        #expect(fix == "applesauce runs only on macOS.")
        #expect(ToolError.macOSOnly.code == .unsupportedPlatform)
    }
}
