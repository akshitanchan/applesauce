import Foundation

/// The kinds of file that `search_files` can filter by.
enum SpotlightKind: String, CaseIterable, Sendable {
    case pdf, image, document, presentation, spreadsheet, folder, audio, video, text

    /// Uniform type identifiers. A file matches when any of them is in its `kMDItemContentTypeTree`.
    var contentTypes: [String] {
        switch self {
        case .pdf: ["com.adobe.pdf"]
        case .image: ["public.image"]
        case .document:
            [
                "com.apple.iwork.pages.sffpages", "org.openxmlformats.wordprocessingml.document",
                "com.microsoft.word.doc", "org.oasis-open.opendocument.text", "public.rtf", "com.apple.rtfd",
            ]
        case .presentation: ["public.presentation"]
        case .spreadsheet: ["public.spreadsheet", "public.comma-separated-values-text"]
        case .folder: ["public.folder"]
        case .audio: ["public.audio"]
        case .video: ["public.movie"]
        case .text: ["public.plain-text"]
        }
    }
}

/// Builds the one query string that goes to mdfind. Pure functions, so tests need no index.
enum SpotlightQuery {
    /// Escapes text for a double-quoted value in an mdfind query: backslash and quote get a backslash.
    /// Line breaks become spaces, because a query is one line.
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n", "\r": result += " "
            default: result.append(character)
            }
        }
        return result
    }

    /// The query for mdfind.
    /// - Without a kind, the text goes as it is, like words typed in Spotlight.
    ///   One exception: text that starts with "-" would look like an option, so it gets the built form.
    /// - With a kind (or a leading "-"): every word must match the file name (anywhere in it) or the
    ///   start of a word in the content. The kind adds a filter on the content type tree.
    static func build(text: String, kind: SpotlightKind?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == nil && !trimmed.hasPrefix("-") { return trimmed }

        let words = trimmed.split(whereSeparator: \.isWhitespace).map { escape(String($0)) }
        var clauses = words.map {
            "(kMDItemDisplayName == \"*\($0)*\"cd || kMDItemTextContent == \"\($0)*\"cd)"
        }
        if let kind {
            let types = kind.contentTypes.map { "kMDItemContentTypeTree == \"\(escape($0))\"" }
            clauses.append("(" + types.joined(separator: " || ") + ")")
        }
        return clauses.joined(separator: " && ")
    }
}
