import AppleSauceCore
import Foundation

/// The real spotlight store. It runs `/usr/bin/mdfind` with an argv array and reads file details.
struct MDFindStore: SpotlightStore {
    let executable: String
    let timeout: Double
    /// Most bytes of mdfind output that are read. Then mdfind is stopped and the result is marked as cut.
    let outputLimit: Int

    init(executable: String = "/usr/bin/mdfind", timeout: Double = 30, outputLimit: Int = processOutputLimit) {
        self.executable = executable
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    /// `-0` separates paths with a NUL byte, so a path with a line break is safe.
    /// The query is the last argument and one argv element.
    static func arguments(query: String, folder: String?) -> [String] {
        var arguments = ["-0"]
        if let folder { arguments += ["-onlyin", folder] }
        arguments.append(query)
        return arguments
    }

    func search(query: String, folder: String?) async throws -> SearchHits {
        let result = try await runProcess(
            executable: executable, arguments: Self.arguments(query: query, folder: folder), timeout: timeout,
            outputLimit: outputLimit, stopAtOutputLimit: true)
        // A program that was stopped at the limit has no useful exit status.
        guard result.status == 0 || result.truncated else {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("Failed to create query") {
                throw ToolError(
                    .invalidInput, "Spotlight could not read the query. \(message)",
                    fix: "Use plain words, or give 'kind' to search by file name and content.")
            }
            throw ToolError(
                .internalError, message.isEmpty ? "mdfind failed (exit \(result.status))." : "mdfind: \(message)",
                fix: "Check that Spotlight is on (System Settings > Siri & Spotlight). If this stays, report it.")
        }
        var pieces = result.stdout.split(separator: 0, omittingEmptySubsequences: false)
        // The text after the last NUL byte has no end. When the output was cut, it may be a part of a path.
        if result.truncated, result.stdout.last != 0 { pieces.removeLast() }
        let paths = pieces.map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
        return SearchHits(paths: paths, truncated: result.truncated)
    }

    func describe(path: String) async -> FileInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey,
        ]
        // The values call throws when the file is gone, so a stale index entry is skipped.
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDirectory = values.isDirectory ?? false
        let ext = url.pathExtension
        let kind = values.localizedTypeDescription ?? (ext.isEmpty ? "File" : ext.uppercased() + " file")
        return FileInfo(
            path: path, name: url.lastPathComponent, kind: kind, size: isDirectory ? nil : values.fileSize,
            modified: values.contentModificationDate)
    }
}
