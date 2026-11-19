import AppleSauceCore
import Foundation
import MCP

/// Notes tools. All of them go through a `NotesStore`. The real store runs AppleScript.
public struct NotesModule: Module {
    public static let moduleName = "notes"
    public var name: String { Self.moduleName }
    public static let requiredPermissions: [Permission] = [.automationNotes]
    public var permissions: [Permission] { Self.requiredPermissions }

    let store: any NotesStore
    let backendTimeout: Double
    let writeTimeout: Double
    /// Where `get_note_attachment` saves files, and the largest file it saves.
    let attachmentRoot: URL
    let attachmentLimit: Int

    /// The real module, backed by AppleScript.
    public init() {
        self.init(store: AppleNotesStore())
    }

    init(
        store: any NotesStore, backendTimeout: Double = 60, writeTimeout: Double = 30,
        attachmentRoot: URL = AttachmentCache.defaultRoot, attachmentLimit: Int = AttachmentCache.maxBytes
    ) {
        self.store = store
        self.backendTimeout = backendTimeout
        self.writeTimeout = writeTimeout
        self.attachmentRoot = attachmentRoot
        self.attachmentLimit = attachmentLimit
    }

    // MARK: tools

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static let idProperty = property("string", "Note id from search_notes (it starts with x-coredata://).")
    private static let accountProperty = property("string", "Account name, for example iCloud. Ignores case.")

    public var tools: [ToolSpec] { Self.toolSpecs }

