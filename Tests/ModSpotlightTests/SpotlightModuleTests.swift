import AppleSauceCore
import Foundation
import MCP
import Testing

@testable import ModSpotlight

@Suite struct SpotlightModuleTests {
    func store(_ edit: (inout FakeSpotlightStore.State) -> Void = { _ in }) -> FakeSpotlightStore {
        var state = FakeSpotlightStore.State()
        state.paths = ["/x/a.pdf", "/x/gone.pdf", "/x/b.pdf", "/x/c.pdf"]
        state.files = [
            "/x/a.pdf": fileInfo("/x/a.pdf"), "/x/b.pdf": fileInfo("/x/b.pdf"),
            "/x/c.pdf": fileInfo("/x/c.pdf"),
        ]
        edit(&state)
        return FakeSpotlightStore(state)
    }

    func module(_ store: FakeSpotlightStore, backendTimeout: Double = 30) -> SpotlightModule {
        SpotlightModule(store: store, backendTimeout: backendTimeout)
    }

    func run(_ args: [String: Value], on store: FakeSpotlightStore) async throws -> ToolOutput {
        try await module(store).call("search_files", Arguments(args))
    }

    func failure(_ args: [String: Value], on store: FakeSpotlightStore, using module: SpotlightModule? = nil) async
        -> ToolError?
    {
        do {
            _ = try await (module ?? self.module(store)).call("search_files", Arguments(args))
            return nil
        } catch {
            return error as? ToolError
        }
    }

    func paths(_ output: ToolOutput) -> [String] {
        output.structured?.objectValue?["files"]?.arrayValue?.compactMap { $0.objectValue?["path"]?.stringValue }
            ?? []
    }

    /// Makes a folder in the temporary directory and removes it at the end.
    func withTempFolder(_ body: (String) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spotlight-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url.path)
    }

    // MARK: tools

    @Test func toolNamesAndFlags() {
        let tools = module(store()).tools
        #expect(tools.map(\.tool.name) == ["search_files"])
        #expect(tools.allSatisfy { !$0.isWrite })
    }

    // MARK: input checks

    @Test func badInputNeverReachesTheStore() async throws {
        let fake = store()
        try await withTempFolder { folder in
            let file = folder + "/file.txt"
            FileManager.default.createFile(atPath: file, contents: Data())
            let bad: [[String: Value]] = [
                [:],
                ["query": ""],
                ["query": "  "],
                ["query": 4],
                ["query": "a", "limit": 0],
                ["query": "a", "limit": 201],
                ["query": "a", "kind": "zip"],
                ["query": "a", "folder": ""],
                ["query": "a", "folder": "relative/path"],
                ["query": "a", "folder": .string(folder + "/missing")],
                ["query": "a", "folder": .string(file)],
            ]
            for args in bad {
                let error = await failure(args, on: fake)
                #expect(error?.code == .invalidInput, "\(args)")
            }
        }
        #expect(fake.read(\.calls).isEmpty)
    }

    // MARK: search

    @Test func existingFolderIsPassedToTheStore() async throws {
        let fake = store()
        try await withTempFolder { folder in
            _ = try await run(["query": "a", "folder": .string(folder)], on: fake)
            #expect(fake.read(\.lastFolder) == folder)
        }
    }

    @Test func queryAndKindReachTheStoreAsOneString() async throws {
        let fake = store()
        _ = try await run(["query": "plan"], on: fake)
        #expect(fake.read(\.lastQuery) == "plan")
        _ = try await run(["query": #"a "b""#, "kind": "PDF"], on: fake)
        #expect(fake.read(\.lastQuery)?.contains(#"\"b\""#) == true)
        #expect(fake.read(\.lastQuery)?.contains("com.adobe.pdf") == true)
    }

    @Test func skipsMissingFilesAndReturnsDetails() async throws {
        let output = try await run(["query": "a"], on: store())
        #expect(paths(output) == ["/x/a.pdf", "/x/b.pdf", "/x/c.pdf"])
        let first = try #require(output.structured?.objectValue?["files"]?.arrayValue?.first?.objectValue)
        #expect(first["name"]?.stringValue == "a.pdf")
        #expect(first["kind"]?.stringValue == "PDF document")
        #expect(first["size"]?.intValue == 1024)
        #expect(first["modified"]?.stringValue?.hasPrefix("2023-11-1") == true)
        #expect(output.structured?.objectValue?["matched"]?.intValue == 4)
        #expect(output.structured?.objectValue?["truncated"]?.boolValue == false)
    }

    @Test func limitStopsEarlyAndSaysTruncated() async throws {
        let fake = store()
        let output = try await run(["query": "a", "limit": 2], on: fake)
        #expect(paths(output) == ["/x/a.pdf", "/x/b.pdf"])
        #expect(output.structured?.objectValue?["truncated"]?.boolValue == true)
        #expect(output.text.contains("Showing the first 2"))
        // It did not look at the paths after the limit.
        #expect(fake.read(\.calls).filter { $0 == "describe" }.count == 3)
    }

    @Test func aCutSearchIsReportedAsTruncated() async throws {
        let output = try await run(["query": "a", "limit": 10], on: store { $0.searchTruncated = true })
        #expect(paths(output).count == 3)
        #expect(output.structured?.objectValue?["truncated"]?.boolValue == true)
        #expect(output.text.contains("More match"))
    }

    @Test func limitThatFitsIsNotTruncated() async throws {
        let output = try await run(["query": "a", "limit": 3], on: store())
        #expect(paths(output).count == 3)
        #expect(output.structured?.objectValue?["truncated"]?.boolValue == false)
    }

    @Test func noMatchesIsAnEmptyList() async throws {
        let output = try await run(["query": "a"], on: store { $0.paths = [] })
        #expect(output.text == "0 files.")
    }

    @Test func foldersHaveNoSize() async throws {
        let fake = store {
            $0.paths = ["/x/dir"]
            $0.files = ["/x/dir": fileInfo("/x/dir", kind: "Folder", size: nil)]
        }
        let output = try await run(["query": "dir"], on: fake)
        let first = try #require(output.structured?.objectValue?["files"]?.arrayValue?.first?.objectValue)
        #expect(first["size"] == nil)
    }

    @Test func slowBackendGivesTimeout() async {
        let fake = store { $0.searchDelay = 5 }
        let error = await failure(["query": "a"], on: fake, using: module(fake, backendTimeout: 0.1))
        #expect(error?.code == .timeout)
    }
}
