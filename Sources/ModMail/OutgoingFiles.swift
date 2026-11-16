import AppleSauceCore
import Foundation

/// A file that a mail will carry. `path` is the real path (symlinks resolved).
struct OutgoingFile: Sendable, Equatable {
    let path: String
    let name: String
    let size: Int
}

/// The checks for files that a tool attaches to a mail. All checks run before Mail is touched.
///
/// A file must exist, be a regular file (not a folder, not an app bundle, not a link to a folder), be readable,
/// and be at most `limit` bytes. At most `maxCount` files and `limit` bytes in all. The real path decides,
/// so a link cannot point into a folder that is off limits.
enum OutgoingFiles {
    static let maxCount = 10

    /// Folders (below the home folder) that applesauce never attaches from. They hold keys, tokens and private data.
    static let blockedFolders = [
        "Library/Keychains", ".ssh", ".gnupg", ".config/applesauce-mcp", ".aws", ".kube", ".config/gcloud",
        ".docker", "Library/Cookies", "Library/Mail", "Library/Messages", "Library/Safari",
    ]
    /// Single files (below the home folder) that applesauce never attaches.
    static let blockedFiles = [".netrc", ".npmrc", ".pypirc", ".git-credentials"]

    /// The real path of `path`: all links resolved. Nil when the path does not exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Checks `paths` and returns the files in the same order.
    static func check(
        _ paths: [String], limit: Int = AttachmentCache.maxBytes,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws -> [OutgoingFile] {
        guard paths.count <= maxCount else {
            throw ToolError(
                .invalidInput, "'attachments' has \(paths.count) files. The limit is \(maxCount).",
                fix: "Attach \(maxCount) files or fewer.")
        }
        // Both the given and the real home folder count, because the home folder can be a link.
        let homes = Set([home, realPath(home) ?? home]).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        var files: [OutgoingFile] = []
        var total = 0
        for path in paths {
            let file = try checkOne(path, limit: limit, homes: homes)
            total += file.size
            files.append(file)
        }
        guard total <= limit else {
            throw ToolError(
                .invalidInput,
                "The attachments are \(AttachmentCache.megabytes(total)) in all. The limit is \(AttachmentCache.megabytes(limit)).",
                fix: "Attach fewer or smaller files, or share a link instead.")
        }
        return files
    }

    private static func checkOne(_ path: String, limit: Int, homes: [String]) throws -> OutgoingFile {
        guard !path.isEmpty, !path.contains("\0") else {
            throw ToolError.invalidInput("'attachments' must contain file paths, and no path may be empty.")
        }
        guard path.hasPrefix("/") else {
            throw ToolError(
                .invalidInput, "The attachment path '\(path)' is not an absolute path.",
                fix: "Give the full path, starting with /. A path that starts with ~ does not work.")
        }
        guard let real = realPath(path) else {
            throw ToolError(
                .notFound, "The attachment '\(path)' does not exist.",
                fix: "Check the path. The tool needs an existing file.")
        }
        if let blocked = blockedReason(real, homes: homes) {
            throw ToolError(
                .invalidInput, "applesauce does not attach files from \(blocked) ('\(path)').",
                fix: "Copy the file to another folder first, if you really need to send it.")
        }
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: real) else {
            throw ToolError(
                .permissionDenied, "The attachment '\(path)' cannot be read.",
                fix: "Check the file permissions.")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            let isFolder = attributes[.type] as? FileAttributeType == .typeDirectory
            throw ToolError(
                .invalidInput,
                isFolder
                    ? "The attachment '\(path)' is a folder or an app bundle."
                    : "The attachment '\(path)' is not a regular file.",
                fix: isFolder
                    ? "Compress the folder to a zip file first, then attach the zip file." : "Attach a regular file.")
        }
        guard fileManager.isReadableFile(atPath: real) else {
            throw ToolError(
                .permissionDenied, "The attachment '\(path)' cannot be read.",
                fix: "Check the file permissions.")
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= limit else {
            throw ToolError(
                .invalidInput,
                "The attachment '\(path)' is \(AttachmentCache.megabytes(size)). The limit is \(AttachmentCache.megabytes(limit)) for each file.",
                fix: "Attach a smaller file, or share a link instead.")
        }
        return OutgoingFile(path: real, name: (real as NSString).lastPathComponent, size: size)
    }

    /// The name of the off limits folder or file that holds `real`, or nil. Names ignore case, like the default Mac disk.
    static func blockedReason(_ real: String, homes: [String]) -> String? {
        let lowered = real.lowercased()
        for home in homes {
            let base = home.lowercased()
            for folder in blockedFolders {
                let prefix = "\(base)/\(folder.lowercased())"
                if lowered == prefix || lowered.hasPrefix(prefix + "/") { return "~/\(folder)" }
            }
            for file in blockedFiles where lowered == "\(base)/\(file.lowercased())" { return "~/\(file)" }
        }
        return nil
    }
}
