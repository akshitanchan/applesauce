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
    /// More than one attachment has the name. Notes could not save an attachment to a file.
    static let ambiguousNumber = 1004
    static let exportNumber = 1006
    /// A folder with the same name is already there.
    static let duplicateNumber = 1007
    /// A folder to delete still holds a note or a folder.
    static let notEmptyNumber = 1008

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

        -- Notes keeps a deleted folder in `folders of <parent>` for some time, but `folder id` no longer finds it.
        on folderExists(fldId)
            try
                tell application "Notes" to set probe to name of folder id fldId
                return true
            on error
                return false
            end try
        end folderExists

        -- Ids and names of the folders directly in an account or folder, without deleted folders.
        on liveChildren(container_)
            tell application "Notes"
                set allIds to id of folders of container_
                if allIds is {} then return {{}, {}}
                set allNames to name of folders of container_
            end tell
            set liveIds to {}
            set liveNames to {}
            repeat with i from 1 to count of allIds
                if my folderExists(item i of allIds) then
                    set end of liveIds to item i of allIds
                    set end of liveNames to item i of allNames
                end if
            end repeat
            return {liveIds, liveNames}
        end liveChildren

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
            set children to my liveChildren(container_)
            set subIds to item 1 of children
            if subIds is {} then return
            set subNames to item 2 of children
            tell application "Notes" to set nestedCount to count of (folders of folders of container_)
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
    /// Output (one record): id, name, folder, account, created, modified, attachment names (separated by character 29),
    /// plain text, html.
    /// A locked note fails with error 1002 before any text is read.
    /// The plain text is cut at one character more than the limit, so the caller can see the cut.
    static let note =
        prelude + """


            on run argv
                set nt to my findNote(item 1 of argv)
                -- One event for every property is about twice as fast as reading them one by one.
                -- Notes gives no text for a locked note, and the lock is checked before any field is used.
                tell application "Notes" to set props to properties of nt
                tell application "Notes" to set isLocked to password protected of props
                if isLocked then my failWith(1002, "The note is locked (password protected).")
                tell application "Notes"
                    set noteId to id of props
                    set noteName to name of props
                    set createdAt to creation date of props
                    set modifiedAt to modification date of props
                    set plainBody to plaintext of props
                    set html to ""
                    if (item 2 of argv) is "true" then set html to body of props
                end tell
                set attNames to {}
                try
                    tell application "Notes" to set attNames to name of attachments of nt
                end try
                set attList to {}
                repeat with attName in attNames
                    set shownName to my clean(contents of attName)
                    if shownName is "" then set shownName to "(no name)"
                    set end of attList to shownName
                end repeat
                set place to my placeOf(nt)
                return noteId & fs & my clean(noteName) & fs & my clean(item 1 of place) & fs & my clean(item 2 of place) & fs & my formatDate(createdAt) & fs & my formatDate(modifiedAt) & fs & my joinList(attList, character id 29) & fs & my clean(my clip(plainBody, \(bodyLimit + 1))) & fs & my clean(html)
            end run
            """

    /// argv: note id, mode (`index` or `name`), the index or the name, the file to write.
    /// Output: the attachment name. Error numbers: 1001 no such attachment, 1002 locked note, 1004 the name is not unique,
    /// 1006 Notes could not save the attachment (drawings, scans, tables and links cannot be saved).
    /// It only saves a file. It changes nothing in Notes.
    static let saveAttachment =
        prelude + """


            on run argv
                set nt to my findNote(item 1 of argv)
                my failIfLocked(nt)
                set mode to item 2 of argv
                set wanted to item 3 of argv
                tell application "Notes"
                    set atts to attachments of nt
                    set total to count of atts
                    set slot to 0
                    if mode is "index" then
                        set slot to wanted as integer
                        if slot < 1 or slot > total then my failWith(1001, "The note has " & total & " attachments, and none is number " & wanted & ".")
                    else
                        repeat with i from 1 to total
                            if (name of item i of atts) is wanted then
                                if slot is not 0 then my failWith(1004, "More than one attachment is named '" & wanted & "'.")
                                set slot to i
                            end if
                        end repeat
                        if slot is 0 then my failWith(1001, "The note has no attachment named '" & wanted & "'.")
                    end if
                    set att to item slot of atts
                    set attName to name of att
                end tell
                set shownName to my clean(attName)
                if shownName is "" then set shownName to "attachment " & slot
                try
                    tell application "Notes" to save att in (POSIX file (item 4 of argv))
                on error errMsg
                    my failWith(1006, "Notes could not save the attachment '" & shownName & "' (" & errMsg & ").")
                end try
                return shownName
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

    /// argv: note id, html. Output: one header record. A locked note fails with error 1002.
    /// It sets the whole `body of note`, so the caller sends the full new HTML (title line included).
    static let replace =
        prelude + """


            on run argv
                set nt to my findNote(item 1 of argv)
                my failIfLocked(nt)
                tell application "Notes" to set body of nt to (item 2 of argv)
                return my header(nt)
            end run
            """

    /// argv: folder name, parent folder id or `none`, account name or `none`. Output: one folder record
    /// (id, name, account, note count 0). With a parent, the folder goes inside it. Otherwise it goes to the account
    /// (or the default account). `folders of <account or folder>` lists the direct children only, so the script
    /// compares the name with those. AppleScript compares text without regard to case.
    /// Error numbers: 1001 no such account, 1007 a folder with this name is already there.
    static let createFolder =
        prelude + """


            on run argv
                set folderName to item 1 of argv
                set parentSpec to item 2 of argv
                set acctSpec to item 3 of argv
                if parentSpec is not "\(none)" then
                    set holder to my findFolder(parentSpec)
                    set acctName to item 2 of my placeOf(holder)
                else
                    try
                        tell application "Notes"
                            if acctSpec is not "\(none)" then
                                set holder to account acctSpec
                            else
                                set holder to default account
                            end if
                            set acctName to name of holder
                        end tell
                    on error errMsg number errNum
                        if errNum is -1728 or errNum is -1719 then my failWith(1001, "No account '" & acctSpec & "'.")
                        error errMsg number errNum
                    end try
                end if
                set siblingNames to item 2 of my liveChildren(holder)
                repeat with siblingName in siblingNames
                    if (contents of siblingName) is folderName then my failWith(1007, "A folder named '" & folderName & "' is already there.")
                end repeat
                tell application "Notes"
                    set newFolder to make new folder at holder with properties {name:folderName}
                    set newId to id of newFolder
                    set newName to name of newFolder
                end tell
                return newId & fs & my clean(newName) & fs & my clean(acctName) & fs & "0"
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

    /// argv: folder id. Output: one record: id, name, account, notes in the folder, folders in the folder,
    /// top level (`true` or `false`), is the default folder of its account, top-level folders of the account.
    /// It only reads.
    static let folderDetails =
        prelude + """


            on run argv
                set fld to my findFolder(item 1 of argv)
                tell application "Notes"
                    set fldId to id of fld
                    set fldName to name of fld
                    set noteTotal to count of notes of fld
                    set holder to container of fld
                    set isTop to ((class of holder) is account)
                    repeat while (class of holder) is folder
                        set holder to container of holder
                    end repeat
                    set acctName to name of holder
                    set defaultId to ""
                    try
                        set defaultId to id of default folder of holder
                    end try
                end tell
                set subTotal to count of item 1 of my liveChildren(fld)
                set topTotal to count of item 1 of my liveChildren(holder)
                return fldId & fs & my clean(fldName) & fs & my clean(acctName) & fs & (noteTotal as text) & fs & (subTotal as text) & fs & (isTop as text) & fs & ((defaultId is fldId) as text) & fs & (topTotal as text)
            end run
            """

    /// argv: folder id. Output: `ok`, after the folder is gone (or after 5 s). It reads the counts again and stops with error 1008 when the folder holds
    /// a note or a folder, so a note that arrived after the check is never deleted with it.
    static let deleteFolder =
        prelude + """


            on run argv
                set fld to my findFolder(item 1 of argv)
                tell application "Notes" to set noteTotal to count of notes of fld
                set subTotal to count of item 1 of my liveChildren(fld)
                if noteTotal > 0 or subTotal > 0 then my failWith(1008, "The folder holds " & noteTotal & " notes and " & subTotal & " subfolders.")
                set fldId to id of fld
                tell application "Notes" to delete fld
                -- Notes removes the folder a moment later. Wait for it (at most 5 s), so that a delete of the
                -- parent folder right after this one sees the parent as empty.
                repeat 20 times
                    try
                        tell application "Notes" to set probe to name of folder id fldId
                    on error
                        exit repeat
                    end try
                    delay 0.25
                end repeat
                return "ok"
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
                throw scriptError(error)
            default:
                throw error
            }
        }
    }

    /// Turns an error that a script raised on purpose into its tool error. Other errors stay as they are.
    static func scriptError(_ error: ToolError) -> ToolError {
        let message = cleanMessage(error.message)
        switch AppleScript.errorNumber(in: error.message) {
        case notFoundNumber:
            return ToolError(
                .notFound, message,
                fix: message.contains("attachment")
                    ? "Check the attachments with get_note."
                    : "Check the id with search_notes, and the folder with list_folders.")
        case lockedNumber:
            return lockedError()
        case ambiguousNumber:
            return ToolError(.ambiguous, message, fix: "Give 'index' instead of 'name'.")
        case duplicateNumber:
            return ToolError(
                .invalidInput, message,
                fix: "Use another name, or use the folder that exists. list_folders shows its id.")
        case notEmptyNumber:
            return ToolError(
                .invalidInput, message,
                fix: "Only an empty folder can be deleted. Nothing was deleted. Move or delete what it holds first.")
        case exportNumber:
            return ToolError(
                .invalidInput, message,
                fix:
                    "Drawings, scans, tables and links cannot be saved. Open the note in Notes and export the item there."
            )
        default:
            return error
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
        if let match = message.firstMatch(of: #/\s*\((1001|1002|1004|1006|1007|1008)\)\s*$/#) {
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

    static func createFolderArguments(name: String, parentId: String?, account: String?) -> [String] {
        [name, parentId ?? none, account ?? none]
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

    static func parseFolderDetails(_ text: String) -> FolderDetails? {
        guard let fields = records(text).first, fields.count >= 8, !fields[0].isEmpty,
            let notes = Int(fields[3]), let subfolders = Int(fields[4]), let top = Int(fields[7])
        else { return nil }
        return FolderDetails(
            folder: NotesFolder(id: fields[0], name: fields[1], account: fields[2], noteCount: notes),
            noteCount: notes, subfolderCount: subfolders, topLevel: fields[5] == "true",
            isDefault: fields[6] == "true", topLevelFolderCount: top)
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
        let fields = text.split(separator: fieldSeparator, maxSplits: 8, omittingEmptySubsequences: false).map(
            String.init)
        guard fields.count == 9, !fields[0].isEmpty else { return nil }
        let (body, truncated) = limitBody(fields[7])
        let attachments = fields[6].split(separator: "\u{1D}", omittingEmptySubsequences: false).enumerated().map {
            NoteAttachment(index: $0.offset + 1, name: String($0.element))
        }
        return NotesNote(
            id: fields[0], name: fields[1], folder: fields[2], account: fields[3], created: parseDate(fields[4]),
            modified: parseDate(fields[5]), body: body, truncated: truncated, html: includeHTML ? fields[8] : nil,
            attachments: fields[6].isEmpty ? [] : attachments)
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
