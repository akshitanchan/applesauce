import AppleSauceCore
import Foundation
import MCP

/// A module with one read tool, one write tool and one failing tool.
struct FakeModule: Module {
    var name = "fake"
    var permissions: [Permission] = []

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "fake_read", description: "read",
                properties: ["q": ["type": "string"]], required: ["q"]),
            ToolSpec(name: "fake_write", description: "write", write: true),
            ToolSpec(name: "fake_delete", description: "delete", destructive: true),
            ToolSpec(name: "fake_crash", description: "throws a non-tool error"),
        ]
    }

    struct Boom: Error {}

    func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        switch tool {
        case "fake_read": ToolOutput(text: "read \(try args.requiredString("q"))")
        case "fake_crash": throw Boom()
        default: ToolOutput(text: tool)
        }
    }
}

struct OtherModule: Module {
    let name = "other"
    let permissions: [Permission] = []
    var tools: [ToolSpec] { [ToolSpec(name: "other_read", description: "read")] }
    func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput { ToolOutput(text: "other") }
}

struct FakeChecker: PermissionChecker {
    var states: [Permission: PermissionState] = [:]
    func state(of permission: Permission) -> PermissionState { states[permission] ?? .granted }
}

func text(_ result: CallTool.Result) -> String {
    guard case .text(let text, _, _)? = result.content.first else { return "" }
    return text
}

func errorCode(_ result: CallTool.Result) -> String? {
    guard result.isError == true,
        let data = text(result).data(using: .utf8),
        let error = try? JSONDecoder().decode(ToolError.self, from: data)
    else { return nil }
    return error.code.rawValue
}
