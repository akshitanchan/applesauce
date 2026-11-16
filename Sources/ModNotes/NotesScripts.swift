import AppleSauceCore
import Foundation

/// The AppleScript for Notes, and the code that builds its arguments and reads its output.
///
/// Rules:
/// - User values go only in `argv`. They never enter the script text.
/// - Scripts print records. Fields are separated by character 31, records by character 30.
///   The scripts remove both characters from every value they print.
enum NotesScripts {
    /// Stands for "no value" in `argv`, because an empty argument may not survive `osascript`.
    static let none = "<none>"

    static let fieldSeparator: Character = "\u{1F}"
    static let recordSeparator: Character = "\u{1E}"

    /// Error numbers that the scripts raise on purpose. `run` turns them into tool errors.
    static let notFoundNumber = 1001
    static let lockedNumber = 1002

    /// Longest plain text body that a tool returns, in characters.
    static let bodyLimit = 100_000
    /// Longest snippet in a search result, in characters.
    static let snippetLimit = 200

    // MARK: shared handlers

    /// Handlers that every script uses.
    ///
    /// Run against a real Notes: `folders of <account>` lists top-level folders and `folders of <folder>` the
    /// nested ones. The walk reads both levels and skips ids it has seen.
    /// `note id <text>` finds a note by the id text that `id of note` gives.
    /// A note in a nested folder has no `container` (Notes answers -1728, or `missing value` in a bulk read),
    /// so its folder is found through each folder's note ids instead.
    static let prelude = """
        property fs : character id 31
        property rs : character id 30

        on failWith(code, reason)
            error reason number code
        end failWith

        -- Text without the separator characters. Missing values become "".
        on clean(value)
            if value is missing value then return ""
            set t to value as text
            set saved to AppleScript's text item delimiters
            set AppleScript's text item delimiters to {fs, rs}
            set parts to text items of t
            set AppleScript's text item delimiters to ""
            set t to parts as text
            set AppleScript's text item delimiters to saved
            return t
        end clean

        on clip(value, maxLength)
            if value is missing value then return ""
            set t to value as text
            if (count of t) > maxLength then set t to text 1 thru maxLength of t
            return t
        end clip

        on pad2(n)
            set t to (n as integer) as text
            if (count of t) < 2 then set t to "0" & t
            return t
        end pad2

        on formatDate(d)
            if d is missing value then return ""
            return ((year of d) as text) & "-" & my pad2(month of d as integer) & "-" & my pad2(day of d) & " " & my pad2(hours of d) & ":" & my pad2(minutes of d) & ":" & my pad2(seconds of d)
        end formatDate

        on joinList(items_, separator)
            set AppleScript's text item delimiters to separator
            set joined to items_ as text
            set AppleScript's text item delimiters to ""
            return joined
        end joinList

        -- Every folder, read in bulk: ids, names and account names in three parallel lists.
        -- Nested folders cost one more read for each level.
        on folderTable()
            script table
                property folderIds : {}
                property folderNames : {}
                property folderAccts : {}
            end script
            tell application "Notes"
                repeat with acct in accounts
                    set acctRef to contents of acct
                    my collectFolders(acctRef, name of acctRef, table)
                end repeat
            end tell
            return table
        end folderTable

        on collectFolders(container_, acctName, table)
            tell application "Notes"
                set subIds to id of folders of container_
                if subIds is {} then return
                set subNames to name of folders of container_
                set nestedCount to count of (folders of folders of container_)
            end tell
            repeat with i from 1 to count of subIds
                set fldId to item i of subIds
                if table's folderIds does not contain fldId then
                    set end of table's folderIds to fldId
                    set end of table's folderNames to item i of subNames
                    set end of table's folderAccts to acctName
                    if nestedCount > 0 then
                        tell application "Notes" to set child to folder id fldId
                        my collectFolders(child, acctName, table)
                    end if
                end if
            end repeat
        end collectFolders

        on findFolder(folderId)
            try
                tell application "Notes"
                    set fld to folder id folderId
                    set probe to name of fld
                    return fld
                end tell
            on error errMsg number errNum
                if errNum is not -1728 and errNum is not -1719 then error errMsg number errNum
            end try
            my failWith(1001, "No folder with id '" & folderId & "'.")
        end findFolder

        -- Position of a value in a list, or 0.
        on indexOf(value, items_)
            repeat with i from 1 to count of items_
                if item i of items_ is value then return i
            end repeat
            return 0
        end indexOf

        on findNote(noteId)
            try
                tell application "Notes"
                    set nt to note id noteId
                    set probe to name of nt
                    return nt
                end tell
            on error errMsg number errNum
                if errNum is not -1728 and errNum is not -1719 then error errMsg number errNum
            end try
            my failWith(1001, "No note with id '" & noteId & "'.")
        end findNote

        on failIfLocked(nt)
            tell application "Notes" to set isLocked to password protected of nt
            if isLocked then my failWith(1002, "The note is locked (password protected).")
        end failIfLocked

        -- The note ids of every folder, read once: one event for each folder.
        -- Notes gives no container for a note in a nested folder, so this is how such a note finds its folder.
        on folderNoteIds(table)
            script idTable
                property noteIdLists : {}
            end script
            repeat with fldId in table's folderIds
                set fldNotes to {}
                try
                    tell application "Notes" to set fldNotes to id of notes of folder id (contents of fldId)
                end try
                set end of idTable's noteIdLists to fldNotes
            end repeat
            return idTable
        end folderNoteIds

        -- {folder name, account name} for a note id from folderNoteIds, or {"", ""}.
        on placeFromLists(noteId, table, idTable)
            repeat with i from 1 to count of table's folderIds
                if (item i of idTable's noteIdLists) contains noteId then
                    return {item i of table's folderNames, item i of table's folderAccts}
                end if
            end repeat
            return {"", ""}
        end placeFromLists

        -- {folder name, account name} of a note, or of a folder (then the folder is its own place).
        on placeOf(item_)
            tell application "Notes" to set isFolder to (class of item_) is folder
            if not isFolder then
                try
                    tell application "Notes" to set probe to container of item_
                on error errMsg number errNum
                    if errNum is not -1728 then error errMsg number errNum
                    -- A note in a nested folder has no container. Find its folder by its id.
                    set table to my folderTable()
                    tell application "Notes" to set noteId to id of item_
                    return my placeFromLists(noteId, table, my folderNoteIds(table))
                end try
            end if
            tell application "Notes"
                if isFolder then
                    set holder to item_
                else
                    set holder to container of item_
                end if
                set folderName to name of holder
                repeat while (class of holder) is folder
                    set holder to container of holder
                end repeat
                set acctName to name of holder
            end tell
            return {folderName, acctName}
        end placeOf

        -- One record: id, name, folder, account.
        on header(nt)
            tell application "Notes"
                set noteId to id of nt
                set noteName to name of nt
            end tell
            set place to my placeOf(nt)
            return noteId & fs & my clean(noteName) & fs & my clean(item 1 of place) & fs & my clean(item 2 of place)
        end header
        """

