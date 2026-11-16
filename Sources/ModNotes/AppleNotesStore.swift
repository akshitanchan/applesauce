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

    func saveAttachment(id: String, pick: AttachmentPick, into folder: URL, limit: Int) async throws
        -> SavedAttachment
    {
        let target = folder.appendingPathComponent("saved-by-notes", isDirectory: false)
        let (mode, value): (String, String) =
            switch pick {
            case .index(let number): ("index", String(number))
            case .name(let name): ("name", name)
            }
        let text = try await NotesScripts.run(
            NotesScripts.saveAttachment, [id, mode, value, target.path], timeout: writeTimeout)
        let name = text.isEmpty ? "attachment" : text
        // Notes says nothing about the size before it saves, so the size is checked on the file.
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size, size > 0 else {
            try? FileManager.default.removeItem(at: target)
            throw ToolError(
                .invalidInput, "Notes saved no data for the attachment '\(name)'.",
                fix:
                    "Drawings, scans, tables and links cannot be saved. Open the note in Notes and export the item there."
            )
        }
        guard size <= limit else {
            try? FileManager.default.removeItem(at: target)
            throw AttachmentCache.tooLarge(name: name, bytes: size, limit: limit)
        }
        let file = folder.appendingPathComponent(AttachmentCache.sanitize(name), isDirectory: false)
        do {
            if file.path != target.path { try FileManager.default.moveItem(at: target, to: file) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw ToolError(
                .internalError, "applesauce could not keep the attachment: \(error.localizedDescription)",
                fix: "Check that \(folder.path) can be written, then try again.")
        }
        return SavedAttachment(file: file, name: name, size: size)
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

    func replaceBody(id: String, html: String) async throws -> NoteRef {
        try ref(try await NotesScripts.run(NotesScripts.replace, [id, html], timeout: writeTimeout))
    }

    func createFolder(name: String, parentId: String?, account: String?) async throws -> NotesFolder {
        let text = try await NotesScripts.run(
            NotesScripts.createFolder,
            NotesScripts.createFolderArguments(name: name, parentId: parentId, account: account),
            timeout: writeTimeout)
        guard let folder = NotesScripts.parseFolders(text).first else { throw Self.unreadable() }
        return folder
    }

    func move(id: String, folderId: String) async throws -> NoteRef {
        try ref(try await NotesScripts.run(NotesScripts.move, [id, folderId], timeout: writeTimeout))
    }

    func delete(id: String) async throws -> NoteRef {
        try ref(try await NotesScripts.run(NotesScripts.delete, [id], timeout: writeTimeout))
    }
}
