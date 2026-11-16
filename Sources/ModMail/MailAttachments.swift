import AppleSauceCore
import Foundation

/// Finds one attachment in a message file and saves it. It reads the bytes from the `.emlx` file, or, when Mail keeps
/// the attachment in its own folder (a `.partial.emlx` file), from `Attachments/<message id>/<part number>/`.
enum MailAttachments {
    // MARK: choosing

    /// The position (from 0) of the attachment that `pick` means. It throws `NOT_FOUND` or `AMBIGUOUS`.
    static func resolve(_ pick: AttachmentPick, in names: [String]) throws -> Int {
        try pick.resolve(in: names, owner: "message")
    }

    // MARK: saving from the message file

    static func notDownloaded(_ name: String) -> ToolError {
        ToolError(
            .notFound, "Mail has not downloaded the attachment '\(name)' yet.",
            fix: "Open the message in Mail so that it downloads the attachment, then try again.")
    }

    /// Saves one attachment of the message in `emlx` into `folder`.
    /// - Parameters:
    ///   - rowid: the message id. It names the attachment folder of Mail.
    ///   - limit: the largest size in bytes. A bigger attachment is refused before it is read.
    static func save(
        emlx: EmlxLocator.Found, rowid: String, pick: AttachmentPick, into folder: URL, limit: Int
    ) throws -> SavedAttachment {
        let data: Data
        switch MIMEReader.readEmlx(at: emlx.url) {
        case .data(let found): data = found
        case .tooLarge(let bytes):
            throw ToolError(
                .invalidInput,
                "The message file is too large to read (\(AttachmentCache.megabytes(bytes))).",
                fix: "Open the message in Mail and save the attachment there.")
        case .unreadable:
            throw ToolError(
                .internalError, "The message file could not be read.",
                fix: "Check Full Disk Access with the doctor tool.")
        }
        let parts = MIMEReader.attachmentParts(MIMEReader.messageBytes(inEmlx: data))
        let part = parts[try resolve(pick, in: parts.map(\.name))]
        guard part.size <= limit else {
            throw AttachmentCache.tooLarge(name: part.name, bytes: part.size, limit: limit)
        }

        let bytes = part.decoded()
        if !bytes.isEmpty {
            guard bytes.count <= limit else {
                throw AttachmentCache.tooLarge(name: part.name, bytes: bytes.count, limit: limit)
            }
            let file = try AttachmentCache.write(Data(bytes), name: part.name, into: folder)
            return SavedAttachment(file: file, name: part.name, size: bytes.count)
        }
        // No bytes in the file: Mail keeps the attachment in its own folder, or has not downloaded it.
        let source = try downloadedFile(of: part, emlx: emlx.url, rowid: rowid)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= limit else { throw AttachmentCache.tooLarge(name: part.name, bytes: size, limit: limit) }
        let target = folder.appendingPathComponent(AttachmentCache.sanitize(part.name), isDirectory: false)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            throw ToolError(
                .internalError, "applesauce could not copy the attachment: \(error.localizedDescription)",
                fix: "Check that \(folder.path) can be written, then try again.")
        }
        return SavedAttachment(file: target, name: part.name, size: size)
    }

    /// The file that Mail keeps for a downloaded attachment: `<Data folder>/Attachments/<message id>/<part id>/<name>`.
    /// The folder is next to the `Messages` folder that holds the `.emlx` file. The name comes from a folder listing,
    /// never from the message, so a name in a message cannot point outside the folder.
    static func downloadedFile(of part: AttachmentPart, emlx: URL, rowid: String) throws -> URL {
        let folder = emlx.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(rowid, isDirectory: true)
            .appendingPathComponent(part.partID, isDirectory: true)
        let fileManager = FileManager.default
        let entries = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter {
            !$0.hasPrefix(".")
        }
        let files = entries.filter { name in
            var isDirectory: ObjCBool = false
            let path = folder.appendingPathComponent(name).path
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard let name = files.first(where: { $0 == part.name }) ?? (files.count == 1 ? files.first : nil) else {
            throw notDownloaded(part.name)
        }
        return folder.appendingPathComponent(name, isDirectory: false)
    }
}
