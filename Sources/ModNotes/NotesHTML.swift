import AppleSauceCore
import Foundation

/// Plain text to the simple HTML that Notes accepts as a body.
/// Every user character is escaped, so text can never add tags.
enum NotesHTML {
    /// Largest HTML (in bytes) that one call may send. The text goes in an argv value, and macOS limits argv size.
    static let maxBytes = 500_000

    /// Escapes `& < > "`.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Escaped text where each line break becomes `<br>`. `\r\n`, `\r` and `\n` all count as a line break.
    static func lines(_ text: String) -> String {
        let parts = text.split(omittingEmptySubsequences: false) { $0.isNewline }
        return parts.map { escape(String($0)) }.joined(separator: "<br>")
    }

    /// The body of a new note. Notes uses the first line as the name, so the title is a heading on that line.
    /// A title is one line: line breaks in it become spaces.
    static func noteBody(title: String, body: String?) -> String {
        var html = titleBlock(title)
        if let body, !body.isEmpty { html += "<div>\(lines(body))</div>" }
        return html
    }

    /// The title line of a note: a heading in its own block. An empty title gives no block, so the body starts the note.
    static func titleBlock(_ title: String) -> String {
        let oneLine = title.split(omittingEmptySubsequences: true) { $0.isNewline }.joined(separator: " ")
        let text = oneLine.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "" : "<div><h1>\(escape(text))</h1></div>"
    }

    /// The HTML of a note with its first block (the title line) replaced by a heading for `title`.
    /// The rest of the HTML stays as it is. Notes writes each line of a note as a `<div>` block. It returns nil when
    /// the HTML does not start with a `<div>` block that closes, because then the title line cannot be found.
    static func replacingTitle(in html: String, with title: String) -> String? {
        let bytes = Array(html.utf8.drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 })
        let open = Array("<div".utf8)
        let close = Array("</div>".utf8)
        func starts(_ pattern: [UInt8], at index: Int) -> Bool {
            index + pattern.count <= bytes.count && bytes[index..<(index + pattern.count)].elementsEqual(pattern)
        }
        guard starts(open, at: 0) else { return nil }
        var depth = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x3C {
                if starts(close, at: index) {
                    depth -= 1
                    index += close.count
                    if depth == 0 {
                        return titleBlock(title) + String(decoding: bytes[index...], as: UTF8.self)
                    }
                    continue
                }
                // `<div` followed by `>` or a space is a block. `<divider>` is not.
                if starts(open, at: index), index + open.count < bytes.count,
                    [0x3E, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index + open.count])
                {
                    depth += 1
                }
            }
            index += 1
        }
        return nil
    }

    /// The plain text of a note without its first line, when that line is the title. Notes starts the plain text
    /// with the title. The text after one line break is the body, so it can be sent back as 'body'.
    static func bodyWithoutTitle(_ text: String, title: String) -> String {
        guard !title.isEmpty, text.hasPrefix(title) else { return text }
        var rest = Substring(text.dropFirst(title.count))
        if let first = rest.first, first.isNewline { rest = rest.dropFirst() }
        return String(rest)
    }

    /// A new paragraph for the end of a note.
    static func fragment(_ text: String) -> String {
        "<div>\(lines(text))</div>"
    }

    static func checkSize(_ html: String) throws {
        guard html.utf8.count <= maxBytes else {
            throw ToolError(
                .invalidInput, "The text is too long to send to Notes (limit: \(maxBytes / 1000) KB after conversion).",
                fix: "Send a shorter text, or split it into several calls.")
        }
    }
}
