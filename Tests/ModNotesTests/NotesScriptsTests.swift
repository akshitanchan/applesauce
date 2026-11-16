import AppleSauceCore
import Foundation
import Testing

@testable import ModNotes

@Suite struct NotesScriptsTests {
    let fs = String(NotesScripts.fieldSeparator)
    let rs = String(NotesScripts.recordSeparator)

    // MARK: scripts and arguments

    @Test func userValuesStayInArgvAndNeverEnterTheScript() {
        let evil = "x\" & (do shell script \"rm -rf ~\") & \"\n'; end tell"
        let query = NotesSearchQuery(text: evil, folderId: "x-coredata://F", account: evil, limit: 7)
        #expect(NotesScripts.searchArguments(query) == [evil, "x-coredata://F", evil])
        #expect(
            NotesScripts.searchArguments(NotesSearchQuery(text: "a"))
                == ["a", NotesScripts.none, NotesScripts.none])
        #expect(NotesScripts.createArguments(html: evil, folderId: nil, account: nil) == [evil, "<none>", "<none>"])
        #expect(NotesScripts.noteArguments(id: "x-coredata://N", includeHTML: true) == ["x-coredata://N", "true"])
        #expect(NotesScripts.search.contains("rm -rf") == false)
        #expect(
            NotesScripts.createFolderArguments(name: evil, parentId: "x-coredata://F", account: evil)
                == [evil, "x-coredata://F", evil])
        #expect(
            NotesScripts.createFolderArguments(name: "n", parentId: nil, account: nil) == ["n", "<none>", "<none>"])
        #expect(NotesScripts.createFolder.contains("rm -rf") == false)
    }

    @Test func everyScriptIsBuiltFromConstantsOnly() {
        for script in [
            NotesScripts.folders, NotesScripts.search, NotesScripts.note, NotesScripts.create,
            NotesScripts.append, NotesScripts.move, NotesScripts.delete, NotesScripts.replace,
            NotesScripts.createFolder,
        ] {
            #expect(script.contains("on run argv"))
            // The lookups live in one place.
            #expect(script.components(separatedBy: "on findNote").count == 2)
            #expect(script.components(separatedBy: "on findFolder").count == 2)
            // No interpolation marker was left in the text.
            #expect(script.contains("\\(") == false)
        }
    }

    @Test func findNoteOnlySwallowsNotFoundErrors() {
        let start = NotesScripts.prelude.range(of: "on findNote")!.lowerBound
        let end = NotesScripts.prelude.range(of: "end findNote")!.upperBound
        let handler = String(NotesScripts.prelude[start..<end])
        #expect(handler.contains("on error errMsg number errNum"))
        #expect(handler.contains("if errNum is not -1728 and errNum is not -1719 then error errMsg number errNum"))
    }

    @Test func scriptsStripSeparatorsFromValues() {
        let prelude = NotesScripts.prelude
        #expect(prelude.contains("set AppleScript's text item delimiters to {fs, rs}"))
        #expect(prelude.contains("property fs : character id 31") && prelude.contains("property rs : character id 30"))
        // Name and text fields go through `clean`.
        #expect(
            NotesScripts.search.contains("my clean(noteName)")
                && NotesScripts.search.contains("my clean(noteText)"))
        #expect(NotesScripts.note.contains("my clean(noteName)") && NotesScripts.note.contains("my clean(html)"))
        #expect(prelude.contains("my clean(noteName)"))
    }

    @Test func lockedNotesAreCheckedBeforeAnyTextIsRead() {
        // append: the lock check runs before the body is read.
        let appendLock = NotesScripts.append.range(of: "my failIfLocked(nt)")
        let appendText = NotesScripts.append.range(of: "body of nt")
        #expect(appendLock != nil && appendText != nil && appendLock!.lowerBound < appendText!.lowerBound)
        // update_note: the same.
        let replaceLock = NotesScripts.replace.range(of: "my failIfLocked(nt)")
        let replaceBody = NotesScripts.replace.range(of: "set body of nt")
        #expect(replaceLock != nil && replaceBody != nil && replaceLock!.lowerBound < replaceBody!.lowerBound)
        // get_note reads every property in one event, then refuses a locked note before it uses any field.
        let note = NotesScripts.note
        let lock = note.range(of: "if isLocked then my failWith(1002")
        let text = note.range(of: "plaintext of props")
        #expect(lock != nil && text != nil && lock!.lowerBound < text!.lowerBound)
        // The search never returns or matches the text of a locked note.
        #expect(NotesScripts.search.contains("if not isLocked then set noteText to"))
        #expect(NotesScripts.search.contains("else if not isLocked and (item i of cols's noteTexts) contains q then"))
    }

    @Test func scriptErrorNumbersAreMapped() {
        let message = NotesScripts.cleanMessage("12:40: execution error: No note with id 'x'. (1001)\n")
        #expect(message == "No note with id 'x'.")
        #expect(NotesScripts.cleanMessage("execution error: Locked. (1002)") == "Locked.")
        let duplicate = NotesScripts.scriptError(
            ToolError(.internalError, "1:2: execution error: A folder named 'X' is already there. (1007)"))
        #expect(duplicate.code == .invalidInput && duplicate.message == "A folder named 'X' is already there.")
        #expect(duplicate.fix?.isEmpty == false)
        #expect(NotesScripts.lockedError().code == .permissionDenied)
        #expect(NotesScripts.lockedError().message.contains("locked"))
        let timeout = NotesScripts.timeoutError(seconds: 60, search: true)
        #expect(timeout.code == .timeout && timeout.fix?.contains("'folder'") == true)
        #expect(NotesScripts.timeoutError(seconds: 30, search: false).fix?.contains("'folder'") == false)
    }

    // MARK: ids

    @Test func noteIdShape() {
        #expect(NotesScripts.isValidID("x-coredata://6E1D5C2A-0000-1111-2222-333344445555/ICNote/p123"))
        for bad in [
            "", "123", "x-coredata://", "http://x", "x-coredata://a b", "x-coredata://a\nb", "x-coredata://é",
            "x-coredata://" + String(repeating: "a", count: 500),
        ] {
            #expect(NotesScripts.isValidID(bad) == false, "\(bad)")
        }
    }

    // MARK: output parsing

    @Test func parsesFolders() {
        let text = "F1\(fs)Notes\(fs)iCloud\(fs)12\(rs)F2\(fs)Work\(fs)Gmail\(fs)x\(rs)broken\(fs)row\(rs)\(fs)n\(fs)a"
        #expect(
            NotesScripts.parseFolders(text) == [
                NotesFolder(id: "F1", name: "Notes", account: "iCloud", noteCount: 12),
                NotesFolder(id: "F2", name: "Work", account: "Gmail", noteCount: nil),
            ])
        #expect(NotesScripts.parseFolders("").isEmpty)
    }

    func row(
        _ id: String, _ name: String, modified: String = "2026-11-12 09:30:00", locked: Bool = false,
        kind: String = "name", snippet: String = "", folder: String = "Notes", account: String = "iCloud"
    ) -> String {
        [id, name, folder, account, modified, String(locked), kind, snippet].joined(separator: fs)
    }

    @Test func parsesSearchRowsWithMissingFields() {
        let text = [
            row("N1", "Shopping", snippet: "milk, eggs"), row("N2", "No date", modified: ""),
            "N3\(fs)short\(fs)Notes", row("", "no id"),
            row("N4", "Secret", locked: true, snippet: "should never show"),
        ].joined(separator: rs)
        let found = NotesScripts.parseSearch(text)
        #expect(found.map(\.summary.id) == ["N1", "N2", "N4"])
        #expect(found[0].summary.snippet == "milk, eggs" && found[0].titleMatch)
        #expect(found[0].summary.folder == "Notes" && found[0].summary.account == "iCloud")
        #expect(
            found[0].summary.modified.map { NotesScripts.dateFormatter().string(from: $0) } == "2026-11-12 09:30:00")
        #expect(found[1].summary.modified == nil)
        #expect(found[2].summary.locked && found[2].summary.snippet.isEmpty)
        #expect(NotesScripts.parseSearch("").isEmpty)
    }

    @Test func snippetIsCleanedAndCut() {
        #expect(NotesScripts.snippet("Title\n\nline one\n  line two", name: "Title") == "line one line two")
        #expect(NotesScripts.snippet("Other text", name: "Title") == "Other text")
        #expect(NotesScripts.snippet(String(repeating: "ab ", count: 300), name: "x").count == 200)
        #expect(NotesScripts.snippet("", name: "x").isEmpty)
    }

    @Test func finishMergesSortsAndCuts() {
        func record(_ id: String, day: Int, title: Bool) -> NotesScripts.SearchRecord {
            let date = Date(timeIntervalSince1970: Double(day) * 86400)
            return NotesScripts.SearchRecord(
                summary: NoteSummary(
                    id: id, name: id, folder: "F", account: "A", modified: date, locked: false, snippet: ""),
                titleMatch: title)
        }
        let records = [
            record("b1", day: 9, title: false), record("t1", day: 1, title: true), record("t2", day: 3, title: true),
            record("t1", day: 1, title: false), record("b2", day: 5, title: false), record("t2", day: 3, title: true),
        ]
        let page = NotesScripts.finish(records, limit: 10)
        // Title matches first, newest first. A note found twice appears once, as a title match.
        #expect(page.items.map(\.id) == ["t2", "t1", "b1", "b2"])
        #expect(page.truncated == false)
        let cut = NotesScripts.finish(records, limit: 3)
        #expect(cut.items.map(\.id) == ["t2", "t1", "b1"] && cut.truncated)
    }

    @Test func parsesNoteOutput() {
        let fields = ["N1", "Plan", "Notes", "iCloud", "2026-11-11 08:00:00", "2026-11-12 09:30:00", ""]
        let text = (fields + ["Plan\nLine \u{1C} two", "<div>Plan</div>"]).joined(separator: fs)
        let note = NotesScripts.parseNote(text, includeHTML: true)
        #expect(note?.id == "N1" && note?.name == "Plan" && note?.account == "iCloud")
        #expect(note?.body == "Plan\nLine \u{1C} two" && note?.truncated == false && note?.html == "<div>Plan</div>")
        #expect(note?.created != nil && note?.modified != nil)
        #expect(NotesScripts.parseNote(text, includeHTML: false)?.html == nil)
        #expect(NotesScripts.parseNote("too\(fs)few", includeHTML: false) == nil)
        let blank = (["N1", "", "", "", "", ""] + ["", "", ""]).joined(separator: fs)
        #expect(NotesScripts.parseNote(blank, includeHTML: false)?.created == nil)
        #expect(note?.attachments.isEmpty == true)
    }

    @Test func parsesTheAttachmentList() {
        let gs = "\u{1D}"
        let names = ["IMG_4311.heic", "scan.PDF", "(no name)", "CISCON 2024 - Link", "plan.docx"].joined(separator: gs)
        let text = (["N1", "Plan", "Notes", "iCloud", "", "", names, "body", ""]).joined(separator: fs)
        let note = NotesScripts.parseNote(text, includeHTML: false)
        #expect(note?.attachments.map(\.index) == [1, 2, 3, 4, 5])
        #expect(
            note?.attachments.map(\.name) == [
                "IMG_4311.heic", "scan.PDF", "(no name)", "CISCON 2024 - Link", "plan.docx",
            ])
        #expect(
            note?.attachments.map(\.type) == [
                "image/heic", "application/pdf", nil, nil,
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ])
        #expect(note?.body == "body")
        // A note with one attachment keeps it.
        let single = (["N1", "P", "N", "iCloud", "", "", "only.png", "b", ""]).joined(separator: fs)
        #expect(NotesScripts.parseNote(single, includeHTML: false)?.attachments.map(\.name) == ["only.png"])
    }

    @Test func scriptErrorsBecomeToolErrors() {
        func make(_ text: String, _ number: Int) -> ToolError {
            NotesScripts.scriptError(ToolError(.internalError, "9:9: execution error: \(text) (\(number))\n"))
        }
        let missing = make("The note has no attachment named 'x'.", 1001)
        #expect(missing.code == .notFound && missing.fix?.contains("get_note") == true)
        #expect(make("No note with id 'x'.", 1001).fix?.contains("search_notes") == true)
        #expect(make("The note is locked.", 1002) == NotesScripts.lockedError())
        #expect(make("More than one attachment is named 'a'.", 1004).code == .ambiguous)
        let export = make("Notes could not save the attachment 'Link' (AppleEvent handler failed.).", 1006)
        #expect(export.code == .invalidInput && export.fix?.contains("Drawings, scans, tables and links") == true)
        #expect(export.message.hasSuffix("failed.)."))
        let other = ToolError(.internalError, "odd (-1728)")
        #expect(NotesScripts.scriptError(other) == other)
    }

    @Test func theAttachmentScriptTakesValuesOnlyThroughArgv() {
        let script = NotesScripts.saveAttachment
        #expect(script.contains("item 4 of argv") && script.contains("save att in (POSIX file (item 4 of argv))"))
        #expect(script.contains("my failIfLocked(nt)"))
    }

    @Test func bodyIsCutAt100000Characters() {
        let (same, cutSame) = NotesScripts.limitBody(String(repeating: "a", count: 100_000))
        #expect(same.count == 100_000 && cutSame == false)
        let (cut, truncated) = NotesScripts.limitBody(String(repeating: "é", count: 100_001))
        #expect(cut.count == 100_000 && truncated)
        let fields = ["N1", "Big", "Notes", "iCloud", "", "", "", String(repeating: "x", count: 100_001), ""]
        let note = NotesScripts.parseNote(fields.joined(separator: fs), includeHTML: false)
        #expect(note?.body.count == 100_000 && note?.truncated == true)
    }

    @Test func parsesHeaderRecords() {
        #expect(
            NotesScripts.parseRef("N1\(fs)Name\(fs)Folder\(fs)iCloud")
                == NoteRef(id: "N1", name: "Name", folder: "Folder", account: "iCloud"))
        #expect(NotesScripts.parseRef("N1\(fs)\(fs)Folder\(fs)")?.name == "")
        #expect(NotesScripts.parseRef("N1\(fs)Name") == nil)
        #expect(NotesScripts.parseRef("\(fs)a\(fs)b\(fs)c") == nil)
    }
}
