import AppleSauceCore
import Foundation

/// One file or folder in a result.
struct FileInfo: Encodable, Sendable, Equatable {
    let path: String
    let name: String
    /// For example "PDF document", in the user's language.
    let kind: String
    /// Bytes. Nil for a folder.
    let size: Int?
    let modified: Date?
}

/// What a search found.
struct SearchHits: Sendable, Equatable {
    let paths: [String]
    /// True when mdfind wrote more than the store reads. `paths` then holds only complete paths from the start.
    var truncated = false
}

/// The only way the spotlight module reaches the search index and the file system.
/// The real store runs `/usr/bin/mdfind`. Tests use a fake.
protocol SpotlightStore: Sendable {
    /// Paths that match an mdfind query, in the order mdfind gives them.
    func search(query: String, folder: String?) async throws -> SearchHits
    /// Details of a path, or nil when it no longer exists.
    func describe(path: String) async -> FileInfo?
}
