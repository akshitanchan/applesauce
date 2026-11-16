import AppleSauceCore
import Foundation

/// The real notes store. It talks to Notes through AppleScript.
struct AppleNotesStore: NotesStore {
    let readTimeout: Double
    let writeTimeout: Double

    init(readTimeout: Double = 60, writeTimeout: Double = 30) {
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
    }

    private static func unreadable() -> ToolError {
        ToolError(.internalError, "Notes gave an answer that could not be read.", fix: "Report this error.")
    }

    private func ref(_ text: String) throws -> NoteRef {
        guard let ref = NotesScripts.parseRef(text) else { throw Self.unreadable() }
        return ref
    }

    func folders() async throws -> [NotesFolder] {
        NotesScripts.parseFolders(try await NotesScripts.run(NotesScripts.folders, [], timeout: readTimeout))
    }

    func search(_ query: NotesSearchQuery) async throws -> NotesSearchPage {
        let text = try await NotesScripts.run(
            NotesScripts.search, NotesScripts.searchArguments(query), timeout: readTimeout, search: true)
        return NotesScripts.finish(NotesScripts.parseSearch(text), limit: query.limit)
    }

    func note(id: String, includeHTML: Bool) async throws -> NotesNote {
        let text = try await NotesScripts.run(
            NotesScripts.note, NotesScripts.noteArguments(id: id, includeHTML: includeHTML), timeout: readTimeout)
        guard let note = NotesScripts.parseNote(text, includeHTML: includeHTML) else { throw Self.unreadable() }
        return note
    }

    func create(html: String, folderId: String?, account: String?) async throws -> NoteRef {
        try ref(
            try await NotesScripts.run(
                NotesScripts.create, NotesScripts.createArguments(html: html, folderId: folderId, account: account),
                timeout: writeTimeout))
    }

    func append(id: String, html: String) async throws -> NoteRef {
        try ref(try await NotesScripts.run(NotesScripts.append, [id, html], timeout: writeTimeout))
    }

    func move(id: String, folderId: String) async throws -> NoteRef {
        try ref(try await NotesScripts.run(NotesScripts.move, [id, folderId], timeout: writeTimeout))
    }

    func delete(id: String) async throws -> NoteRef {
        try ref(try await NotesScripts.run(NotesScripts.delete, [id], timeout: writeTimeout))
    }
}