    // MARK: reads

    /// Output records: folder id, folder name, account name, note count.
    static let folders =
        prelude + """


            on run argv
                set table to my folderTable()
                -- Fast path: count from one bulk read of every note's container.
                -- A note in a nested folder has no container, so then each folder is counted on its own.
                tell application "Notes" to set holders to id of container of every note
                script counted
                    property holderIds : holders
                end script
                set exact to counted's holderIds does not contain missing value
                set out to {}
                repeat with i from 1 to count of table's folderIds
                    set fldId to item i of table's folderIds
                    set noteCount to 0
                    if exact then
                        repeat with holder in counted's holderIds
                            if contents of holder is fldId then set noteCount to noteCount + 1
                        end repeat
                    else
                        try
                            tell application "Notes" to set noteCount to count of notes of folder id fldId
                        end try
                    end if
                    set end of out to fldId & fs & my clean(item i of table's folderNames) & fs & my clean(item i of table's folderAccts) & fs & (noteCount as text)
                end repeat
                return my joinList(out, rs)
            end run
            """

    /// argv: query, folder id or `none`, account name or `none`.
    /// Output records: id, name, folder, account, modified, locked, kind (`name` or `body`), snippet.
    ///
    /// A `whose` filter costs Notes over a second, and Notes runs it again for each property read.
    /// So the script reads each property of every note in scope once, in bulk, and filters here.
    /// AppleScript `contains` ignores case. Notes gives no text for a locked note, and the script drops it anyway.
    static let search =
        prelude + """


            on run argv
                set q to item 1 of argv
                set wantedFolder to item 2 of argv
                set wantedAccount to item 3 of argv
                script cols
                    property noteIds : {}
                    property noteNames : {}
                    property noteMods : {}
                    property noteLocks : {}
                    property noteTexts : {}
                    property noteHolders : {}
                end script
                set table to missing value
                set fixedPlace to missing value
                if wantedFolder is not "\(none)" then
                    set fld to my findFolder(wantedFolder)
                    set fixedPlace to my placeOf(fld)
                    tell application "Notes" to set scope to a reference to (notes of fld)
                else if wantedAccount is not "\(none)" then
                    try
                        tell application "Notes" to set acctRef to account wantedAccount
                    on error errMsg number errNum
                        if errNum is -1728 or errNum is -1719 then return ""
                        error errMsg number errNum
                    end try
                    tell application "Notes" to set scope to a reference to (notes of acctRef)
                else
                    tell application "Notes" to set scope to a reference to every note
                end if
                tell application "Notes"
                    set cols's noteIds to id of scope
                    set cols's noteNames to name of scope
                    set cols's noteMods to modification date of scope
                    set cols's noteLocks to password protected of scope
                    set cols's noteTexts to plaintext of scope
                    if fixedPlace is missing value then set cols's noteHolders to id of container of scope
                end tell
                if fixedPlace is missing value then set table to my folderTable()
                set noteIdTable to missing value
                set out to {}
                repeat with i from 1 to count of cols's noteIds
                    set isLocked to item i of cols's noteLocks
                    set noteName to item i of cols's noteNames
                    set noteText to ""
                    if not isLocked then set noteText to my clip(item i of cols's noteTexts, 600)
                    set matchKind to ""
                    if noteName contains q then
                        set matchKind to "name"
                    else if not isLocked and (item i of cols's noteTexts) contains q then
                        set matchKind to "body"
                    end if
                    if matchKind is not "" then
                        if fixedPlace is missing value then
                            set place to {"", ""}
                            set holder to item i of cols's noteHolders
                            set k to 0
                            if holder is not missing value then set k to my indexOf(holder, table's folderIds)
                            if k > 0 then
                                set place to {item k of table's folderNames, item k of table's folderAccts}
                            else
                                -- A note in a nested folder has no container. Read each folder's notes once.
                                if noteIdTable is missing value then set noteIdTable to my folderNoteIds(table)
                                set place to my placeFromLists(item i of cols's noteIds, table, noteIdTable)
                            end if
                        else
                            set place to fixedPlace
                        end if
                        set end of out to (item i of cols's noteIds) & fs & my clean(noteName) & fs & my clean(item 1 of place) & fs & my clean(item 2 of place) & fs & my formatDate(item i of cols's noteMods) & fs & (isLocked as text) & fs & matchKind & fs & my clean(noteText)
                    end if
                end repeat
                return my joinList(out, rs)
            end run
            """

