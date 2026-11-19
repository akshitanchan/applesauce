import AppleSauceCore
import Foundation

@testable import ModNotes

/// A notes store in memory. It records every call. It never runs AppleScript.
final class FakeNotesStore: NotesStore, @unchecked Sendable {
    struct State {
        var folders: [NotesFolder] = []
        var page = NotesSearchPage(items: [], truncated: false)
        var note: NotesNote?
        /// An error that every call except `folders` throws.
        var error: ToolError?
        var ref = NoteRef(id: "x-coredata://A/ICNote/p1", name: "Result", folder: "Notes", account: "iCloud")
        var calls: [String] = []
        var query: NotesSearchQuery?
        var noteRequest: (id: String, includeHTML: Bool)?
        var created: (html: String, folderId: String?, account: String?)?
        var appended: (id: String, html: String)?
        var replaced: (id: String, html: String)?
        var createdFolder: (name: String, parentId: String?, account: String?)?
        var folderResult = NotesFolder(id: "x-coredata://A/ICFolder/p9", name: "New", account: "iCloud", noteCount: 0)
        var moved: (id: String, folderId: String)?
        var deleted: String?
        /// What `folderDetails` returns, by folder id.
        var details: [String: FolderDetails] = [:]
        var deletedFolder: String?
        /// An error that only `deleteFolder` throws.
        var deleteFolderError: ToolError?
        var delay: Double = 0
        /// What `saveAttachment` writes, and under which name.
        var attachmentData = Data("note attachment".utf8)
        var attachmentName = "memo.txt"
        var savedAttachment: (id: String, pick: AttachmentPick, limit: Int)?
    }

    private let lock = NSLock()
    private var state: State

    init(_ state: State = State()) {
        self.state = state
    }

    func read<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func write(_ body: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&state)
    }

    private func enter(_ call: String) async throws {
        write { $0.calls.append(call) }
        let seconds = read(\.delay)
        if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        if call != "folders", let error = read(\.error) { throw error }
    }

    func folders() async throws -> [NotesFolder] {
        try await enter("folders")
        return read(\.folders)
    }

    func search(_ query: NotesSearchQuery) async throws -> NotesSearchPage {
        write { $0.query = query }
        try await enter("search")
        return read(\.page)
    }

    func note(id: String, includeHTML: Bool) async throws -> NotesNote {
        write { $0.noteRequest = (id, includeHTML) }
        try await enter("note")
        guard let note = read(\.note) else { throw ToolError(.notFound, "No note \(id).") }
        return note
    }

    func saveAttachment(id: String, pick: AttachmentPick, into folder: URL, limit: Int) async throws
        -> SavedAttachment
    {
        write { $0.savedAttachment = (id, pick, limit) }
        try await enter("saveAttachment")
        let (data, name) = (read(\.attachmentData), read(\.attachmentName))
        let file = try AttachmentCache.write(data, name: name, into: folder)
        return SavedAttachment(file: file, name: name, size: data.count)
    }

    func create(html: String, folderId: String?, account: String?) async throws -> NoteRef {
        write { $0.created = (html, folderId, account) }
        try await enter("create")
        return read(\.ref)
    }

    func append(id: String, html: String) async throws -> NoteRef {
        write { $0.appended = (id, html) }
        try await enter("append")
        return read(\.ref)
    }

    func replaceBody(id: String, html: String) async throws -> NoteRef {
        write { $0.replaced = (id, html) }
        try await enter("replaceBody")
        return read(\.ref)
    }

    func createFolder(name: String, parentId: String?, account: String?) async throws -> NotesFolder {
        write { $0.createdFolder = (name, parentId, account) }
        try await enter("createFolder")
        return read(\.folderResult)
    }

    func move(id: String, folderId: String) async throws -> NoteRef {
        write { $0.moved = (id, folderId) }
        try await enter("move")
        return read(\.ref)
    }

    func delete(id: String) async throws -> NoteRef {
        write { $0.deleted = id }
        try await enter("delete")
        return read(\.ref)
    }

    func folderDetails(id: String) async throws -> FolderDetails {
        try await enter("folderDetails")
        guard let details = read({ $0.details[id] }) else { throw ToolError(.notFound, "No folder \(id).") }
        return details
    }

    func deleteFolder(id: String) async throws {
        write { $0.deletedFolder = id }
        try await enter("deleteFolder")
        if let error = read(\.deleteFolderError) { throw error }
    }
}