    public static var toolSpecs: [ToolSpec] {
        [
            ToolSpec(
                name: "list_folders",
                description: "List the Notes folders with their account, note count and id.",
                properties: ["account": Self.accountProperty]),
            ToolSpec(
                name: "search_notes",
                description:
                    "Search notes by title and body text. Title matches come first, then body matches, newest first in each group. The body is searched only when the title matches are fewer than 'limit'. Locked notes can match by title only. Large libraries are slow, so give 'folder' when you can.",
                properties: [
                    "query": Self.property("string", "Text to find in the title or the body. Ignores case."),
                    "folder": Self.property("string", "Folder name (any case) or id. Default: all folders."),
                    "account": Self.accountProperty,
                    "limit": Self.property("integer", "Most results to return. Default 25, maximum 200."),
                ],
                required: ["query"]),
            ToolSpec(
                name: "get_note",
                description:
                    "Get one note: name, folder, account, dates and the plain text body (cut at 100000 characters). Locked notes are not read. Attachments are listed (number, name, type) but their content is not returned. Use get_note_attachment for that.",
                properties: [
                    "id": Self.idProperty,
                    "include_html": Self.property("boolean", "true to add the HTML body. Default false."),
                ],
                required: ["id"]),
            ToolSpec(
                name: "get_note_attachment",
                description:
                    "Save one attachment of a note as a file on this Mac and return its absolute path. Images (JPEG, PNG, GIF, WebP, HEIC) are also returned as an image. PDF, text, RTF, DOC and DOCX files are also returned as text (cut at 100000 characters). Other types return the path only. Files above 25 MB are refused. Notes cannot save drawings, scans, tables and links: the call then fails with an error. Locked notes are not read. The file is kept for 24 hours. Give the attachment by 'name' or 'index' from get_note. Needs 'confirm' true on every call. Ask the user first, because the file is copied to ~/Library/Caches/applesauce/attachments.",
                properties: [
                    "id": Self.idProperty,
                    "name": Self.property(
                        "string", "Attachment name from get_note. Give 'name' or 'index', not both."),
                    "index": Self.property("integer", "Attachment number from get_note. The first is 1."),
                    "confirm": Self.property(
                        "boolean",
                        "Must be true. Ask the user first: the call copies the attachment to this Mac."),
                ],
                required: ["id"],
                // It writes a file to the Mac and can copy private content out of Notes, so `--read-only` hides it.
                write: true),
            ToolSpec(
                name: "create_note",
                description:
                    "Create a note from plain text. The title becomes the first line (a heading). Notes uses the default folder when 'folder' is not given.",
                properties: [
                    "title": Self.property("string", "Title of the note, on one line."),
                    "body": Self.property("string", "Plain text body. Line breaks are kept."),
                    "folder": Self.property("string", "Folder name (any case) or id."),
                    "account": Self.accountProperty,
                ],
                required: ["title"], write: true),
            ToolSpec(
                name: "append_to_note",
                description:
                    "Add plain text as a new paragraph at the end of a note. Notes writes the whole note again, so some rich content (for example a drawing) can change. Locked notes are not changed.",
                properties: ["id": Self.idProperty, "text": Self.property("string", "Plain text to add.")],
                required: ["id", "text"], write: true),
            ToolSpec(
                name: "update_note",
                description:
                    "Change the title or the plain text body of a note. Give 'title', 'body' or both. 'body' replaces the whole body, and the title stays as the first line (a heading). 'title' alone renames the note and keeps the rest. The result has 'previous_title' and 'previous_body' (the old text below the title), so the change can be undone with this tool. Notes writes the whole note again, so rich content (for example a drawing, a table or formatting) can change. Locked notes are not changed.",
                properties: [
                    "id": Self.idProperty,
                    "title": Self.property("string", "New title, on one line."),
                    "body": Self.property(
                        "string", "New plain text body. It replaces the whole body. Line breaks are kept."),
                ],
                required: ["id"], destructive: true),
            ToolSpec(
                name: "create_folder",
                description:
                    "Create a Notes folder. Give 'parent' to make it inside another folder. Without 'parent', it goes to the top level of 'account' (default: the default account). A folder with the same name in the same place is refused.",
                properties: [
                    "name": Self.property("string", "Name of the new folder, on one line."),
                    "parent": Self.property("string", "Parent folder name (any case) or id."),
                    "account": Self.accountProperty,
                ],
                required: ["name"], write: true),
            ToolSpec(
                name: "move_note",
                description:
                    "Move a note to a folder. The note id can change after a move. Use the id in the result.",
                properties: [
                    "id": Self.idProperty,
                    "folder": Self.property("string", "Target folder name (any case) or id."),
                    "account": Self.accountProperty,
                ],
                required: ["id", "folder"], write: true),
            ToolSpec(
                name: "delete_note",
                description:
                    "Delete a note. Notes moves it to the Recently Deleted folder, where it stays for 30 days.",
                properties: ["id": Self.idProperty],
                required: ["id"], destructive: true),
            ToolSpec(
                name: "delete_folder",
                description:
                    "Delete an empty Notes folder. It is refused when the folder holds any note or any subfolder (the error says how many), for the built-in folders (Notes, Recently Deleted, Quick Notes) and for the default folder or the only folder of an account. It needs 'confirm' true, also for an empty folder. Without it, nothing is deleted. Notes may keep a deleted folder in Recently Deleted for a while.",
                properties: [
                    "folder": Self.property("string", "Folder name (any case) or id."),
                    "account": Self.accountProperty,
                    "confirm": Self.property(
                        "boolean", "Must be true to delete the folder. Without it, nothing is deleted."),
                ],
                required: ["folder"], destructive: true),
        ]
    }

