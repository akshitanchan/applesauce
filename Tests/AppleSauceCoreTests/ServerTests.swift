import AppleSauceCore
import MCP
import Testing

/// End to end over an in-memory transport: handshake, tools/list, tools/call.
@Suite struct ServerTests {
    @Test func handshakeListAndCall() async throws {
        let registry = try Registry(
            available: [FakeModule()],
            alwaysOn: [DoctorModule(modules: ["fake"], readOnly: false, checker: FakeChecker())],
            config: Config())
        let server = await ServerFactory.make(registry: registry)
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverSide)

        let client = Client(name: "test", version: "1")
        let initResult = try await client.connect(transport: clientSide)
        #expect(initResult.serverInfo.name == "applesauce")

        let tools = try await client.listTools().tools.map(\.name)
        #expect(tools.first == "doctor")
        #expect(tools.contains("fake_write"))

        let (content, isError) = try await client.callTool(name: "fake_read", arguments: ["q": "hello"])
        #expect(isError != true)
        guard case .text(let text, _, _)? = content.first else {
            Issue.record("no text")
            return
        }
        #expect(text == "read hello")

        let failed = try await client.callTool(name: "fake_read", arguments: [:])
        #expect(failed.isError == true)

        await client.disconnect()
        await server.stop()
    }
}
