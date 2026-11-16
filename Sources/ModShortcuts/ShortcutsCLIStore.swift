import AppleSauceCore
import Foundation

/// The real shortcuts store. It runs `/usr/bin/shortcuts` with an argv array.
struct ShortcutsCLIStore: ShortcutsStore {
    let executable: String
    let runTimeout: Double
    let listTimeout: Double

    init(executable: String = "/usr/bin/shortcuts", runTimeout: Double = 120, listTimeout: Double = 30) {
        self.executable = executable
        self.runTimeout = runTimeout
        self.listTimeout = listTimeout
    }

    /// Longest text that a tool returns, in characters.
    static let textLimit = 100_000

    func folders() async throws -> [String] {
        try await lines(["list", "--folders"])
    }

    func list(folder: String?) async throws -> [String] {
        try await lines(folder.map { ["list", "--folder-name", $0] } ?? ["list"])
    }

    private func lines(_ arguments: [String]) async throws -> [String] {
        let result = try await runProcess(executable: executable, arguments: arguments, timeout: listTimeout)
        guard result.status == 0 else { throw Self.failure(result) }
        return Self.parseLines(result.stdoutText)
    }

    static func parseLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func run(name: String, input: String?) async throws -> ShortcutOutput {
        // A private folder holds the input and output files. It is removed on every exit.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "applesauce-shortcut-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw ToolError(
                .internalError, "Could not make a temporary folder: \(error.localizedDescription)",
                fix: "Check free disk space and the temporary folder.")
        }
        defer { try? FileManager.default.removeItem(at: folder) }

        let outputPath = folder.appendingPathComponent("output").path
        var arguments = ["run", name, "--output-path", outputPath]
        if let input {
            let inputURL = folder.appendingPathComponent("input.txt")
            do {
                try Data(input.utf8).write(to: inputURL)
            } catch {
                throw ToolError(
                    .internalError, "Could not write the input file: \(error.localizedDescription)",
                    fix: "Check free disk space and the temporary folder.")
            }
            arguments += ["--input-path", inputURL.path]
        }

        let result: ProcessResult
        do {
            result = try await runProcess(executable: executable, arguments: arguments, timeout: runTimeout)
        } catch let error as ToolError where error.code == .timeout {
            throw ToolError(
                .timeout, "The shortcut '\(name)' ran longer than \(Int(runTimeout)) seconds and was stopped.",
                fix:
                    "Check that the shortcut does not wait for input or a dialog. Run it by hand in the Shortcuts app.")
        }
        guard result.status == 0 else { throw Self.failure(result) }

        // The shortcuts tool may add a file extension to the output name, so look at the whole folder.
        let files =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0 != "input.txt" }.sorted() ?? []
        guard let file = files.first else { return .none }
        let url = folder.appendingPathComponent(file)
        // A big file is not read. Only its size is reported.
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > Self.outputFileLimit {
            return .other(type: nil, bytes: size)
        }
        guard let data = FileManager.default.contents(atPath: url.path) else { return .none }
        return Self.classify(data)
    }

    /// Largest output file that is read, in bytes (10 MB).
    static let outputFileLimit = 10 * 1024 * 1024

    /// Text comes back whole (cut at `textLimit`). Anything else is described by type and size.
    static func classify(_ data: Data) -> ShortcutOutput {
        if data.isEmpty { return .none }
        if !data.contains(0), let text = String(data: data, encoding: .utf8) {
            if text.count > textLimit { return .text(String(text.prefix(textLimit)), truncated: true) }
            return .text(text, truncated: false)
        }
        return .other(type: sniffType(data), bytes: data.count)
    }

    /// A guess from the first bytes.
    static func sniffType(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(Array("GIF8".utf8)) { return "image/gif" }
        if starts(Array("%PDF".utf8)) { return "application/pdf" }
        if starts(Array("PK".utf8) + [3, 4]) { return "application/zip" }
        if starts(Array("bplist00".utf8)) { return "application/x-plist" }
        if starts(Array("ftyp".utf8), at: 4) { return "video/quicktime or video/mp4" }
        if starts(Array("RIFF".utf8)) { return "audio/wav or image/webp" }
        return nil
    }

    private static func failure(_ result: ProcessResult) -> ToolError {
        let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolError(
            .internalError,
            message.isEmpty ? "The shortcuts tool failed (exit \(result.status))." : "Shortcuts: \(message)",
            fix: "Run the shortcut by hand in the Shortcuts app to see the problem.")
    }
}
