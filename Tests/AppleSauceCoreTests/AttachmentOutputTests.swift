import Foundation
import Testing

@testable import AppleSauceCore

@Suite struct AttachmentOutputTests {
    @Test func kindsAndMimeTypesFollowTheExtension() {
        #expect(AttachmentOutput.kind(forFileName: "a.JPG") == .image)
        #expect(AttachmentOutput.kind(forFileName: "a.heic") == .image)
        #expect(AttachmentOutput.kind(forFileName: "a.webp") == .image)
        #expect(AttachmentOutput.kind(forFileName: "a.pdf") == .pdf)
        #expect(AttachmentOutput.kind(forFileName: "a.csv") == .text)
        #expect(AttachmentOutput.kind(forFileName: "a.docx") == .document)
        #expect(AttachmentOutput.kind(forFileName: "a.zip") == .other)
        #expect(AttachmentOutput.kind(forFileName: "noextension") == .other)
        #expect(AttachmentOutput.mimeType(forFileName: "a.jpeg") == "image/jpeg")
        #expect(AttachmentOutput.mimeType(forFileName: "a.zip") == nil)
    }

    @Test func textIsCutAtTheLimit() {
        let (same, cutSame) = AttachmentOutput.cut(String(repeating: "a", count: 100_000), limit: 100_000)
        #expect(same.count == 100_000 && cutSame == false)
        let (cut, truncated) = AttachmentOutput.cut(String(repeating: "é", count: 100_001), limit: 100_000)
        #expect(cut.count == 100_000 && truncated)
    }
}

#if os(macOS)
import AppKit
import ImageIO
import MCP
import PDFKit
import UniformTypeIdentifiers

/// These tests save real files in a temp folder and read them with ImageIO, PDFKit and AppKit.
@Suite struct AttachmentExtractionTests {
    func folder() throws -> URL {
        try AttachmentCache.makeFolder(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(
                "applesauce-extract-\(UUID().uuidString)", isDirectory: true))
    }

    func save(_ data: Data, as name: String, in folder: URL) throws -> URL {
        try AttachmentCache.write(data, name: name, into: folder)
    }

