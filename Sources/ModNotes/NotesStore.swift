import AppleSauceCore
import Foundation

struct NotesFolder: Encodable, Sendable, Equatable, Identified {
    /// The AppleScript id of the folder, for example `x-coredata://.../ICFolder/p12`.
    let id: String
    let name: String
    let account: String
    let noteCount: Int?
    var title: String { name }
}

struct NoteSummary: Encodable, Sendable, Equatable {
    /// The AppleScript id of the note, for example `x-coredata://.../ICNote/p345`.
    let id: String
    let name: String
    let folder: String
    let account: String
    let modified: Date?
    /// True for a password protected note. Its text is never read, so `snippet` is empty.
    let locked: Bool
    /// Up to 200 characters of the body text.
    let snippet: String
}

struct NotesSearchPage: Sendable, Equatable {
    var items: [NoteSummary]
    /// More notes may match than were returned.
    var truncated: Bool
}

struct NotesSearchQuery: Sendable, Equatable {
    var text: String
    /// A folder id. Nil means all folders.
    var folderId: String?
    /// An account name. Nil means all accounts.
    var account: String?
    var limit: Int = 25
}

struct NotesNote: Encodable, Sendable, Equatable {
    let id: String
    let name: String
    let folder: String
    let account: String
    let created: Date?
    let modified: Date?
    /// Plain text.
    let body: String
    /// True when the body was cut at the character limit.
    let truncated: Bool
    /// The HTML body. Only set when it was asked for.
    let html: String?
}

/// A note after a write. For a move, `id` is the id that Notes reports after the move.
struct NoteRef: Encodable, Sendable, Equatable {
    let id: String
    let name: String
    let folder: String
    let account: String
}

/// The only way the notes module reaches Notes. The real store runs AppleScript. Tests use a fake.
protocol NotesStore: Sendable {
    /// All folders of all accounts.
    func folders() async throws -> [NotesFolder]
    func search(_ query: NotesSearchQuery) async throws -> NotesSearchPage
    /// Throws `NOT_FOUND` for an unknown id, and `PERMISSION_DENIED` for a locked note.
    func note(id: String, includeHTML: Bool) async throws -> NotesNote
    /// `folderId` and `account` are optional. Without both, Notes uses its default folder.
    func create(html: String, folderId: String?, account: String?) async throws -> NoteRef
    func append(id: String, html: String) async throws -> NoteRef
    func move(id: String, folderId: String) async throws -> NoteRef
    func delete(id: String) async throws -> NoteRef
}