    /// argv: note id, include html (`true` or `false`).
    /// Output (one record): id, name, folder, account, created, modified, plain text, html.
    /// A locked note fails with error 1002 before any text is read.
    /// The plain text is cut at one character more than the limit, so the caller can see the cut.
    static let note =
        prelude + """


            on run argv
                set nt to my findNote(item 1 of argv)
                my failIfLocked(nt)
                tell application "Notes"
                    set noteId to id of nt
                    set noteName to name of nt
                    set createdAt to creation date of nt
                    set modifiedAt to modification date of nt
                    set plainBody to plaintext of nt
                    set html to ""
                    if (item 2 of argv) is "true" then set html to body of nt
                end tell
                set place to my placeOf(nt)
                return noteId & fs & my clean(noteName) & fs & my clean(item 1 of place) & fs & my clean(item 2 of place) & fs & my formatDate(createdAt) & fs & my formatDate(modifiedAt) & fs & my clean(my clip(plainBody, \(bodyLimit + 1))) & fs & my clean(html)
            end run
            """

    // MARK: writes

    /// argv: html body, folder id or `none`, account name or `none`. Output: one header record.
    /// Without a folder, the note goes to the default folder of the account, or of Notes.
    /// `make new note at <folder> with properties {body:...}` makes the first line the name.
    static let create =
        prelude + """


            on run argv
                set target to missing value
                if (item 2 of argv) is not "\(none)" then
                    set target to my findFolder(item 2 of argv)
                else if (item 3 of argv) is not "\(none)" then
                    tell application "Notes"
                        set acctRef to account (item 3 of argv)
                        try
                            set target to default folder of acctRef
                        on error
                            set target to first folder of acctRef
                        end try
                    end tell
                end if
                tell application "Notes"
                    if target is missing value then
                        set nt to make new note with properties {body:(item 1 of argv)}
                    else
                        set nt to make new note at target with properties {body:(item 1 of argv)}
                    end if
                end tell
                return my header(nt)
            end run
            """