    /// A picture with a gradient, so that it does not compress to nothing.
    func pictureData(width: Int, height: Int, type: UTType) -> Data? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let pixels = context.data
        else { return nil }
        let buffer = pixels.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * context.bytesPerRow + x * 4
                buffer[offset] = UInt8((x * 7 + y * 3) % 256)
                buffer[offset + 1] = UInt8((x * 5 + y * 11) % 256)
                buffer[offset + 2] = UInt8((x ^ y) % 256)
                buffer[offset + 3] = 255
            }
        }
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    func size(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    // MARK: images

    @Test func smallImagesGoOutAsTheyAreAsAnImageBlock() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let png = try #require(pictureData(width: 40, height: 30, type: .png))
        let file = try save(png, as: "chart.png", in: folder)
        let output = try AttachmentOutput.make(file: file, name: "chart.png", size: png.count, textLimit: 100_000)
        let image = try #require(output.images.first)
        #expect(output.images.count == 1 && image.mimeType == "image/png")
        // The block holds the file bytes as base64, so a client can decode them again.
        #expect(Data(base64Encoded: image.data) == png)
        #expect(output.text.contains(file.path) && output.text.contains("Type: image/png"))
        let payload = try #require(output.structured?.objectValue)
        #expect(payload["path"]?.stringValue == file.path)
        #expect(payload["image_returned"]?.boolValue == true && payload["kind"]?.stringValue == "image")
        #expect(payload["mime_type"]?.stringValue == "image/png")
    }

    @Test func jpegKeepsItsMimeType() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let jpeg = try #require(pictureData(width: 64, height: 64, type: .jpeg))
        let file = try save(jpeg, as: "photo.JPEG", in: folder)
        let output = try AttachmentOutput.make(file: file, name: "photo.JPEG", size: jpeg.count, textLimit: 100)
        #expect(output.images.first?.mimeType == "image/jpeg")
    }

    @Test func largeImagesAreScaledDownAndTheOriginalStaysOnDisk() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let jpeg = try #require(pictureData(width: 1600, height: 1200, type: .jpeg))
        let file = try save(jpeg, as: "big.jpg", in: folder)
        // A small limit makes the test fast: the image is above it.
        let limit = jpeg.count / 2
        let result = AttachmentExtractor.image(file: file, name: "big.jpg", limit: limit)
        let image = try #require(result.image)
        let scaled = try #require(Data(base64Encoded: image.data))
        #expect(image.mimeType == "image/jpeg" && scaled.count <= limit && scaled.count < jpeg.count)
        let (width, height) = try #require(size(of: scaled))
        #expect(max(width, height) < 1600 && width * 3 == height * 4 || abs(width * 3 - height * 4) < 8)
        #expect(result.note?.contains("scaled") == true)
        #expect(try Data(contentsOf: file) == jpeg)
    }

    @Test func largeImagesThatCannotShrinkGiveOnlyAPath() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let jpeg = try #require(pictureData(width: 600, height: 600, type: .jpeg))
        let file = try save(jpeg, as: "big.jpg", in: folder)
        let result = AttachmentExtractor.image(file: file, name: "big.jpg", limit: 10)
        #expect(result.image == nil && result.note?.contains("file path") == true)
    }

    @Test func heicBecomesJpeg() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        // Not every Mac can encode HEIC. Without an encoder there is nothing to convert.
        guard let heic = pictureData(width: 64, height: 48, type: .heic) else { return }
        let file = try save(heic, as: "IMG_0001.HEIC", in: folder)
        let output = try AttachmentOutput.make(file: file, name: "IMG_0001.HEIC", size: heic.count, textLimit: 100)
        let image = try #require(output.images.first)
        #expect(image.mimeType == "image/jpeg")
        let jpeg = try #require(Data(base64Encoded: image.data))
        #expect(jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(output.text.contains("HEIC to JPEG"))
    }

    @Test func aFileThatIsNotAPictureGivesAPathAndANote() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let file = try save(Data("not a picture".utf8), as: "fake.png", in: folder)
        let output = try AttachmentOutput.make(file: file, name: "fake.png", size: 13, textLimit: 100)
        #expect(output.images.isEmpty && output.text.contains("Note:") && output.text.contains(file.path))
    }

    // MARK: text

    func pdfData(text: String?) -> Data {
        let content = text.map { "BT /F1 18 Tf 20 100 Td (\($0)) Tj ET" } ?? ""
        let pdf = """
            %PDF-1.4
            1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
            2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
            3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
            4 0 obj<</Length \(content.utf8.count)>>stream
            \(content)
            endstream
            endobj
            5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
            trailer<</Root 1 0 R/Size 6>>
            %%EOF
            """
        return Data(pdf.utf8)
    }

    @Test func pdfTextIsExtracted() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let data = pdfData(text: "Invoice 4711 total")
        let file = try save(data, as: "invoice.pdf", in: folder)
        let output = try AttachmentOutput.make(file: file, name: "invoice.pdf", size: data.count, textLimit: 100_000)
        #expect(output.text.contains("Invoice 4711 total") && output.text.contains(file.path))
        #expect(output.images.isEmpty && output.structured?.objectValue?["text_returned"]?.boolValue == true)
    }

    @Test func aPdfWithoutTextSaysSoAndGivesOnlyThePath() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let data = pdfData(text: nil)
        let file = try save(data, as: "scan.pdf", in: folder)
        let output = try AttachmentOutput.make(file: file, name: "scan.pdf", size: data.count, textLimit: 100_000)
        #expect(output.text.contains("no text") && output.text.contains("scan"))
        #expect(output.text.contains("Only the file path is returned") && output.text.contains(file.path))
        let payload = try #require(output.structured?.objectValue)
        #expect(payload["text_returned"]?.boolValue == false && payload["image_returned"]?.boolValue == false)
    }

    @Test func plainTextIsCutAtTheLimitAndSaysSo() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let text = String(repeating: "é", count: 100_001)
        let file = try save(Data(text.utf8), as: "long.txt", in: folder)
        let output = try AttachmentOutput.make(
            file: file, name: "long.txt", size: text.utf8.count, textLimit: 100_000)
        #expect(output.text.contains(String(repeating: "é", count: 100_000)))
        #expect(!output.text.contains(String(repeating: "é", count: 100_001)))
        #expect(output.text.contains("Text cut at 100000 characters"))
        #expect(output.structured?.objectValue?["truncated"]?.boolValue == true)

        let short = try save(Data("a,b\n1,2\n".utf8), as: "table.csv", in: folder)
        let shortOutput = try AttachmentOutput.make(file: short, name: "table.csv", size: 8, textLimit: 100_000)
        #expect(shortOutput.text.contains("a,b\n1,2") && !shortOutput.text.contains("cut at"))
        #expect(shortOutput.structured?.objectValue?["truncated"]?.boolValue == false)
    }

    @Test func textEncodingsAreDecoded() {
        #expect(AttachmentExtractor.decode(Data("Grüße".utf8)) == "Grüße")
        #expect(AttachmentExtractor.decode(Data([0xEF, 0xBB, 0xBF] + Array("hi".utf8))) == "hi")
        #expect(AttachmentExtractor.decode(Data([0x47, 0x72, 0xFC, 0xDF, 0x65])) == "Grüße")
        #expect(AttachmentExtractor.decode("hé".data(using: .utf16) ?? Data()) == "hé")
    }

    @Test func rtfAndDocxTextIsExtracted() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let attributed = NSAttributedString(string: "Meeting notes for Monday")
        let rtf = try #require(
            try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
        let rtfFile = try save(rtf, as: "notes.rtf", in: folder)
        let rtfOutput = try AttachmentOutput.make(file: rtfFile, name: "notes.rtf", size: rtf.count, textLimit: 1000)
        #expect(rtfOutput.text.contains("Meeting notes for Monday"))

        if let docx = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        {
            let docxFile = try save(docx, as: "notes.docx", in: folder)
            let docxOutput = try AttachmentOutput.make(
                file: docxFile, name: "notes.docx", size: docx.count, textLimit: 1000)
            #expect(docxOutput.text.contains("Meeting notes for Monday"))
        }
    }

    @Test func otherTypesGiveOnlyThePath() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let file = try save(Data([0x50, 0x4B, 3, 4]), as: "archive.zip", in: folder)
        let output = try AttachmentOutput.make(file: file, name: "archive.zip", size: 4, textLimit: 100)
        #expect(output.images.isEmpty && output.text.contains(file.path))
        let payload = try #require(output.structured?.objectValue)
        #expect(payload["kind"]?.stringValue == "other" && payload["text_returned"]?.boolValue == false)
    }
}
#endif
