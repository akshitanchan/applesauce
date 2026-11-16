import Foundation

/// The folder where attachment tools put files, and the rules for it.
///
/// Every attachment goes to `<root>/<unique folder>/<safe name>`. The root is
/// `~/Library/Caches/applesauce/attachments`. Folders and files are private to the user (0700 and 0600).
/// Anything older than 24 hours is deleted at the start of the next attachment call.
public enum AttachmentCache {
    /// Largest attachment that a tool saves, in bytes (25 MB).
    public static let maxBytes = 25 * 1024 * 1024
    /// Age in seconds after which a saved attachment is deleted (24 hours).
    public static let maxAge: TimeInterval = 24 * 3600
    /// Longest file name that is kept, in UTF-8 bytes. The extension is kept.
    static let maxNameBytes = 120

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Caches/applesauce/attachments", isDirectory: true)
    }

    // MARK: names

    /// A file name that is safe to use inside the cache folder. The original name is only data, never a path.
    /// - `/`, `\`, `:` and control characters become `_`.
    /// - Runs of dots become one dot, so `..` cannot stay. Leading and trailing dots and spaces are removed.
    /// - An empty result becomes `attachment`.
    public static func sanitize(_ name: String) -> String {
        let forbidden: Set<Character> = ["/", "\\", ":"]
        var text = String(
            name.map { character -> Character in
                if forbidden.contains(character) { return "_" }
                if character.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return "_" }
                return character
            })
        while text.contains("..") { text = text.replacingOccurrences(of: "..", with: ".") }
        let trim = CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines)
        while let first = text.unicodeScalars.first, trim.contains(first) { text.unicodeScalars.removeFirst() }
        while let last = text.unicodeScalars.last, trim.contains(last) { text.unicodeScalars.removeLast() }
        if text.isEmpty { return "attachment" }
        return shorten(text)
    }

    /// Cuts the name to `maxNameBytes` and keeps a short extension.
    private static func shorten(_ name: String) -> String {
        guard name.utf8.count > maxNameBytes else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : ".\(ext)"
        let stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        var kept = ""
        for character in stem {
            if (kept + String(character)).utf8.count + suffix.utf8.count > maxNameBytes { break }
            kept.append(character)
        }
        return kept.isEmpty ? "attachment\(suffix)" : kept + suffix
    }

    // MARK: folders and files

    /// Makes `root` (private) and a new unique folder inside it. Returns the new folder.
    public static func makeFolder(root: URL = defaultRoot) throws -> URL {
        let fileManager = FileManager.default
        let privateFolder: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        do {
            try fileManager.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: privateFolder)
            try fileManager.setAttributes(privateFolder, ofItemAtPath: root.path)
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(
                at: folder, withIntermediateDirectories: false, attributes: privateFolder)
            return folder
        } catch {
            throw ToolError(
                .internalError, "applesauce could not make the attachment folder: \(error.localizedDescription)",
                fix: "Check that \(root.path) can be written, then try again.")
        }
    }

    /// Writes `data` to `<folder>/<safe name>` and returns the file.
    public static func write(_ data: Data, name: String, into folder: URL) throws -> URL {
        let file = folder.appendingPathComponent(sanitize(name), isDirectory: false)
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw ToolError(
                .internalError, "applesauce could not save the attachment: \(error.localizedDescription)",
                fix: "Check that \(folder.path) can be written, then try again.")
        }
        return file
    }

    /// Deletes every item in `root` that is older than `maxAge` seconds. An item is a folder (by its own date)
    /// or a loose file. It never throws: a failed sweep must not stop a tool call. Returns how many items it removed.
    @discardableResult
    public static func sweep(root: URL = defaultRoot, now: Date = Date(), maxAge: TimeInterval = maxAge) -> Int {
        let fileManager = FileManager.default
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
        else { return 0 }
        let cutoff = now.addingTimeInterval(-maxAge)
        var removed = 0
        for item in items {
            guard
                let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                date < cutoff
            else { continue }
            if (try? fileManager.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: size

    public static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// The error for an attachment above the limit. Nothing is saved.
    public static func tooLarge(name: String, bytes: Int, limit: Int = maxBytes) -> ToolError {
        ToolError(
            .invalidInput,
            "The attachment '\(name)' is \(megabytes(bytes)). applesauce saves files up to \(megabytes(limit)).",
            fix: "Open the item in its app and save the file there.")
    }
}
