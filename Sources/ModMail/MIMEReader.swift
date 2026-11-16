import Foundation

/// What the MIME reader finds in one message. It never keeps attachment bytes.
struct ParsedMail: Sendable, Equatable {
    var subject: String?
    var from: String?
    var to: String?
    var cc: String?
    var date: String?
    var messageID: String?
    /// Plain text. When the message has only HTML, this is the HTML turned into text.
    var body: String
    var attachments: [MailAttachment]
}

/// One attachment part of a message, with its bytes. Only `MIMEReader.attachmentParts` makes these.
struct AttachmentPart: Sendable, Equatable {
    var name: String
    /// Mail's number for the part, for example `1.2` (second part inside the first). It names the folder where Mail
    /// keeps an attachment that is not inside the `.emlx` file.
    var partID: String
    /// The decoded size in bytes. For a part without bytes, the size that Mail wrote in `X-Apple-Content-Length`.
    var size: Int
    var encoding: String
    /// The bytes as written in the message, still encoded. Empty when Mail keeps the attachment elsewhere.
    var body: [UInt8]

    /// The bytes of the attachment after the transfer decoding.
    func decoded() -> [UInt8] { MIMEReader.transferDecode(body, encoding) }
}

/// A small MIME reader for `.emlx` files.
/// It handles multipart, quoted-printable, base64, encoded header words and the common charsets.
enum MIMEReader {
    // MARK: emlx

    /// Largest `.emlx` file that is read, in bytes. A bigger file is not opened.
    static let emlxLimit = 50_000_000

    enum EmlxFile {
        case data(Data)
        case tooLarge(bytes: Int)
        case unreadable
    }

