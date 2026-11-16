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
        let oneLine = title.split(omittingEmptySubsequences: true) { $0.isNewline }.joined(separator: " ")
        var html = "<div><h1>\(escape(oneLine.trimmingCharacters(in: .whitespaces)))</h1></div>"
        if let body, !body.isEmpty { html += "<div>\(lines(body))</div>" }
        return html
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
