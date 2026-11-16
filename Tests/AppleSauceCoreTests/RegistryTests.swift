import AppleSauceCore
import Foundation
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

    struct Pictures: Module {
        let name = "pictures"
        let permissions: [Permission] = []
        var tools: [ToolSpec] { [ToolSpec(name: "picture", description: "returns an image")] }
        func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
            ToolOutput(text: "here", images: [ToolImage(data: "aGVsbG8=", mimeType: "image/png")])
        }
    }

    @Test func imagesBecomeImageContentBlocksAfterTheText() async throws {
        let registry = try Registry(available: [Pictures()], config: Config())
        let result = await registry.call("picture", arguments: nil)
        #expect(result.isError == nil && result.content.count == 2)
        guard case .text(let text, _, _) = result.content[0] else {
            Issue.record("no text first")
            return
        }
        #expect(text == "here")
        guard case .image(let data, let mimeType, _, _) = result.content[1] else {
            Issue.record("no image block")
            return
        }
        #expect(data == "aGVsbG8=" && mimeType == "image/png")
        // The wire form has the keys that MCP clients read.
        let json = try String(decoding: JSONEncoder().encode(result.content[1]), as: UTF8.self)
        #expect(json.contains("\"type\":\"image\"") && json.contains("\"mimeType\":\"image\\/png\""))
        #expect(json.contains("\"data\":\"aGVsbG8=\""))
    }

    @Test func outputsWithoutImagesStayOneTextBlock() async throws {
        let ok = try await registry().call("fake_read", arguments: ["q": "x"])
        #expect(ok.content.count == 1)
    }
}
