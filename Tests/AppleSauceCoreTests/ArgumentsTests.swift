import AppleSauceCore
import MCP
import Testing

@Suite struct ArgumentsTests {
    let args = Arguments([
        "s": "hi", "n": 5, "d": 7.0, "f": 2.5, "b": true, "list": ["a", "b"], "null": nil, "empty": "",
    ])

    @Test func typedGetters() throws {
        #expect(try args.string("s") == "hi")
        #expect(try args.int("n") == 5)
        #expect(try args.int("d") == 7)
        #expect(try args.bool("b") == true)
        #expect(try args.stringArray("list") == ["a", "b"])
        #expect(try args.string("missing") == nil)
        #expect(try args.string("null") == nil)
    }

    @Test func wrongTypesThrowInvalidInput() {
        #expect(throws: ToolError.invalidInput("'n' must be a string.")) { try args.string("n") }
        #expect(throws: ToolError.self) { try args.int("f") }
        #expect(throws: ToolError.self) { try args.bool("s") }
        #expect(throws: ToolError.self) { try args.stringArray("s") }
    }

    @Test func requiredAndRange() throws {
        #expect(throws: ToolError.invalidInput("'missing' is required.")) { try args.requiredString("missing") }
        #expect(throws: ToolError.self) { try args.requiredString("empty") }
        #expect(try args.int("missing", default: 20, range: 1...100) == 20)
        #expect(throws: ToolError.self) { try args.int("n", default: 1, range: 10...20) }
    }
}
