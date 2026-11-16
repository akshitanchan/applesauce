import MCP

public enum ServerFactory {
    /// An MCP server that serves the registry's tools.
    public static func make(registry: Registry) async -> Server {
        let server = Server(
            name: AppleSauce.name,
            version: AppleSauce.version,
            instructions:
                "applesauce works with the Apple apps on this Mac. If a tool fails with a permission error, call doctor and show the user its fix step.",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: registry.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await registry.call(params.name, arguments: params.arguments)
        }
        return server
    }
}
