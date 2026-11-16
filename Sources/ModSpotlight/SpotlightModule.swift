import AppleSauceCore
import Foundation
import MCP

/// Spotlight search. The data comes from a `SpotlightStore` (`mdfind` in the real binary).
public struct SpotlightModule: Module {
    public static let moduleName = "spotlight"
    public var name: String { Self.moduleName }
    /// Spotlight needs no permission. Folders that macOS protects are left out of the results.
    public static let requiredPermissions: [Permission] = []
    public var permissions: [Permission] { Self.requiredPermissions }

    let store: any SpotlightStore
    let backendTimeout: Double

    /// The real module, backed by `mdfind`.
    public init() {
        self.init(store: MDFindStore())
    }

    init(store: any SpotlightStore, backendTimeout: Double = 30) {
        self.store = store
        self.backendTimeout = backendTimeout
    }

    // MARK: tools

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    public var tools: [ToolSpec] { Self.toolSpecs }

    public static var toolSpecs: [ToolSpec] {
        [
            ToolSpec(
                name: "search_files",
                description:
                    "Search files and folders with Spotlight. The query is plain words, like in Spotlight. With 'kind', every word must be in the file name or at the start of a word in the content. Returns path, name, kind, size and modified date. Files that no longer exist are skipped.",
                properties: [
                    "query": Self.property("string", "Words to look for."),
                    "folder": Self.property(
                        "string", "Search only inside this folder (an absolute path, or one that starts with ~)."),
                    "kind": [
                        "type": "string", "enum": .array(SpotlightKind.allCases.map { .string($0.rawValue) }),
                        "description":
                            "Only this kind of item. 'document' means Word, Pages, OpenDocument and RTF files. 'text' means plain text, Markdown and code.",
                    ],
                    "limit": Self.property("integer", "Most results to return. Default 25, maximum 200."),
                ],
                required: ["query"])
        ]
    }

    // MARK: routing

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        switch tool {
        case "search_files": return try await searchFiles(args)
        default:
            throw ToolError(.unknownTool, "The spotlight module has no tool named '\(tool)'.")
        }
    }

    // MARK: backend access

    /// One backend call with the 30 second limit.
    private func backend<T: Sendable>(_ operation: @escaping @Sendable (any SpotlightStore) async throws -> T)
        async throws -> T
    {
        let store = store
        return try await withTimeout(seconds: backendTimeout) { try await operation(store) }
    }

    // MARK: output

    private struct FileList: Encodable {
        let files: [FileInfo]
        /// Paths that Spotlight found, before the limit and before the check that each file exists.
        let matched: Int
        let truncated: Bool
    }

    static func describe(_ file: FileInfo) -> String {
        var parts = [file.name, file.kind]
        if let size = file.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let modified = file.modified { parts.append("modified " + ISODate.string(modified)) }
        parts.append(file.path)
        return parts.joined(separator: " | ")
    }

    // MARK: input

    private func folderArgument(_ args: Arguments) throws -> String? {
        guard let text = try args.string("folder")?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard !text.isEmpty else { throw ToolError.invalidInput("'folder' must not be empty.") }
        let path = (text as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw ToolError(
                .invalidInput, "'folder' must be an absolute path, but it is '\(text)'.",
                fix: "Use a full path such as /Users/name/Documents, or one that starts with ~.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ToolError(
                .invalidInput, "The folder '\(path)' does not exist.", fix: "Check the path and try again.")
        }
        guard isDirectory.boolValue else {
            throw ToolError(
                .invalidInput, "'\(path)' is a file, not a folder.", fix: "Give a folder path in 'folder'.")
        }
        return path
    }

    private func kindArgument(_ args: Arguments) throws -> SpotlightKind? {
        guard let text = try args.string("kind") else { return nil }
        guard let kind = SpotlightKind(rawValue: text.lowercased()) else {
            let list = SpotlightKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolError.invalidInput("'kind' must be one of: \(list).")
        }
        return kind
    }

    // MARK: read tools

    private func searchFiles(_ args: Arguments) async throws -> ToolOutput {
        let text = try args.requiredString("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError.invalidInput("'query' is required.") }
        let folder = try folderArgument(args)
        let kind = try kindArgument(args)
        let limit = try args.int("limit", default: 25, range: 1...200)
        let query = SpotlightQuery.build(text: text, kind: kind)

        let (files, matched, truncated) = try await backend { store in
            let hits = try await store.search(query: query, folder: folder)
            let paths = hits.paths
            var files: [FileInfo] = []
            var index = 0
            while index < paths.count && files.count < limit {
                if let info = await store.describe(path: paths[index]) { files.append(info) }
                index += 1
            }
            return (files, paths.count, index < paths.count || hits.truncated)
        }
        var lines = [
            truncated
                ? "Showing the first \(files.count) files. More match. Raise 'limit' (maximum 200), or add 'folder' or 'kind'."
                : "\(files.count) files."
        ]
        lines += files.map { "- " + Self.describe($0) }
        return try ToolOutput(
            text: lines.joined(separator: "\n"), payload: FileList(files: files, matched: matched, truncated: truncated)
        )
    }
}