    /// argv: note id, html to add. Output: one header record. A locked note fails with error 1002.
    /// `body of note` is a plain HTML fragment (no `html` or `body` wrapper), so adding text at the end
    /// is valid. Setting the body writes the whole note again.
    static let append =
        prelude + """


            on run argv
                set nt to my findNote(item 1 of argv)
                my failIfLocked(nt)
                tell application "Notes"
                    set oldBody to body of nt
                    set body of nt to oldBody & (item 2 of argv)
                end tell
                return my header(nt)
            end run
            """

    /// argv: note id, folder id. Output: one header record.
    /// `move` returns nothing, and the note keeps its id, so the note is found again by that id.
    /// If the new header cannot be read, the old id and the folder name are returned.
    static let move =
        prelude + """


            on run argv
                set nt to my findNote(item 1 of argv)
                set target to my findFolder(item 2 of argv)
                tell application "Notes"
                    set oldId to id of nt
                    set targetName to name of target
                    move nt to target
                end tell
                try
                    return my header(my findNote(oldId))
                end try
                return oldId & fs & fs & my clean(targetName) & fs
            end run
            """

    /// argv: note id. Output: one header record, read before the delete.
    /// `delete note` moves the note to Recently Deleted.
    static let delete =
        prelude + """


            on run argv
                set nt to my findNote(item 1 of argv)
                set info to my header(nt)
                tell application "Notes" to delete nt
                return info
            end run
            """

    // MARK: running

    /// The error for a script that ran too long. A search gets a hint to use a folder.
    static func timeoutError(seconds: Double, search: Bool) -> ToolError {
        ToolError(
            .timeout, "Notes took longer than \(Int(seconds)) seconds.",
            fix: search
                ? "Large libraries are slow to search. Add 'folder' (and 'account') to search fewer notes, or use a more specific query."
                : "Check that Notes is not stuck on a dialog, then try again.")
    }

    /// Runs a script. The script's own error numbers become tool errors: 1001 `NOT_FOUND`, 1002 locked note.
    static func run(_ script: String, _ arguments: [String], timeout: Double, search: Bool = false) async throws
        -> String
    {
        do {
            return try await AppleScript.run(
                script, arguments: arguments, permission: .automationNotes, appName: "Notes", timeout: timeout)
        } catch let error as ToolError {
            switch error.code {
            case .timeout:
                throw timeoutError(seconds: timeout, search: search)
            case .internalError:
                switch AppleScript.errorNumber(in: error.message) {
                case notFoundNumber:
                    throw ToolError(
                        .notFound, cleanMessage(error.message),
                        fix: "Check the id with search_notes, and the folder with list_folders.")
                case lockedNumber:
                    throw lockedError()
                default:
                    throw error
                }
            default:
                throw error
            }
        }
    }

    static func lockedError() -> ToolError {
        ToolError(
            .permissionDenied,
            "The note is locked (password protected). applesauce does not read or change locked notes.",
            fix: "Remove the lock in Notes first, or use another note.")
    }