    /// Reads an `.emlx` file. The size is checked first, so a huge file never enters memory.
    static func readEmlx(at url: URL, limit: Int = emlxLimit) -> EmlxFile {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return .unreadable }
        guard size <= limit else { return .tooLarge(bytes: size) }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return .data(data)
    }

    /// The message bytes inside an `.emlx` file.
    /// The first line is the byte length of the message. A plist follows the message, and it is cut off.
    /// A file without that first line is taken as a plain message.
    static func messageBytes(inEmlx data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        guard let newline = bytes.prefix(32).firstIndex(of: 10),
            let length = Int(String(decoding: bytes[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces))
        else { return bytes }
        let start = newline + 1
        return Array(bytes[start..<min(bytes.count, start + max(0, length))])
    }

    // MARK: parse

    /// The attachment parts of a message, in the same order as `parse(_:).attachments`, with their bytes.
    static func attachmentParts(_ bytes: [UInt8]) -> [AttachmentPart] {
        var found = Found()
        found.keepParts = true
        walk(entity(from: bytes), into: &found, depth: 0, partID: "")
        return found.parts
    }

    static func parse(_ bytes: [UInt8]) -> ParsedMail {
        let entity = entity(from: bytes)
        var found = Found()
        walk(entity, into: &found, depth: 0, partID: "")
        let plain = found.plain.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = plain.isEmpty ? htmlToText(found.html.joined(separator: "\n")) : plain
        func header(_ name: String) -> String? {
            entity.headers[name].map { decodeWords($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return ParsedMail(
            subject: header("subject"), from: header("from"), to: header("to"), cc: header("cc"),
            date: header("date"), messageID: header("message-id"), body: body, attachments: found.attachments)
    }

    private struct Entity {
        var headers: [String: String]
        var body: [UInt8]
    }

    private struct Found {
        var plain: [String] = []
        var html: [String] = []
        var attachments: [MailAttachment] = []
        /// Set by `attachmentParts`. `parse` never keeps attachment bytes.
        var keepParts = false
        var parts: [AttachmentPart] = []
    }

    private static func entity(from bytes: [UInt8]) -> Entity {
        let (head, body) = split(bytes)
        return Entity(headers: parseHeaders(head), body: body)
    }

    /// Splits at the first blank line. Handles LF and CRLF.
    static func split(_ bytes: [UInt8]) -> (head: [UInt8], body: [UInt8]) {
        let count = bytes.count
        if count > 0, bytes[0] == 10 { return ([], Array(bytes[1...])) }
        if count > 1, bytes[0] == 13, bytes[1] == 10 { return ([], Array(bytes[2...])) }
        var index = 0
        while index < count {
            if bytes[index] == 10 {
                if index + 1 < count, bytes[index + 1] == 10 {
                    return (Array(bytes[..<index]), Array(bytes[(index + 2)...]))
                }
                if index + 2 < count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    return (Array(bytes[..<index]), Array(bytes[(index + 3)...]))
                }
            }
            index += 1
        }
        return (bytes, [])
    }

    /// Header names are lowercase. A name that appears twice keeps its first value. Folded lines are joined.
    static func parseHeaders(_ head: [UInt8]) -> [String: String] {
        let text = String(decoding: head, as: UTF8.self)
        var lines: [String] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] == nil && !name.isEmpty { headers[name] = value }
        }
        return headers
    }

    // MARK: structure

    private static func walk(_ entity: Entity, into found: inout Found, depth: Int, partID: String) {
        guard depth < 12 else { return }
        let type = headerValue(entity.headers["content-type"] ?? "text/plain")
        let disposition = headerValue(entity.headers["content-disposition"] ?? "")
        let mime = type.value
        let rawName = disposition.params["filename"] ?? type.params["name"]
        let filename = rawName.map { decodeWords($0) }

        if mime.hasPrefix("multipart/") {
            guard let boundary = type.params["boundary"], !boundary.isEmpty else { return }
            for (offset, part) in splitMultipart(entity.body, boundary: boundary).enumerated() {
                let childID = partID.isEmpty ? "\(offset + 1)" : "\(partID).\(offset + 1)"
                walk(Self.entity(from: part), into: &found, depth: depth + 1, partID: childID)
            }
            return
        }

        let encoding = (entity.headers["content-transfer-encoding"] ?? "").lowercased()
            .trimmingCharacters(in: .whitespaces)
        let isAttachment = disposition.value == "attachment"

        if (mime == "text/plain" || mime == "text/html") && !isAttachment && filename == nil {
            let text = decode(transferDecode(entity.body, encoding), charset: type.params["charset"])
            if mime == "text/plain" { found.plain.append(text) } else { found.html.append(text) }
            return
        }
        guard isAttachment || filename != nil || mime == "message/rfc822" else { return }
        var size: Int
        switch encoding {
        case "base64": size = base64Size(entity.body)
        case "quoted-printable": size = decodeQuotedPrintable(entity.body).count
        default: size = entity.body.count
        }
        // A `.partial.emlx` file has no bytes for an attachment, but Mail writes its real size in a header.
        if size == 0, let declared = entity.headers["x-apple-content-length"].flatMap({ Int($0) }) { size = declared }
        let fallback = mime == "message/rfc822" ? "message.eml" : "attachment"
        let name = filename ?? fallback
        found.attachments.append(MailAttachment(name: name, size: size))
        if found.keepParts {
            found.parts.append(
                AttachmentPart(
                    name: name, partID: partID.isEmpty ? "1" : partID, size: size, encoding: encoding,
                    body: entity.body))
        }
    }

    /// The parts between the boundary lines.
    static func splitMultipart(_ body: [UInt8], boundary: String) -> [[UInt8]] {
        let open = Array("--\(boundary)".utf8)
        let close = open + [45, 45]
        var parts: [[UInt8]] = []
        var partStart: Int?
        var lineStart = 0
        let count = body.count
        while lineStart <= count {
            var lineEnd = lineStart
            while lineEnd < count && body[lineEnd] != 10 { lineEnd += 1 }
            var contentEnd = lineEnd
            while contentEnd > lineStart && (body[contentEnd - 1] == 13 || body[contentEnd - 1] == 32) {
                contentEnd -= 1
            }
            let line = Array(body[lineStart..<contentEnd])
            let isOpen = line == open
            let isClose = line == close
            if isOpen || isClose {
                if let start = partStart {
                    var end = lineStart > start ? lineStart - 1 : start
                    if end > start, body[end - 1] == 13 { end -= 1 }
                    parts.append(Array(body[start..<max(start, end)]))
                }
                if isClose {
                    partStart = nil
                    break
                }
                partStart = min(count, lineEnd + 1)
            }
            lineStart = lineEnd + 1
        }
        if let start = partStart, start < count { parts.append(Array(body[start...])) }
        return parts
    }

    // MARK: header values

    struct HeaderValue {
        var value: String
        var params: [String: String]
    }

    /// `text/plain; charset="utf-8"` becomes value `text/plain` and params `["charset": "utf-8"]`.
    /// The value is lowercase. Parameter names are lowercase. It resolves RFC 2231 forms such as `filename*=UTF-8''a%20b`.
    static func headerValue(_ text: String) -> HeaderValue {
        var segments: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if character == ";" && !quoted {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)
        let value = segments.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var raw: [(String, String)] = []
        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var parameter = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if parameter.count >= 2, parameter.hasPrefix("\""), parameter.hasSuffix("\"") {
                parameter = String(parameter.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
            }
            raw.append((key, parameter))
        }
        return HeaderValue(value: value, params: resolveExtended(raw))
    }

    private static func resolveExtended(_ raw: [(String, String)]) -> [String: String] {
        var params: [String: String] = [:]
        var pieces: [String: [(index: Int, value: String, encoded: Bool)]] = [:]
        for (key, value) in raw {
            if let match = key.wholeMatch(of: #/([^*]+)\*(\d+)(\*?)/#) {
                pieces[String(match.1), default: []].append((Int(match.2) ?? 0, value, match.3 == "*"))
            } else if key.hasSuffix("*") {
                pieces[String(key.dropLast()), default: []].append((0, value, true))
            } else if params[key] == nil {
                params[key] = value
            }
        }
        for (name, list) in pieces {
            var charset: String?
            var bytes: [UInt8] = []
            for (position, piece) in list.sorted(by: { $0.index < $1.index }).enumerated() {
                var value = piece.value
                guard piece.encoded else {
                    bytes += Array(value.utf8)
                    continue
                }
                if position == 0, let first = value.firstIndex(of: "'"),
                    let second = value[value.index(after: first)...].firstIndex(of: "'")
                {
                    charset = String(value[..<first])
                    value = String(value[value.index(after: second)...])
                }
                bytes += percentDecode(Array(value.utf8))
            }
            params[name] = decode(bytes, charset: charset)
        }
        return params
    }

    private static func percentDecode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count, let high = hex(bytes[index + 1]),
                let low = hex(bytes[index + 2])
            {
                out.append(high * 16 + low)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return out
    }

    /// Decodes `=?utf-8?B?...?=` and `=?iso-8859-1?Q?...?=` words (RFC 2047).
    static func decodeWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let pattern = #/=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?=/#
        var result = ""
        var cursor = text.startIndex
        var afterWord = false
        for match in text.matches(of: pattern) {
            let gap = text[cursor..<match.range.lowerBound]
            // Spaces between two encoded words are not part of the text.
            if !(afterWord && gap.allSatisfy(\.isWhitespace)) { result += gap }
            let charset = String(match.1).split(separator: "*").first.map(String.init)
            let payload = Array(String(match.3).utf8)
            let bytes =
                match.2.lowercased() == "b"
                ? decodeBase64(payload) : decodeQuotedPrintable(payload, underscoreIsSpace: true)
            result += decode(bytes, charset: charset)
            cursor = match.range.upperBound
            afterWord = true
        }
        result += text[cursor...]
        return result
    }

    // MARK: transfer encodings and charsets

    static func transferDecode(_ bytes: [UInt8], _ encoding: String) -> [UInt8] {
        switch encoding {
        case "base64": decodeBase64(bytes)
        case "quoted-printable": decodeQuotedPrintable(bytes)
        default: bytes
        }
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    static func decodeQuotedPrintable(_ bytes: [UInt8], underscoreIsSpace: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if byte == 61 {
                if index + 1 < count, bytes[index + 1] == 10 {
                    index += 2
                } else if index + 2 < count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    index += 3
                } else if index + 2 < count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    out.append(high * 16 + low)
                    index += 3
                } else {
                    out.append(byte)
                    index += 1
                }
            } else if underscoreIsSpace && byte == 95 {
                out.append(32)
                index += 1
            } else {
                out.append(byte)
                index += 1
            }
        }
        return out
    }

    private static func isBase64Character(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 43 || byte == 47
    }

    static func decodeBase64(_ bytes: [UInt8]) -> [UInt8] {
        var clean = bytes.filter { isBase64Character($0) }
        while clean.count % 4 != 0 { clean.append(61) }
        return Data(base64Encoded: Data(clean)).map { [UInt8]($0) } ?? []
    }

    /// The decoded size, worked out from the text length. It does not decode the attachment.
    static func base64Size(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { $0 + (isBase64Character($1) ? 1 : 0) } * 6 / 8
    }

    /// Bytes to text. Handles every charset that macOS knows by its IANA name (utf-8, iso-8859-1, windows-1252, ...).
    /// Bad UTF-8 is read as windows-1252.
    static func decode(_ bytes: [UInt8], charset: String?) -> String {
        let name = (charset ?? "utf-8").trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        let data = Data(bytes)
        func encoding(_ iana: String) -> String.Encoding? {
            #if os(macOS)
            let cf = CFStringConvertIANACharSetNameToEncoding(iana as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            #else
            // Linux builds never read mail. A few common names keep this compiling and correct.
            switch iana {
            case "iso-8859-1", "latin1": return .isoLatin1
            case "windows-1252", "cp1252": return .windowsCP1252
            case "us-ascii", "ascii": return .ascii
            default: return nil
            }
            #endif
        }
        if name != "utf-8" && name != "utf8" && name != "us-ascii", let wanted = encoding(name),
            let text = String(data: data, encoding: wanted)
        {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let fallback = encoding("windows-1252"), let text = String(data: data, encoding: fallback) { return text }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: html

    /// Most characters of HTML that `htmlToText` works on.
    static let htmlLimit = 2_000_000

    /// A plain text version of an HTML body: tags removed, block ends become line breaks, entities decoded.
    static func htmlToText(_ html: String) -> String {
        // The patterns below can be slow on a huge string, so the HTML is cut first.
        var text = html.count > htmlLimit ? String(html.prefix(htmlLimit)) : html
        text = text.replacing(#/(?is)<(script|style|head)\b.*?</\1\s*>/#, with: "")
        text = text.replacing(#/(?i)<br\s*/?>/#, with: "\n")
        text = text.replacing(#/(?i)<li\b[^>]*>/#, with: "\n- ")
        text = text.replacing(#/(?i)</(p|div|tr|li|h[1-6]|table|blockquote|ul|ol)\s*>/#, with: "\n")
        text = text.replacing(#/<[^>]*>/#, with: "")
        text = text.replacing(#/&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);/#) { match in
            entity(String(match.1)) ?? String(match.0)
        }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map {
            $0.replacing(#/[ \t\u{00A0}]+/#, with: " ").trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n").replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func entity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let code =
                digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return code.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
        }
        let named = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "\u{00A9}",
            "reg": "\u{00AE}", "hellip": "\u{2026}", "ndash": "\u{2013}", "mdash": "\u{2014}",
            "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
            "euro": "\u{20AC}",
        ]
        return named[name]
    }
}
