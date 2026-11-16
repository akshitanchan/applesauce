/// A module for systems other than macOS. It lists the real module's tools, and every call fails with
/// `UNSUPPORTED_PLATFORM`. MCP clients and directories can see what applesauce offers, and nothing pretends to work.
public struct MacOnlyModule: Module {
    public let name: String
    public let tools: [ToolSpec]
    public let permissions: [Permission]

    public init(name: String, tools: [ToolSpec], permissions: [Permission]) {
        self.name = name
        self.tools = tools
        self.permissions = permissions
    }

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        throw ToolError.macOSOnly
    }
}