    /// `1:5: execution error: No note. (1001)` becomes `No note.`
    static func cleanMessage(_ text: String) -> String {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "execution error: ") { message = String(message[range.upperBound...]) }
        if let match = message.firstMatch(of: #/\s*\((1001|1002)\)\s*$/#) {
            message = String(message[..<match.range.lowerBound])
        }
        return message
    }

    // MARK: arguments

    /// A note id looks like `x-coredata://<store>/ICNote/p123`. This checks the shape only, not that the note exists.
    static func isValidID(_ id: String) -> Bool {
        let prefix = "x-coredata://"
        guard id.hasPrefix(prefix), id.count > prefix.count, id.count <= 500 else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value < 127 }
    }

    static func searchArguments(_ query: NotesSearchQuery) -> [String] {
        [query.text, query.folderId ?? none, query.account ?? none]
    }

    static func noteArguments(id: String, includeHTML: Bool) -> [String] {
        [id, includeHTML ? "true" : "false"]
    }

    static func createArguments(html: String, folderId: String?, account: String?) -> [String] {
        [html, folderId ?? none, account ?? none]
    }

    // MARK: output

    static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    static func parseDate(_ text: String) -> Date? {
        text.isEmpty ? nil : dateFormatter().date(from: text)
    }

    private static func records(_ text: String) -> [[String]] {
        text.split(separator: recordSeparator).map {
            $0.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        }
    }

    static func parseFolders(_ text: String) -> [NotesFolder] {
        records(text).compactMap { fields in
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            return NotesFolder(
                id: fields[0], name: fields[1], account: fields[2], noteCount: fields.count > 3 ? Int(fields[3]) : nil)
        }
    }

    /// One row of the search output, before the sort and the limit.
    struct SearchRecord: Equatable {
        let summary: NoteSummary
        let titleMatch: Bool
    }

    static func parseSearch(_ text: String) -> [SearchRecord] {
        records(text).compactMap { fields in
            guard fields.count >= 8, !fields[0].isEmpty else { return nil }
            let locked = fields[5] == "true"
            return SearchRecord(
                summary: NoteSummary(
                    id: fields[0], name: fields[1], folder: fields[2], account: fields[3],
                    modified: parseDate(fields[4]), locked: locked,
                    snippet: locked ? "" : snippet(fields[7], name: fields[1])),
                titleMatch: fields[6] == "name")
        }
    }

    /// Whitespace runs become one space. A leading copy of the name is dropped, because Notes starts the text with it.
    /// The result has at most `snippetLimit` characters.
    static func snippet(_ text: String, name: String) -> String {
        var collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let title = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !title.isEmpty, collapsed.hasPrefix(title) {
            collapsed = String(collapsed.dropFirst(title.count)).trimmingCharacters(in: .whitespaces)
        }
        return String(collapsed.prefix(snippetLimit))
    }

    /// Removes repeated ids (a title match wins), puts title matches first, newest first inside each group,
    /// and cuts at `limit`.
    static func finish(_ records: [SearchRecord], limit: Int) -> NotesSearchPage {
        var seen = Set<String>()
        var titles: [NoteSummary] = []
        var bodies: [NoteSummary] = []
        for record in records where record.titleMatch && seen.insert(record.summary.id).inserted {
            titles.append(record.summary)
        }
        for record in records where !record.titleMatch && seen.insert(record.summary.id).inserted {
            bodies.append(record.summary)
        }
        func newestFirst(_ items: [NoteSummary]) -> [NoteSummary] {
            items.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        let all = newestFirst(titles) + newestFirst(bodies)
        return NotesSearchPage(items: Array(all.prefix(limit)), truncated: all.count > limit)
    }

    /// Reads the output of the `note` script.
    static func parseNote(_ text: String, includeHTML: Bool) -> NotesNote? {
        let fields = text.split(separator: fieldSeparator, maxSplits: 7, omittingEmptySubsequences: false).map(
            String.init)
        guard fields.count == 8, !fields[0].isEmpty else { return nil }
        let (body, truncated) = limitBody(fields[6])
        return NotesNote(
            id: fields[0], name: fields[1], folder: fields[2], account: fields[3], created: parseDate(fields[4]),
            modified: parseDate(fields[5]), body: body, truncated: truncated, html: includeHTML ? fields[7] : nil)
    }

    /// Reads a header record: id, name, folder, account.
    static func parseRef(_ text: String) -> NoteRef? {
        let fields = text.split(separator: fieldSeparator, maxSplits: 3, omittingEmptySubsequences: false).map(
            String.init)
        guard fields.count == 4, !fields[0].isEmpty else { return nil }
        return NoteRef(id: fields[0], name: fields[1], folder: fields[2], account: fields[3])
    }

    static func limitBody(_ text: String, limit: Int = bodyLimit) -> (String, Bool) {
        text.count > limit ? (String(text.prefix(limit)), true) : (text, false)
    }
}
