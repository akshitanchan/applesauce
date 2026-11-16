import Foundation

public enum AttachmentKind: String, Sendable, Equatable {
    case image, pdf, text, document, other
}

/// What the extractor found in one saved attachment.
struct AttachmentExtraction: Sendable, Equatable {
    var text: String?
    var image: ToolImage?
    var note: String?
}

/// Builds the result of an attachment tool from a file that is already saved: the path always, and the content when
/// applesauce can read it (an image block for images, text for PDF, text files and documents).
public enum AttachmentOutput {
    /// Images above this size in bytes are scaled down before they are returned.
    public static let imageLimit = 5_000_000

    // MARK: types

    public static func kind(forFileName name: String) -> AttachmentKind {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp": .image
        case "pdf": .pdf
        case "txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "xml", "yml", "yaml", "ics", "vcf": .text
        case "rtf", "doc", "docx": .document
        default: .other
        }
    }

    /// The MIME type that goes with the extension, for the types that applesauce reads. Nil for other files.
    public static func mimeType(forFileName name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "txt", "text", "log": "text/plain"
        case "md", "markdown": "text/markdown"
        case "csv": "text/csv"
        case "tsv": "text/tab-separated-values"
        case "json": "application/json"
        case "xml": "application/xml"
        case "yml", "yaml": "application/yaml"
        case "ics": "text/calendar"
        case "vcf": "text/vcard"
        case "rtf": "application/rtf"
        case "doc": "application/msword"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        default: nil
        }
    }

    /// The text cut at `limit` characters, and whether it was cut.
    public static func cut(_ text: String, limit: Int) -> (String, Bool) {
        text.count > limit ? (String(text.prefix(limit)), true) : (text, false)
    }

    // MARK: output

    private struct Payload: Encodable {
        let path: String
        let name: String
        let size: Int
        let mimeType: String?
        let kind: String
        let textReturned: Bool
        /// True when the text was cut at the character limit.
        let truncated: Bool
        let imageReturned: Bool
        let note: String?
    }

    /// - Parameters:
    ///   - file: the saved file. Its path is returned.
    ///   - name: the original attachment name.
    ///   - textLimit: where text is cut, in characters (the same limit as message bodies).
    public static func make(file: URL, name: String, size: Int, textLimit: Int) throws -> ToolOutput {
        let kind = kind(forFileName: name)
        #if os(macOS)
        let extraction = AttachmentExtractor.extract(file: file, name: name, kind: kind)
        #else
        // Linux builds never read attachments: the tools only list there.
        let extraction = AttachmentExtraction()
        #endif
        var note = extraction.note
        var text: String?
        var truncated = false
        if let full = extraction.text {
            let (kept, wasCut) = cut(full, limit: textLimit)
            text = kept
            truncated = wasCut
        }
        let sizeText = AttachmentCache.megabytes(size)
        var lines = ["Saved '\(name)' (\(sizeText)) to: \(file.path)"]
        if let mime = mimeType(forFileName: name) { lines.append("Type: \(mime)") }
        if extraction.image != nil {
            note = note ?? "The image is attached to this result."
        }
        if let note { lines.append("Note: \(note)") }
        if let text {
            lines.append("")
            lines.append(text)
            if truncated { lines.append("\n(Text cut at \(textLimit) characters.)") }
        }
        let payload = Payload(
            path: file.path, name: name, size: size, mimeType: mimeType(forFileName: name), kind: kind.rawValue,
            textReturned: text != nil, truncated: truncated, imageReturned: extraction.image != nil, note: note)
        return try ToolOutput(
            text: lines.joined(separator: "\n"), payload: payload, images: extraction.image.map { [$0] } ?? [])
    }
}
