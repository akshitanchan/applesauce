// Reads the content of a saved attachment with ImageIO, PDFKit and AppKit. macOS only.
#if os(macOS)
import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum AttachmentExtractor {
    /// Pixel sizes to try, from large to small, when an image must be made smaller.
    static let scaleSteps = [2048, 1536, 1024, 768, 512]

    static func extract(file: URL, name: String, kind: AttachmentKind) -> AttachmentExtraction {
        switch kind {
        case .image: image(file: file, name: name)
        case .pdf: pdf(file: file)
        case .text: plainText(file: file)
        case .document: document(file: file)
        case .other: AttachmentExtraction()
        }
    }

    private static func unreadable(_ what: String) -> AttachmentExtraction {
        AttachmentExtraction(note: "applesauce could not read this \(what). Only the file path is returned.")
    }

    // MARK: images

    /// A JPEG, PNG, GIF or WebP up to the size limit goes out as it is. HEIC becomes JPEG. A larger image is scaled
    /// down (a PNG stays PNG, the others become JPEG).
    static func image(file: URL, name: String, limit: Int = AttachmentOutput.imageLimit) -> AttachmentExtraction {
        guard let data = try? Data(contentsOf: file) else { return unreadable("image") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return unreadable("image (the file is not a picture that macOS can open)")
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let isHEIC = ext == "heic" || ext == "heif"
        if !isHEIC, data.count <= limit, let mime = AttachmentOutput.mimeType(forFileName: name) {
            return AttachmentExtraction(image: ToolImage(data: data.base64EncodedString(), mimeType: mime))
        }
        let keepPNG = ext == "png"
        let type = keepPNG ? UTType.png : UTType.jpeg
        let mime = keepPNG ? "image/png" : "image/jpeg"
        let full = fullSize(of: source)
        // HEIC is tried at full size first. A large image is tried at smaller sizes only.
        let steps: [Int] = isHEIC ? [full] + scaleSteps.filter { $0 < full } : scaleSteps.filter { $0 < full }
        for pixels in steps {
            guard let encoded = encode(source, maxPixel: pixels, type: type), encoded.count <= limit else { continue }
            let note =
                isHEIC
                ? (pixels == full
                    ? "Converted from HEIC to JPEG for display."
                    : "Converted from HEIC to JPEG and scaled to \(pixels) pixels for display.")
                : "The image is larger than \(limit / 1_000_000) MB, so the copy in this result is scaled to \(pixels) pixels. The saved file is the original."
            return AttachmentExtraction(
                image: ToolImage(data: encoded.base64EncodedString(), mimeType: mime), note: note)
        }
        return AttachmentExtraction(
            note:
                "The image is too large to show, and applesauce could not make it smaller. Only the file path is returned."
        )
    }

    private static func fullSize(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return max(max(width, height), 1)
    }

    /// The first frame, at most `maxPixel` pixels on the long side, with its orientation applied.
    private static func encode(_ source: CGImageSource, maxPixel: Int, type: UTType) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    // MARK: text

    private static func pdf(file: URL) -> AttachmentExtraction {
        guard let document = PDFDocument(url: file) else { return unreadable("PDF") }
        if document.isLocked {
            return AttachmentExtraction(note: "The PDF is password protected. Only the file path is returned.")
        }
        let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return AttachmentExtraction(
                note: "The PDF has no text. It may be a scan or only images. Only the file path is returned.")
        }
        return AttachmentExtraction(text: text)
    }

    private static func plainText(file: URL) -> AttachmentExtraction {
        guard let data = try? Data(contentsOf: file) else { return unreadable("file") }
        let text = decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return AttachmentExtraction(note: "The file is empty.") }
        return AttachmentExtraction(text: text)
    }

    /// UTF-8 (with or without a byte order mark), UTF-16 with a mark, and windows-1252 for the rest.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
            let text = String(data: data, encoding: .utf16)
        {
            return text
        }
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// RTF, DOC and DOCX. AppKit reads them as attributed text, and the plain string is the result.
    private static func document(file: URL) -> AttachmentExtraction {
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(url: file, options: [:], documentAttributes: nil)
        } catch {
            return unreadable("document (\(error.localizedDescription))")
        }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return AttachmentExtraction(note: "The document has no text. Only the file path is returned.")
        }
        return AttachmentExtraction(text: text)
    }
}
#endif
