import MCP

/// Holds the enabled modules, lists their tools, and routes tool calls.
/// It turns every failure into the `{code, message, fix}` error shape.
public struct Registry: Sendable {
    public let config: Config
    public let modules: [any Module]
    private let routes: [String: Route]
    /// Write tools hidden by `--read-only`, so a call gets a clear error instead of "unknown tool".
    private let hiddenWrites: Set<String>
    /// Hard limit for one call. Modules set tighter limits on their backend calls.
    private let callLimit: Double

    private struct Route: Sendable {
        let module: any Module
        let spec: ToolSpec
    }

    /// - Parameters:
    ///   - available: feature modules. `--modules` and `--disable` choose among them.
    ///   - alwaysOn: modules that flags cannot turn off (for example `doctor`). They come first.
    public init(available: [any Module], alwaysOn: [any Module] = [], config: Config, callLimit: Double = 150) throws {
        let known = Set(available.map(\.name))
        let asked = (config.modules ?? []).union(config.disabled)
        if let unknown = asked.subtracting(known).sorted().first {
            let list = known.sorted().joined(separator: ", ")
            throw Config.ParseError(
                description: "Unknown module '\(unknown)'. Known modules: \(list.isEmpty ? "none" : list).")
        }

        var routes: [String: Route] = [:]
        var hidden: Set<String> = []
        let enabled = alwaysOn + available.filter { config.isEnabled($0.name) }
        for module in enabled {
            for spec in module.tools {
                precondition(
                    routes[spec.tool.name] == nil && !hidden.contains(spec.tool.name),
                    "duplicate tool name \(spec.tool.name)")
                if config.readOnly && spec.isWrite {
                    hidden.insert(spec.tool.name)
                } else {
                    routes[spec.tool.name] = Route(module: module, spec: spec)
                }
            }
        }
        self.config = config
        self.modules = enabled
        self.routes = routes
        self.hiddenWrites = hidden
        self.callLimit = callLimit
    }

    /// Tools in a stable order: module order, then the module's own order.
    public var tools: [Tool] {
        modules.flatMap { module in
            module.tools.map(\.tool).filter { routes[$0.name] != nil }
        }
    }

    public func call(_ name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let route = routes[name] else {
            let error =
                hiddenWrites.contains(name)
                ? ToolError(
                    .readOnly, "'\(name)' changes data, and applesauce runs in read-only mode.",
                    fix: "Remove --read-only (or APPLESAUCE_READ_ONLY) to allow changes.")
                : ToolError(
                    .unknownTool, "There is no tool named '\(name)'.",
                    fix: "List the tools again. The module may be turned off.")
            return Self.failure(error)
        }
        let args = Arguments(arguments)
        do {
            let output = try await withTimeout(seconds: callLimit) {
                try await route.module.call(name, args)
            }
            let images = output.images.map {
                Tool.Content.image(data: $0.data, mimeType: $0.mimeType, annotations: nil, _meta: nil)
            }
            return CallTool.Result(
                content: [.text(text: output.text, annotations: nil, _meta: nil)] + images,
                structuredContent: output.structured)
        } catch let error as ToolError {
            return Self.failure(error)
        } catch {
            return Self.failure(
                ToolError(
                    .internalError, String(describing: error),
                    fix: "Call the 'doctor' tool. If the error stays, report it."))
        }
    }

    static func failure(_ error: ToolError) -> CallTool.Result {
        CallTool.Result(content: [.text(text: error.json, annotations: nil, _meta: nil)], isError: true)
    }
}
