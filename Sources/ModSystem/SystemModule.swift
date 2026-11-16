import AppleSauceCore
import Foundation
import MCP
import UniformTypeIdentifiers

/// System tools: clipboard, notifications and opening things. The work goes through a `SystemStore`.
public struct SystemModule: Module {
    public let name = "system"
    /// System tools need no permission.
    /// The notification script talks to no other app, so it needs no Automation permission.
    public let permissions: [Permission] = []

    let store: any SystemStore
    let backendTimeout: Double

    /// The real module.
    public init() {
        self.init(store: AppKitSystemStore())
    }

    init(store: any SystemStore, backendTimeout: Double = 30) {
        self.store = store
        self.backendTimeout = backendTimeout
    }

    /// Longest clipboard text that a tool returns, in characters.
    static let clipboardLimit = 100_000

    // MARK: tools

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    public var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "get_clipboard",
                description:
                    "Read the text on the clipboard. Only text is returned. If the clipboard holds something else, for example an image, the answer says so."
            ),
            ToolSpec(
                name: "set_clipboard",
                description: "Replace the clipboard with this text.",
                properties: ["text": Self.property("string", "The text to put on the clipboard.")],
                required: ["text"], write: true, idempotent: true),
            ToolSpec(
                name: "notify",
                description: "Show a macOS notification.",
                properties: [
                    "title": Self.property("string", "Notification title."),
                    "message": Self.property("string", "Notification text."),
                    "subtitle": Self.property("string", "Optional line under the title."),
                ],
                required: ["title", "message"], write: true),
            ToolSpec(
                name: "open",
                description:
                    "Open a web page, an email draft or a file in its default app. Give exactly one of 'url' (http, https or mailto) or 'path' (a file or folder that exists). Apps, executables, installers, scripts and bundles are refused.",
                properties: [
                    "url": Self.property("string", "A URL that starts with http://, https:// or mailto:."),
                    "path": Self.property("string", "Absolute path of a file or folder. A path with ~ also works."),
                ],
                destructive: true),
        ]
    }

    // MARK: routing

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        switch tool {
        case "get_clipboard": return try await getClipboard()
        case "set_clipboard": return try await setClipboard(args)
        case "notify": return try await notify(args)
        case "open": return try await open(args)
        default:
            throw ToolError(.unknownTool, "The system module has no tool named '\(tool)'.")
        }
    }

    // MARK: backend access

    /// One backend call with the 30 second limit.
    private func backend<T: Sendable>(_ operation: @escaping @Sendable (any SystemStore) async throws -> T)
        async throws -> T
    {
        let store = store
        return try await withTimeout(seconds: backendTimeout) { try await operation(store) }
    }

    // MARK: output

    private struct Clipboard: Encodable {
        let hasText: Bool
        let text: String?
        let truncated: Bool?
        let types: [String]?
    }
    private struct Done: Encodable {
        let done: String
        let target: String?
    }

    // MARK: input

    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Checks the 'url' argument. Only http, https and mailto pass.
    static func checkedURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw ToolError(
                .invalidInput, "'url' is not a valid URL: '\(text)'.",
                fix: "Use a full URL, for example https://example.com.")
        }
        guard allowedSchemes.contains(scheme) else {
            throw ToolError(
                .invalidInput,
                scheme == "file"
                    ? "'url' cannot be a file: URL." : "'url' must start with http, https or mailto, not '\(scheme)'.",
                fix: scheme == "file" ? "Use 'path' to open a file." : "Use an http, https or mailto URL.")
        }
        if scheme != "mailto" && (url.host ?? "").isEmpty {
            throw ToolError(
                .invalidInput, "'url' has no host: '\(text)'.", fix: "Use a full URL, for example https://example.com.")
        }
        return url
    }

    /// File extensions that `open` refuses, whatever the content type says.
    static let blockedExtensions: Set<String> = [
        "app", "command", "tool", "sh", "zsh", "bash", "csh", "py", "rb", "pl", "workflow", "action", "pkg", "mpkg",
        "dmg", "scpt", "scptd", "applescript", "terminal", "jar", "webloc", "inetloc", "fileloc",
    ]

    /// Content types that `open` refuses.
    /// `UTType` has no constant for installer packages, so that one comes from its identifier.
    static let blockedTypes: [UTType] =
        [.application, .executable, .applicationBundle, .unixExecutable, .shellScript, .script]
        + [UTType("com.apple.installer-package-archive")].compactMap { $0 }

    /// True when the item is an app, an executable, an installer, a script or a bundle.
    static func isRunnable(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        for candidate in [url, resolved] {
            if blockedExtensions.contains(candidate.pathExtension.lowercased()) { return true }
        }
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isPackageKey, .isApplicationKey]
        guard let values = try? resolved.resourceValues(forKeys: keys) else { return false }
        if values.isPackage == true || values.isApplication == true { return true }
        guard let type = values.contentType else { return false }
        return blockedTypes.contains { type.conforms(to: $0) } || type.conforms(to: .bundle)
    }

    /// Checks the 'path' argument. The item must exist and must not be runnable.
    static func checkedPath(_ text: String) throws -> URL {
        let path = (text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw ToolError(
                .invalidInput, "'path' must be an absolute path, but it is '\(text)'.",
                fix: "Use a full path such as /Users/name/Documents/file.pdf, or one that starts with ~.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError(
                .notFound, "There is no file or folder at '\(path)'.", fix: "Check the path and try again.")
        }
        let url = URL(fileURLWithPath: path)
        guard !isRunnable(url) else {
            throw ToolError(
                .invalidInput, "'path' is an app, an executable, an installer, a script or a bundle: '\(path)'.",
                fix: "Use 'open' only for documents, images, folders and similar files.")
        }
        return url
    }

    // MARK: read tools

    private func getClipboard() async throws -> ToolOutput {
        let content = try await backend { await $0.clipboard() }
        guard let text = content.text, !text.isEmpty else {
            let held = content.types.isEmpty ? "it is empty" : "it holds: \(content.types.joined(separator: ", "))"
            return try ToolOutput(
                text: "The clipboard holds no text (\(held)).",
                payload: Clipboard(hasText: false, text: nil, truncated: nil, types: content.types))
        }
        let truncated = text.count > Self.clipboardLimit
        let shown = truncated ? String(text.prefix(Self.clipboardLimit)) : text
        let note = truncated ? "\n(Text cut at \(Self.clipboardLimit) of \(text.count) characters.)" : ""
        return try ToolOutput(
            text: shown + note, payload: Clipboard(hasText: true, text: shown, truncated: truncated, types: nil))
    }

    // MARK: write tools

    private func setClipboard(_ args: Arguments) async throws -> ToolOutput {
        let text = try args.requiredString("text")
        try await backend { try await $0.setClipboard(text) }
        return try ToolOutput(
            text: "Put \(text.count) characters on the clipboard.", payload: Done(done: "set_clipboard", target: nil))
    }

    private func notify(_ args: Arguments) async throws -> ToolOutput {
        let title = try args.requiredString("title")
        let message = try args.requiredString("message")
        let subtitle = try args.string("subtitle").flatMap { $0.isEmpty ? nil : $0 }
        try await backend { try await $0.notify(title: title, message: message, subtitle: subtitle) }
        return try ToolOutput(text: "Showed the notification '\(title)'.", payload: Done(done: "notify", target: nil))
    }

    private func open(_ args: Arguments) async throws -> ToolOutput {
        let urlText = try args.string("url").flatMap { $0.isEmpty ? nil : $0 }
        let pathText = try args.string("path").flatMap { $0.isEmpty ? nil : $0 }
        let target: URL
        switch (urlText, pathText) {
        case (let url?, nil): target = try Self.checkedURL(url)
        case (nil, let path?): target = try Self.checkedPath(path)
        default:
            throw ToolError.invalidInput("Give exactly one of 'url' or 'path'.")
        }
        try await backend { try await $0.open(target) }
        let shown = target.isFileURL ? target.path : target.absoluteString
        return try ToolOutput(text: "Opened \(shown).", payload: Done(done: "open", target: shown))
    }
}