    // MARK: routing

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        switch tool {
        case "list_folders": return try await listFolders(args)
        case "search_notes": return try await searchNotes(args)
        case "get_note": return try await getNote(args)
        case "get_note_attachment": return try await getAttachment(args)
        case "create_note": return try await createNote(args)
        case "append_to_note": return try await appendToNote(args)
        case "update_note": return try await updateNote(args)
        case "create_folder": return try await createFolder(args)
        case "move_note": return try await moveNote(args)
        case "delete_note": return try await deleteNote(args)
        case "delete_folder": return try await deleteFolder(args)
        default:
            throw ToolError(.unknownTool, "The notes module has no tool named '\(tool)'.")
        }
    }

    // MARK: backend access

    /// One backend call. The limit is `seconds`, or `backendTimeout` when `seconds` is nil.
    /// `onTimeout` replaces the timeout error, for example with the hint for a search.
    private func backend<T: Sendable>(
        seconds: Double? = nil, onTimeout: ToolError? = nil,
        _ operation: @escaping @Sendable (any NotesStore) async throws -> T
    ) async throws -> T {
        let store = store
        let limit = seconds ?? backendTimeout
        return try await withTimeout(
            seconds: limit, error: onTimeout ?? NotesScripts.timeoutError(seconds: limit, search: false)
        ) { try await operation(store) }
    }

    // MARK: output

    private struct FolderList: Encodable {
        let folders: [NotesFolder]
        let count: Int
    }
    private struct SearchResult: Encodable {
        let notes: [NoteSummary]
        let count: Int
        let truncated: Bool
    }
    private struct UpdateResult: Encodable {
        let action: String
        let note: NoteRef
        let previousTitle: String
        /// The old plain text below the title. Cut at the body limit.
        let previousBody: String
        let previousBodyTruncated: Bool
        /// The old HTML body. Left out when it is longer than the body limit.
        let previousHtml: String?
    }
    private struct FolderResult: Encodable {
        let action: String
        let folder: NotesFolder
        let parent: String?
    }
    private struct ActionResult: Encodable {
        let action: String
        let note: NoteRef
        /// Only for delete.
        let movedTo: String?
    }

    private struct FolderConfirmNeeded: Encodable {
        let confirmRequired = true
        let folder: NotesFolder
        let noteCount: Int
        let subfolderCount: Int
    }
    private struct FolderDeleted: Encodable {
        let action: String
        let deleted: String
        let folder: NotesFolder
    }

    static func describe(_ item: NoteSummary) -> String {
        let date = item.modified.map { ISODate.string($0) } ?? "no date"
        let name = item.name.isEmpty ? "(no title)" : item.name
        let tail = item.locked ? " [locked]" : item.snippet.isEmpty ? "" : " | \(item.snippet)"
        return "- \(item.id) | \(name) | \(item.folder) | \(item.account) | \(date)\(tail)"
    }

    // MARK: input

    /// A string argument without surrounding spaces. An empty value is an error. A NUL character is an error,
    /// because it cannot travel in argv.
    private func trimmed(_ args: Arguments, _ key: String) throws -> String? {
        guard let text = try args.string(key) else { return nil }
        guard !text.contains("\0") else { throw ToolError.invalidInput("'\(key)' must not contain a NUL character.") }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ToolError.invalidInput("'\(key)' must not be empty.") }
        return value
    }

    private func required(_ args: Arguments, _ key: String) throws -> String {
        guard let value = try trimmed(args, key) else { throw ToolError.invalidInput("'\(key)' is required.") }
        return value
    }

    /// Free text that keeps its spaces and line breaks. It must have a visible character.
    private func freeText(_ args: Arguments, _ key: String, required: Bool) throws -> String? {
        guard let text = try args.string(key) else {
            if required { throw ToolError.invalidInput("'\(key)' is required.") }
            return nil
        }
        guard !text.contains("\0") else { throw ToolError.invalidInput("'\(key)' must not contain a NUL character.") }
        if required && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolError.invalidInput("'\(key)' must not be empty.")
        }
        return text
    }

    private func noteID(_ args: Arguments) throws -> String {
        let id = try required(args, "id")
        guard NotesScripts.isValidID(id) else {
            throw ToolError(
                .invalidInput, "'id' is not a note id: '\(id.prefix(80))'.",
                fix: "Use an id from search_notes. A note id starts with x-coredata://.")
        }
        return id
    }

    // MARK: folder resolution

    private static func accountNames(_ folders: [NotesFolder]) -> [String] {
        var seen = Set<String>()
        return folders.map(\.account).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The exact account name for `query` (any case), or `NOT_FOUND`.
    static func resolveAccount(_ query: String, in folders: [NotesFolder]) throws -> String {
        let names = accountNames(folders)
        if let match = names.first(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) { return match }
        let list = names.sorted().map { "'\($0)'" }.joined(separator: ", ")
        throw ToolError(
            .notFound, "No account matches '\(query)'. Available: \(list.isEmpty ? "none" : list).",
            fix: "Use an account name from list_folders.")
    }

    /// The folder for `query` (a name in any case, or an id), inside the account when one is given.
    static func resolveFolder(_ query: String, account: String?, in folders: [NotesFolder]) throws -> NotesFolder {
        let pool = folders.filter { account == nil || $0.account == account }
        return try resolveByIdOrName(query, kind: "folder", in: pool)
    }

    /// Reads the optional 'folder' and 'account' arguments and asks Notes for the folder list only when it needs it.
    private func place(_ args: Arguments) async throws -> (folderId: String?, account: String?, folderName: String?) {
        let folderQuery = try trimmed(args, "folder")
        let accountQuery = try trimmed(args, "account")
        guard folderQuery != nil || accountQuery != nil else { return (nil, nil, nil) }
        let folders = try await backend { try await $0.folders() }
        let account = try accountQuery.map { try Self.resolveAccount($0, in: folders) }
        guard let folderQuery else { return (nil, account, nil) }
        let folder = try Self.resolveFolder(folderQuery, account: account, in: folders)
        return (folder.id, account ?? folder.account, folder.name)
    }

    // MARK: read tools

    private func listFolders(_ args: Arguments) async throws -> ToolOutput {
        let accountQuery = try trimmed(args, "account")
        let all = try await backend { try await $0.folders() }
        let account = try accountQuery.map { try Self.resolveAccount($0, in: all) }
        let folders = all.filter { account == nil || $0.account == account }
        var lines = ["\(folders.count) folders."]
        lines += folders.map {
            "- \($0.name) | \($0.account)\($0.noteCount.map { " | \($0) notes" } ?? "") | id: \($0.id)"
        }
        return try ToolOutput(
            text: lines.joined(separator: "\n"), payload: FolderList(folders: folders, count: folders.count))
    }

    private func searchNotes(_ args: Arguments) async throws -> ToolOutput {
        let text = try required(args, "query")
        let limit = try args.int("limit", default: 25, range: 1...200)
        let found = try await place(args)
        let query = NotesSearchQuery(text: text, folderId: found.folderId, account: found.account, limit: limit)
        let page = try await backend(
            onTimeout: NotesScripts.timeoutError(seconds: backendTimeout, search: true)
        ) { try await $0.search(query) }

        var lines: [String] = []
        if page.truncated {
            lines.append(
                "Showing \(page.items.count) notes. More may match. Raise 'limit' (maximum 200) or add 'folder'.")
        } else {
            lines.append("\(page.items.count) notes.")
        }
        lines += page.items.map(Self.describe)
        return try ToolOutput(
            text: lines.joined(separator: "\n"),
            payload: SearchResult(notes: page.items, count: page.items.count, truncated: page.truncated))
    }

    private func getNote(_ args: Arguments) async throws -> ToolOutput {
        let id = try noteID(args)
        let includeHTML = try args.bool("include_html") ?? false
        let note = try await backend { try await $0.note(id: id, includeHTML: includeHTML) }
        var lines = [
            "Name: \(note.name.isEmpty ? "(no title)" : note.name)",
            "Folder: \(note.folder) (\(note.account))",
        ]
        if let created = note.created { lines.append("Created: \(ISODate.string(created))") }
        if let modified = note.modified { lines.append("Modified: \(ISODate.string(modified))") }
        if !note.attachments.isEmpty {
            let list = note.attachments.map { "\($0.index). \($0.name)\($0.type.map { " (\($0))" } ?? "")" }
            lines.append("Attachments: \(list.joined(separator: ", "))")
        }
        lines += ["", note.body]
        if note.truncated { lines.append("\n(Body cut at \(NotesScripts.bodyLimit) characters.)") }
        return try ToolOutput(text: lines.joined(separator: "\n"), payload: note)
    }

    // MARK: attachments

    static let confirmAttachmentError = ToolError(
        .invalidInput, "Saving an attachment needs the user's OK, and 'confirm' is not true. Nothing was saved.",
        fix:
            "Ask the user whether applesauce may save this attachment on this Mac. If the user agrees, call again with 'confirm' true."
    )

    private func getAttachment(_ args: Arguments) async throws -> ToolOutput {
        let id = try noteID(args)
        let pick = try AttachmentPick(args)
        let confirmed = try args.bool("confirm") == true
        guard confirmed else { throw Self.confirmAttachmentError }

        AttachmentCache.sweep(root: attachmentRoot)
        let folder = try AttachmentCache.makeFolder(root: attachmentRoot)
        let limit = attachmentLimit
        do {
            let saved = try await backend {
                try await $0.saveAttachment(id: id, pick: pick, into: folder, limit: limit)
            }
            // The store checks the size. This is a second check of the file that it wrote.
            guard saved.size <= limit else {
                throw AttachmentCache.tooLarge(name: saved.name, bytes: saved.size, limit: limit)
            }
            return try await backend { _ in
                try AttachmentOutput.make(
                    file: saved.file, name: saved.name, size: saved.size, textLimit: NotesScripts.bodyLimit)
            }
        } catch {
            // Nothing stays behind for a failed call.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    // MARK: write tools

    private func createNote(_ args: Arguments) async throws -> ToolOutput {
        let title = try required(args, "title")
        let body = try freeText(args, "body", required: false)
        let html = NotesHTML.noteBody(title: title, body: body)
        try NotesHTML.checkSize(html)
        let found = try await place(args)
        let note = try await backend(seconds: writeTimeout) {
            try await $0.create(html: html, folderId: found.folderId, account: found.account)
        }
        return try ToolOutput(
            text:
                "Created note '\(note.name.isEmpty ? title : note.name)' in \(note.folder.isEmpty ? "the default folder" : note.folder).\nid: \(note.id)",
            payload: ActionResult(action: "create_note", note: note, movedTo: nil))
    }

    private func appendToNote(_ args: Arguments) async throws -> ToolOutput {
        let id = try noteID(args)
        let text = try freeText(args, "text", required: true) ?? ""
        let html = NotesHTML.fragment(text)
        try NotesHTML.checkSize(html)
        let note = try await backend(seconds: writeTimeout) { try await $0.append(id: id, html: html) }
        return try ToolOutput(
            text: "Added text to note '\(note.name)'.\nid: \(note.id)",
            payload: ActionResult(action: "append_to_note", note: note, movedTo: nil))
    }

    private func updateNote(_ args: Arguments) async throws -> ToolOutput {
        let id = try noteID(args)
        let title = try trimmed(args, "title")
        // An empty body is allowed: it clears the body and keeps the title.
        let body = try freeText(args, "body", required: false)
        guard title != nil || body != nil else {
            throw ToolError(
                .invalidInput, "Give 'title', 'body' or both. There is nothing to change.",
                fix: "Add the new title or the new body.")
        }
        if let body { try NotesHTML.checkSize(NotesHTML.noteBody(title: title ?? "", body: body)) }

        // The old note is read first: it gives the title for a body change, the HTML for a rename, and the undo data.
        let before = try await backend { try await $0.note(id: id, includeHTML: true) }
        let html: String
        if let body {
            html = NotesHTML.noteBody(title: title ?? before.name, body: body)
        } else if let title, let renamed = NotesHTML.replacingTitle(in: before.html ?? "", with: title) {
            html = renamed
        } else {
            throw ToolError(
                .invalidInput,
                "applesauce cannot find the title line in the HTML of this note, so it cannot rename it.",
                fix: "Give 'body' too, to replace the whole note, or rename the note in Notes.")
        }
        try NotesHTML.checkSize(html)
        let note = try await backend(seconds: writeTimeout) { try await $0.replaceBody(id: id, html: html) }

        let previousBody = NotesHTML.bodyWithoutTitle(before.body, title: before.name)
        let previousHtml = (before.html?.count ?? 0) <= NotesScripts.bodyLimit ? before.html : nil
        var lines = ["Updated note '\(note.name.isEmpty ? before.name : note.name)'."]
        if let title { lines.append("Title: '\(before.name)' became '\(title)'.") }
        if body != nil { lines.append("The body was replaced. The old text is in 'previous_body'.") }
        if before.truncated { lines.append("The old text was cut at \(NotesScripts.bodyLimit) characters.") }
        lines.append("id: \(note.id)")
        return try ToolOutput(
            text: lines.joined(separator: "\n"),
            payload: UpdateResult(
                action: "update_note", note: note, previousTitle: before.name, previousBody: previousBody,
                previousBodyTruncated: before.truncated, previousHtml: previousHtml))
    }

    private func createFolder(_ args: Arguments) async throws -> ToolOutput {
        let name = try required(args, "name")
        guard !name.contains(where: \.isNewline) else {
            throw ToolError.invalidInput("'name' must be on one line.")
        }
        let parentQuery = try trimmed(args, "parent")
        let accountQuery = try trimmed(args, "account")
        var parent: NotesFolder?
        var account: String?
        if parentQuery != nil || accountQuery != nil {
            let folders = try await backend { try await $0.folders() }
            account = try accountQuery.map { try Self.resolveAccount($0, in: folders) }
            if let parentQuery {
                parent = try Self.resolveFolder(parentQuery, account: account, in: folders)
                account = parent?.account
            }
        }
        let parentId = parent?.id
        let wanted = account
        let folder = try await backend(seconds: writeTimeout) {
            try await $0.createFolder(name: name, parentId: parentId, account: wanted)
        }
        let place = parent.map { " inside '\($0.name)'" } ?? ""
        return try ToolOutput(
            text: "Created folder '\(folder.name)'\(place) in \(folder.account).\nid: \(folder.id)",
            payload: FolderResult(action: "create_folder", folder: folder, parent: parent?.name))
    }

    private func moveNote(_ args: Arguments) async throws -> ToolOutput {
        let id = try noteID(args)
        _ = try required(args, "folder")
        let found = try await place(args)
        guard let folderId = found.folderId, let folderName = found.folderName else {
            throw ToolError.invalidInput("'folder' is required.")
        }
        let note = try await backend(seconds: writeTimeout) { try await $0.move(id: id, folderId: folderId) }
        let target = note.folder.isEmpty ? folderName : note.folder
        return try ToolOutput(
            text: "Moved note '\(note.name)' to '\(target)'. Use this id from now on: \(note.id)",
            payload: ActionResult(action: "move_note", note: note, movedTo: target))
    }

    private func deleteNote(_ args: Arguments) async throws -> ToolOutput {
        let id = try noteID(args)
        let note = try await backend(seconds: writeTimeout) { try await $0.delete(id: id) }
        return try ToolOutput(
            text: "Deleted note '\(note.name)'. Notes moved it to Recently Deleted, where it stays for 30 days.",
            payload: ActionResult(action: "delete_note", note: note, movedTo: "Recently Deleted"))
    }

    /// Names that Notes uses for its own folders. Only a top-level folder with one of these names counts.
    static let builtInFolderNames: Set<String> = ["notes", "recently deleted", "quick notes"]

    private func deleteFolder(_ args: Arguments) async throws -> ToolOutput {
        let query = try required(args, "folder")
        let accountQuery = try trimmed(args, "account")
        let confirmed = try args.bool("confirm") == true

        let folders = try await backend { try await $0.folders() }
        let account = try accountQuery.map { try Self.resolveAccount($0, in: folders) }
        let found = try Self.resolveFolder(query, account: account, in: folders)
        let id = found.id
        let details = try await backend { try await $0.folderDetails(id: id) }
        let name = details.folder.name
        if details.topLevel && Self.builtInFolderNames.contains(name.lowercased()) {
            throw ToolError(
                .invalidInput, "'\(name)' is a built-in Notes folder. Nothing was deleted.",
                fix: "Built-in folders cannot be deleted.")
        }
        if details.isDefault || (details.topLevel && details.topLevelFolderCount <= 1) {
            throw ToolError(
                .invalidInput,
                "'\(name)' is the \(details.isDefault ? "default folder" : "only folder") of the account '\(details.folder.account)'. Nothing was deleted.",
                fix: "Keep this folder. Notes needs a folder to put new notes in.")
        }
        if details.noteCount > 0 || details.subfolderCount > 0 {
            throw ToolError(
                .invalidInput,
                "'\(name)' holds \(details.noteCount) notes and \(details.subfolderCount) subfolders. Nothing was deleted.",
                fix: "Only an empty folder can be deleted. Move or delete the notes and subfolders first.")
        }
        if !confirmed {
            return try ToolOutput(
                text:
                    "Nothing deleted. The folder '\(name)' in \(details.folder.account) is empty (0 notes, 0 subfolders). Ask the user, then call again with 'confirm' true.",
                payload: FolderConfirmNeeded(folder: details.folder, noteCount: 0, subfolderCount: 0))
        }
        try await backend(seconds: writeTimeout) { try await $0.deleteFolder(id: id) }
        return try ToolOutput(
            text:
                "Deleted folder '\(name)' from \(details.folder.account). It was empty. To undo, call create_folder with the same name and account (add 'parent' for a nested folder).",
            payload: FolderDeleted(action: "delete_folder", deleted: id, folder: details.folder))
    }
}
