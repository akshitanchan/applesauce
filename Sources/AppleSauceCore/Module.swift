import MCP

/// One tool and whether it changes data.
/// Write tools are hidden in read-only mode.
public struct ToolSpec: Sendable {
    public let tool: Tool
    public var isWrite: Bool { tool.annotations.readOnlyHint != true }

    /// - Parameters:
    ///   - write: false for tools that only read. Read tools get `readOnlyHint: true`.
    ///   - destructive: true for tools that delete or send. Implies `write`.
    public init(
        name: String,
        description: String,
        properties: [String: Value] = [:],
        required: [String] = [],
        write: Bool = false,
        destructive: Bool = false,
        idempotent: Bool? = nil
    ) {
        let isWrite = write || destructive
        self.tool = Tool(
            name: name,
            description: description,
            inputSchema: .object([
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": false,
            ]),
            annotations: .init(
                readOnlyHint: !isWrite,
                destructiveHint: isWrite ? destructive : nil,
                idempotentHint: idempotent,
                openWorldHint: false
            )
        )
    }
}

/// What a tool returns: text for the model, plus optional structured data.
public struct ToolOutput: Sendable {
    public let text: String
    public let structured: Value?

    public init(text: String, structured: Value? = nil) {
        self.text = text
        self.structured = structured
    }
}

/// One Apple app area (Calendar, Mail, ...).
/// A module talks to its app through a small store protocol, so tests use a fake store.
public protocol Module: Sendable {
    /// Short lowercase name, used in `--modules` and `--disable`.
    var name: String { get }
    var tools: [ToolSpec] { get }
    var permissions: [Permission] { get }
    func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput
}
