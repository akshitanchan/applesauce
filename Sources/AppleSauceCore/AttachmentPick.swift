import Foundation

/// Which attachment of a message or a note the caller wants.
public enum AttachmentPick: Sendable, Equatable {
    /// The position in the attachment list, starting at 1.
    case index(Int)
    /// The file name. It must be unambiguous.
    case name(String)

    /// Reads the optional arguments 'name' and 'index'. Exactly one of them must be there.
    public init(_ args: Arguments) throws {
        let name = try args.string("name")
        let index = try args.int("index")
        switch (name, index) {
        case (nil, nil):
            throw ToolError(
                .invalidInput, "Give 'name' or 'index' to say which attachment you want.",
                fix: "Use a name or a number from the attachment list.")
        case (.some, .some):
            throw ToolError.invalidInput("Give 'name' or 'index', not both.")
        case (let name?, nil):
            guard !name.isEmpty, !name.contains("\0") else {
                throw ToolError.invalidInput("'name' must not be empty and must not contain a NUL character.")
            }
            self = .name(name)
        case (nil, let index?):
            guard index >= 1 else {
                throw ToolError(
                    .invalidInput, "'index' must be 1 or more.", fix: "The first attachment is number 1.")
            }
            self = .index(index)
        }
    }

    /// The position (from 0) of the attachment that this pick means in `names`.
    /// It throws `NOT_FOUND` for no match and `AMBIGUOUS` for a name that more than one attachment has.
    /// `owner` is `message` or `note`, for the error text.
    public func resolve(in names: [String], owner: String) throws -> Int {
        guard !names.isEmpty else {
            throw ToolError(
                .notFound, "The \(owner) has no attachments.", fix: "Check the \(owner) with its get tool.")
        }
        let list = names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: ", ")
        switch self {
        case .index(let number):
            guard names.indices.contains(number - 1) else {
                throw ToolError(
                    .notFound,
                    "The \(owner) has \(names.count) attachments, and none is number \(number). \(list).",
                    fix: "Use a number from 1 to \(names.count).")
            }
            return number - 1
        case .name(let wanted):
            var matches = names.indices.filter { names[$0] == wanted }
            if matches.isEmpty {
                matches = names.indices.filter { names[$0].caseInsensitiveCompare(wanted) == .orderedSame }
            }
            guard let first = matches.first else {
                throw ToolError(
                    .notFound, "The \(owner) has no attachment named '\(wanted)'. Attachments: \(list).",
                    fix: "Use a name from the attachment list, or give 'index'.")
            }
            guard matches.count == 1 else {
                let numbers = matches.map { String($0 + 1) }.joined(separator: ", ")
                throw ToolError(
                    .ambiguous, "More than one attachment is named '\(wanted)' (numbers \(numbers)).",
                    fix: "Give 'index' instead of 'name'.")
            }
            return first
        }
    }
}

/// An attachment that is saved as a file.
public struct SavedAttachment: Sendable, Equatable {
    public let file: URL
    /// The original name (the file name on disk is the sanitized form).
    public let name: String
    public let size: Int

    public init(file: URL, name: String, size: Int) {
        self.file = file
        self.name = name
        self.size = size
    }
}
