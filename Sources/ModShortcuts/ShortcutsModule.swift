import AppleSauceCore
import Foundation
import MCP

/// Shortcuts tools. They run `/usr/bin/shortcuts` through a `ShortcutsStore`.
public struct ShortcutsModule: Module {
    public static let moduleName = "shortcuts"
    public var name: String { Self.moduleName }
    /// The shortcuts tool needs no macOS permission itself. A shortcut may ask for its own.
    public static let requiredPermissions: [Permission] = []
    public var permissions: [Permission] { Self.requiredPermissions }

    let store: any ShortcutsStore
    let backendTimeout: Double
    let runTimeout: Double

    /// The real module, backed by `/usr/bin/shortcuts`.
    public init() {
        self.init(store: ShortcutsCLIStore())
    }

    /// `runTimeout` is a safety limit a little above the store's own 120 second limit.
    init(store: any ShortcutsStore, backendTimeout: Double = 30, runTimeout: Double = 125) {
        self.store = store
        self.backendTimeout = backendTimeout
        self.runTimeout = runTimeout
    }

    // MARK: tools

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    public var tools: [ToolSpec] { Self.toolSpecs }

    public static var toolSpecs: [ToolSpec] {
        [
            ToolSpec(
                name: "list_shortcuts",
                description: "List the names of the shortcuts in the Shortcuts app, all or from one folder.",
                properties: ["folder": Self.property("string", "Folder name. Ignores case. Default: all shortcuts.")]),
            ToolSpec(
                name: "run_shortcut",
                description:
                    "Run a shortcut by name and wait for it (up to 120 seconds). A shortcut can do anything on this Mac, so run only what the user asked for. It can take text as 'input'. Text output is returned. Other output types are only described by type and size.",
                properties: [
                    "name": Self.property("string", "Shortcut name from list_shortcuts. Ignores case."),
                    "input": Self.property("string", "Text to give the shortcut as input."),
                ],
                required: ["name"], destructive: true),
        ]
    }

    // MARK: routing

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        switch tool {
        case "list_shortcuts": return try await listShortcuts(args)
        case "run_shortcut": return try await runShortcut(args)
        default:
            throw ToolError(.unknownTool, "The shortcuts module has no tool named '\(tool)'.")
        }
    }

    // MARK: backend access

    /// One backend call. The limit is `seconds`, or `backendTimeout` when `seconds` is nil.
    private func backend<T: Sendable>(
        seconds: Double? = nil, _ operation: @escaping @Sendable (any ShortcutsStore) async throws -> T
    ) async throws -> T {
        let store = store
        return try await withTimeout(seconds: seconds ?? backendTimeout) { try await operation(store) }
    }

    // MARK: output

    private struct ShortcutList: Encodable {
        let shortcuts: [String]
        let folder: String?
    }
    private struct RunResult: Encodable {
        let name: String
        let outputKind: String
        let output: String?
        let outputType: String?
        let outputBytes: Int?
        let truncated: Bool?
    }

    // MARK: names

    /// Names that contain the query or that the query contains (any case). At most 10, sorted.
    static func closeNames(to query: String, in names: [String]) -> [String] {
        let wanted = query.lowercased()
        return names.filter {
            let name = $0.lowercased()
            return name.contains(wanted) || wanted.contains(name)
        }.sorted { $0.lowercased() < $1.lowercased() }.prefix(10).map { $0 }
    }

    /// The exact name, or the one name that matches without regard to case.
    static func resolve(_ query: String, kind: String, in names: [String]) throws -> String {
        if names.contains(query) { return query }
        let same = names.filter { $0.caseInsensitiveCompare(query) == .orderedSame }
        if same.count == 1, let found = same.first { return found }
        if same.count > 1 {
            throw ToolError(
                .ambiguous,
                "More than one \(kind) is named like '\(query)': \(same.map { "'\($0)'" }.joined(separator: ", ")).",
                fix: "Use the exact name, with the same upper and lower case.")
        }
        let close = closeNames(to: query, in: names)
        let hint =
            close.isEmpty
            ? "No \(kind) has a similar name."
            : "Close names: \(close.map { "'\($0)'" }.joined(separator: ", "))."
        throw ToolError(
            .notFound, "No \(kind) is named '\(query)'. \(hint)",
            fix: kind == "shortcut"
                ? "Use a name from list_shortcuts." : "Leave 'folder' out to list all shortcuts.")
    }

    // MARK: read tools

    private func listShortcuts(_ args: Arguments) async throws -> ToolOutput {
        let folderQuery = try args.string("folder")?.trimmingCharacters(in: .whitespaces)
        if folderQuery?.isEmpty == true { throw ToolError.invalidInput("'folder' must not be empty.") }

        var folder: String?
        if let folderQuery {
            let folders = try await backend { try await $0.folders() }
            folder = try Self.resolve(folderQuery, kind: "folder", in: folders)
        }
        let chosen = folder
        let names = try await backend { try await $0.list(folder: chosen) }.sorted {
            $0.lowercased() < $1.lowercased()
        }
        var lines = ["\(names.count) shortcuts\(folder.map { " in folder '\($0)'" } ?? "")."]
        lines += names.map { "- \($0)" }
        return try ToolOutput(
            text: lines.joined(separator: "\n"), payload: ShortcutList(shortcuts: names, folder: folder))
    }

    // MARK: write tools

    private func runShortcut(_ args: Arguments) async throws -> ToolOutput {
        let query = try args.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError.invalidInput("'name' is required.") }
        let input = try args.string("input")

        let names = try await backend { try await $0.list(folder: nil) }
        let exact = try Self.resolve(query, kind: "shortcut", in: names)
        let output = try await backend(seconds: runTimeout) { try await $0.run(name: exact, input: input) }

        switch output {
        case .none:
            return try ToolOutput(
                text: "Ran shortcut '\(exact)'. It gave no output.",
                payload: RunResult(
                    name: exact, outputKind: "none", output: nil, outputType: nil, outputBytes: nil, truncated: nil))
        case .text(let text, let truncated):
            let note =
                truncated ? "\n(Output cut at \(ShortcutsCLIStore.textLimit) characters.)" : ""
            return try ToolOutput(
                text: "Ran shortcut '\(exact)'. Output:\n\(text)\(note)",
                payload: RunResult(
                    name: exact, outputKind: "text", output: text, outputType: nil, outputBytes: nil,
                    truncated: truncated))
        case .other(let type, let bytes):
            let described = type ?? "unknown type"
            return try ToolOutput(
                text:
                    "Ran shortcut '\(exact)'. It gave output that is not text (\(described), \(bytes) bytes). Only text output can be returned.",
                payload: RunResult(
                    name: exact, outputKind: "other", output: nil, outputType: type, outputBytes: bytes,
                    truncated: nil))
        }
    }
}
