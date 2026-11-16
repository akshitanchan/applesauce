import Foundation

/// Something with an id and a display name, for example a calendar or a reminder list.
public protocol Identified {
    var id: String { get }
    var title: String { get }
}

/// Finds one item by id or by name. Names match without regard to case.
/// Two matches throw `AMBIGUOUS` (with the ids). No match throws `NOT_FOUND` (with the names).
public func resolveByIdOrName<T: Identified>(_ query: String, kind: String, in items: [T]) throws -> T {
    let query = query.trimmingCharacters(in: .whitespaces)
    if let byID = items.first(where: { $0.id == query }) { return byID }
    let matches = items.filter { $0.title.caseInsensitiveCompare(query) == .orderedSame }
    if matches.count == 1, let match = matches.first { return match }
    if matches.count > 1 {
        let list = matches.map { "'\($0.title)' (id: \($0.id))" }.joined(separator: ", ")
        throw ToolError(
            .ambiguous, "More than one \(kind) is named '\(query)': \(list).",
            fix: "Use the id instead of the name.")
    }
    let names = items.map { "'\($0.title)'" }.sorted().joined(separator: ", ")
    throw ToolError(
        .notFound, "No \(kind) matches '\(query)'. Available: \(names.isEmpty ? "none" : names).",
        fix: "Use a name or an id from the list.")
}
