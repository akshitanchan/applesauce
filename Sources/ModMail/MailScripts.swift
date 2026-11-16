import AppleSauceCore
import Foundation

/// The AppleScript for Mail, and the code that builds its arguments and reads its output.
///
/// Rules:
/// - User values go only in `argv`. They never enter the script text.
/// - Scripts print records. Fields are separated by character 31, records by character 30.
enum MailScripts {
    /// Stands for "no value" in `argv`, because an empty argument may not survive `osascript`.
    static let none = "<none>"

    static let fieldSeparator: Character = "\u{1F}"
    static let recordSeparator: Character = "\u{1E}"

    /// The error number that the scripts raise for a missing item. `run` turns it into a tool error.
    static let notFoundNumber = 1001

    /// Longest plain text body that a tool returns, in characters.
    static let bodyLimit = 100_000

    // MARK: shared handlers

    /// Handlers that every script uses.
    ///
    /// The Mail `id` of a message is the same number as the Envelope Index ROWID.
    /// `findMessage` is the only place that turns an id into a message.
    /// `mailbox "[Gmail]/Bin" of account` accepts a path with `/` for a nested mailbox.
    static let prelude = """
        property fs : character id 31
        property rs : character id 30

        on failWith(code, reason)
            error reason number code
        end failWith

        -- Text of a value without the separator characters. Missing values become "".
        on safeText(value)
            if value is missing value then return ""
            set t to value as text
            set saved to AppleScript's text item delimiters
            set AppleScript's text item delimiters to {fs, rs}
            set parts to text items of t
            set AppleScript's text item delimiters to ""
            set t to parts as text
            set AppleScript's text item delimiters to saved
            return t
        end safeText

        on pad2(n)
            set t to (n as integer) as text
            if (count of t) < 2 then set t to "0" & t
            return t
        end pad2

        on formatDate(d)
            if d is missing value then return ""
            return ((year of d) as text) & "-" & my pad2(month of d as integer) & "-" & my pad2(day of d) & " " & my pad2(hours of d) & ":" & my pad2(minutes of d) & ":" & my pad2(seconds of d)
        end formatDate

        -- A date from text like `2026-11-12 09:30:00`. It is the reverse of formatDate.
        on parseDate(t)
            set d to current date
            set day of d to 1
            set year of d to (text 1 thru 4 of t) as integer
            set month of d to (text 6 thru 7 of t) as integer
            set day of d to (text 9 thru 10 of t) as integer
            set hours of d to (text 12 thru 13 of t) as integer
            set minutes of d to (text 15 thru 16 of t) as integer
            set seconds of d to (text 18 thru 19 of t) as integer
            return d
        end parseDate

        -- The account with this id or name. Error 1001 when there is none.
        on findAccount(spec)
            tell application "Mail"
                repeat with acct in accounts
                    if (id of acct) is spec or (name of acct) is spec then return contents of acct
                end repeat
            end tell
            my failWith(1001, "Mail has no account '" & spec & "'.")
        end findAccount

        -- The mailbox with this path in an account. Error 1001 when there is none.
        on findMailbox(accountSpec, mailboxPath)
            set acct to my findAccount(accountSpec)
            try
                tell application "Mail" to return mailbox mailboxPath of acct
            on error errMsg number errNum
                if errNum is not -1728 and errNum is not -1719 then error errMsg number errNum
            end try
            my failWith(1001, "The account has no mailbox '" & mailboxPath & "'.")
        end findMailbox

        -- The message with this id in a mailbox. Error 1001 when there is none.
        on findMessage(accountSpec, mailboxPath, messageId)
            set mb to my findMailbox(accountSpec, mailboxPath)
            tell application "Mail"
                set matches to (every message of mb whose id is (messageId as integer))
            end tell
            if (count of matches) is 0 then my failWith(1001, "No message with id " & messageId & " in mailbox '" & mailboxPath & "'.")
            return item 1 of matches
        end findMessage

        on joinList(items_, separator)
            set AppleScript's text item delimiters to separator
            set joined to items_ as text
            set AppleScript's text item delimiters to ""
            return joined
        end joinList
        """

    // MARK: reads

    /// Output records: id, name, emails (comma separated).
    static let accounts =
        prelude + """


            on run argv
                tell application "Mail"
                    set acctIds to id of every account
                    set acctNames to name of every account
                    try
                        set acctEmails to email addresses of every account
                    on error
                        set acctEmails to {}
                    end try
                end tell
                set out to {}
                repeat with i from 1 to count of acctIds
                    set emails to ""
                    if (count of acctEmails) is (count of acctIds) then set emails to my joinList(item i of acctEmails, ",")
                    set end of out to (item i of acctIds) & fs & my safeText(item i of acctNames) & fs & emails
                end repeat
                return my joinList(out, rs)
            end run
            """

    /// argv: account spec or `none`. Output records: account id, account name, path, unread count.
    static let mailboxes =
        prelude + """


            -- One level at a time: names and unread counts of all children in bulk, then each child's children.
            on collect(container_, prefix, acctId, acctName, out)
                tell application "Mail"
                    set children to mailboxes of container_
                    if children is {} then return
                    set childNames to name of mailboxes of container_
                    try
                        set unreadCounts to unread count of mailboxes of container_
                    on error
                        set unreadCounts to {}
                    end try
                end tell
                repeat with i from 1 to count of children
                    set mbPath to prefix & (item i of childNames)
                    set unreadCount to 0
                    if (count of unreadCounts) is (count of children) then set unreadCount to item i of unreadCounts
                    set end of out to acctId & fs & acctName & fs & mbPath & fs & (unreadCount as text)
                    my collect(item i of children, mbPath & "/", acctId, acctName, out)
                end repeat
            end collect

            on run argv
                set out to {}
                tell application "Mail"
                    if (item 1 of argv) is "\(none)" then
                        set targets to accounts
                    else
                        set targets to {my findAccount(item 1 of argv)}
                    end if
                    repeat with acct in targets
                        set acctRef to contents of acct
                        my collect(acctRef, "", id of acctRef, name of acctRef, out)
                    end repeat
                end tell
                return my joinList(out, rs)
            end run
            """

    /// argv: account spec or `none`, mailbox path, since (`yyyy-MM-dd HH:mm:ss`, local time), before (same).
    /// Output records: id, subject, sender, date, read, flagged, mailbox path, account id, flag index (-1 for none).
    ///
    /// A `whose` filter on a large mailbox costs Mail several seconds, and Mail runs it again for each property read.
    /// So the script reads each property of every message once, in bulk, and filters the dates here.
    /// A message that arrives between two reads shifts the lists, so the reads repeat until the lengths agree.
    static let search =
        prelude + """


            on run argv
                set mailboxPath to item 2 of argv
                set sinceDate to my parseDate(item 3 of argv)
                set beforeDate to my parseDate(item 4 of argv)
                script cols
                    property msgIds : {}
                    property msgSubjects : {}
                    property msgSenders : {}
                    property msgDates : {}
                    property msgReads : {}
                    property msgFlags : {}
                    property msgColors : {}
                end script
                set out to {}
                tell application "Mail"
                    if (item 1 of argv) is "\(none)" then
                        set targets to accounts
                    else
                        set targets to {my findAccount(item 1 of argv)}
                    end if
                end tell
                repeat with acct in targets
                    set acctRef to contents of acct
                    set mb to missing value
                    tell application "Mail"
                        set acctId to id of acctRef
                        try
                            set mb to mailbox mailboxPath of acctRef
                        on error errMsg number errNum
                            if errNum is not -1728 and errNum is not -1719 then error errMsg number errNum
                        end try
                    end tell
                    if mb is not missing value then
                        set aligned to false
                        repeat 3 times
                            tell application "Mail"
                                set cols's msgDates to date received of every message of mb
                                set cols's msgIds to id of every message of mb
                                set cols's msgSubjects to subject of every message of mb
                                set cols's msgSenders to sender of every message of mb
                                set cols's msgReads to read status of every message of mb
                                set cols's msgFlags to flagged status of every message of mb
                                set cols's msgColors to flag index of every message of mb
                            end tell
                            set total to count of cols's msgDates
                            if (count of cols's msgIds) is total and (count of cols's msgSubjects) is total and (count of cols's msgSenders) is total and (count of cols's msgReads) is total and (count of cols's msgFlags) is total and (count of cols's msgColors) is total then
                                set aligned to true
                                exit repeat
                            end if
                        end repeat
                        if not aligned then error "Mail changed the mailbox during the search. Try again."
                        repeat with i from 1 to total
                            set d to item i of cols's msgDates
                            if d is not missing value and d >= sinceDate and d < beforeDate then
                                set end of out to ((item i of cols's msgIds) as text) & fs & my safeText(item i of cols's msgSubjects) & fs & my safeText(item i of cols's msgSenders) & fs & my formatDate(d) & fs & ((item i of cols's msgReads) as text) & fs & ((item i of cols's msgFlags) as text) & fs & mailboxPath & fs & acctId & fs & ((item i of cols's msgColors) as text)
                            end if
                        end repeat
                    end if
                end repeat
                return my joinList(out, rs)
            end run
            """

    /// argv: account spec, mailbox path, id.
    /// Output (one record): subject, sender, date, read, flagged, flag index (-1 for none), to (comma separated), cc,
    /// attachments, content.
    /// Attachments are `name`, character 28, `size`, and character 29 between attachments.
    static let message =
        prelude + """


            on run argv
                set msg to my findMessage(item 1 of argv, item 2 of argv, item 3 of argv)
                set gs to character id 29
                set us to character id 28
                tell application "Mail"
                    set toList to {}
                    set ccList to {}
                    try
                        set toList to address of every to recipient of msg
                    end try
                    try
                        set ccList to address of every cc recipient of msg
                    end try
                    set attachmentList to {}
                    try
                        repeat with att in mail attachments of msg
                            set attSize to 0
                            try
                                set attSize to file size of att
                            end try
                            set end of attachmentList to (name of att) & us & (attSize as text)
                        end repeat
                    end try
                    set bodyText to ""
                    try
                        set bodyText to content of msg
                    end try
                    set flagIndex to -1
                    try
                        set flagIndex to flag index of msg
                    end try
                    return my safeText(subject of msg) & fs & my safeText(sender of msg) & fs & my formatDate(date received of msg) & fs & ((read status of msg) as text) & fs & ((flagged status of msg) as text) & fs & (flagIndex as text) & fs & my joinList(toList, ",") & fs & my joinList(ccList, ",") & fs & my joinList(attachmentList, gs) & fs & my safeText(bodyText)
                end tell
            end run
            """

    // MARK: writes

    /// argv: action (`flag`, `color`, `read`, `move`, `delete`), value (`true` or `false`, the flag index for `color`,
    /// or the target mailbox path),
    /// target account (name or id, or `none` for the account of each message), count,
    /// then for each message: account id, mailbox path, message id. Output: the number of messages changed.
    /// `delete` moves a message out of its mailbox, and Mail gives it a new id.
    /// `move msg to mailbox` works across accounts. On Gmail, `delete` moves a message to the Bin, it does not archive.
    static let change =
        prelude + """


            on run argv
                set action to item 1 of argv
                set value_ to item 2 of argv
                set targetAccount to item 3 of argv
                set n to (item 4 of argv) as integer
                set done to 0
                repeat with i from 0 to n - 1
                    set base to 5 + i * 3
                    set accountId to item base of argv
                    set msg to my findMessage(accountId, item (base + 1) of argv, item (base + 2) of argv)
                    if action is "move" then
                        if targetAccount is "\(none)" then
                            set target to my findMailbox(accountId, value_)
                        else
                            set target to my findMailbox(targetAccount, value_)
                        end if
                    end if
                    tell application "Mail"
                        if action is "flag" then
                            set flagged status of msg to (value_ is "true")
                        else if action is "color" then
                            set flagged status of msg to true
                            set flag index of msg to (value_ as integer)
                        else if action is "read" then
                            set read status of msg to (value_ is "true")
                        else if action is "move" then
                            move msg to target
                        else if action is "delete" then
                            delete msg
                        end if
                    end tell
                    set done to done + 1
                end repeat
                return done as text
            end run
            """

    /// argv: mode (`draft` or `send`), subject, body, number of to, cc, bcc addresses, sender address or `none`,
    /// then the addresses. The sender address picks the account that sends.
    /// The message is created without a window, and `send` leaves no window open.
    /// `save` puts it in Drafts without a visible window. Mail keeps the hidden message object until it quits,
    /// and neither `close` nor `delete` removes it, so the script leaves it.
    static let compose =
        prelude + """


            on run argv
                set mode to item 1 of argv
                set nTo to (item 4 of argv) as integer
                set nCc to (item 5 of argv) as integer
                set nBcc to (item 6 of argv) as integer
                tell application "Mail"
                    set msg to make new outgoing message with properties {subject:(item 2 of argv), content:(item 3 of argv), visible:false}
                    if (item 7 of argv) is not "\(none)" then set sender of msg to (item 7 of argv)
                    tell msg
                        set pos to 8
                        repeat with i from 1 to nTo
                            make new to recipient at end of to recipients with properties {address:(item pos of argv)}
                            set pos to pos + 1
                        end repeat
                        repeat with i from 1 to nCc
                            make new cc recipient at end of cc recipients with properties {address:(item pos of argv)}
                            set pos to pos + 1
                        end repeat
                        repeat with i from 1 to nBcc
                            make new bcc recipient at end of bcc recipients with properties {address:(item pos of argv)}
                            set pos to pos + 1
                        end repeat
                    end tell
                    if mode is "send" then
                        send msg
                    else
                        save msg
                    end if
                end tell
                return "ok"
            end run
            """

    /// argv: mode (`draft` or `send`), reply all (`true` or `false`), body, account id, mailbox path, message id.
    ///
    /// Mail's own `reply` command opens a window even with `opening window false`, fills in the quoted text later,
    /// and often never saves the draft. So the reply is built as a new hidden message instead:
    /// "Re: " and the subject, the original sender (or, for your own sent message, its recipients), everyone else
    /// for reply all, your address in that account, and the original text quoted with "> ".
    /// AppleScript cannot set the In-Reply-To header, so clients thread the reply by its subject.
    static let reply =
        prelude + """


            -- Addresses from a list, without your own and without repeats.
            on others(addresses_, own)
                set kept to {}
                repeat with a in addresses_
                    set address_ to contents of a
                    if own does not contain address_ and kept does not contain address_ then set end of kept to address_
                end repeat
                return kept
            end others

            on run argv
                set mode to item 1 of argv
                set replyAll to (item 2 of argv) is "true"
                set msg to my findMessage(item 4 of argv, item 5 of argv, item 6 of argv)
                tell application "Mail"
                    set own to {}
                    try
                        set own to email addresses of (account of (mailbox of msg))
                    end try
                    set originalSubject to subject of msg
                    set originalSender to sender of msg
                    set senderAddress to extract address from originalSender
                    set originalDate to date received of msg
                    set originalText to content of msg
                    set toAddresses to address of every to recipient of msg
                    set ccAddresses to address of every cc recipient of msg
                end tell
                -- Send from your address that the original went to, or the account's first address.
                set fromAddress to ""
                repeat with a in own
                    if (toAddresses & ccAddresses & {senderAddress}) contains (contents of a) then
                        set fromAddress to contents of a
                        exit repeat
                    end if
                end repeat
                if fromAddress is "" and (count of own) > 0 then set fromAddress to item 1 of own
                -- A reply to your own sent message goes to its recipients.
                if own contains senderAddress then
                    set toList to toAddresses
                else
                    set toList to {senderAddress}
                end if
                set ccList to {}
                if replyAll then
                    set toList to toList & toAddresses
                    set ccList to ccAddresses
                end if
                set toList to my others(toList, own)
                -- A message you sent only to yourself: reply to yourself.
                if toList is {} then set toList to my others(toAddresses & {senderAddress}, {})
                set ccList to my others(ccList, own & toList)
                set replySubject to originalSubject
                if replySubject does not start with "Re:" then set replySubject to "Re: " & replySubject
                if (count of originalText) > 20000 then set originalText to text 1 thru 20000 of originalText
                set quotedLines to {}
                repeat with lineText in paragraphs of originalText
                    set end of quotedLines to "> " & (contents of lineText)
                end repeat
                set replyText to (item 3 of argv) & return & return & "On " & (originalDate as text) & ", " & originalSender & " wrote:" & return & my joinList(quotedLines, return)
                tell application "Mail"
                    set answer to make new outgoing message with properties {subject:replySubject, content:replyText, visible:false}
                    if fromAddress is not "" then set sender of answer to fromAddress
                    tell answer
                        repeat with address_ in toList
                            make new to recipient at end of to recipients with properties {address:(contents of address_)}
                        end repeat
                        repeat with address_ in ccList
                            make new cc recipient at end of cc recipients with properties {address:(contents of address_)}
                        end repeat
                    end tell
                    if mode is "send" then
                        send answer
                    else
                        save answer
                    end if
                end tell
                return "ok"
            end run
            """

    // MARK: running

    /// Runs a script. The script's own error number 1001 (not found) becomes `NOT_FOUND`.
    static func run(_ script: String, _ arguments: [String], timeout: Double) async throws -> String {
        do {
            return try await AppleScript.run(
                script, arguments: arguments, permission: .automationMail, appName: "Mail", timeout: timeout)
        } catch let error as ToolError where error.code == .internalError {
            guard AppleScript.errorNumber(in: error.message) == notFoundNumber else { throw error }
            throw ToolError(
                .notFound, cleanMessage(error.message),
                fix: "Check the id with search_mail, and the mailbox with list_mailboxes.")
        }
    }

    /// `1:5: execution error: No message. (1001)` becomes `No message.`
    static func cleanMessage(_ text: String) -> String {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "execution error: ") { message = String(message[range.upperBound...]) }
        if let match = message.firstMatch(of: #/\s*\(1001\)\s*$/#) {
            message = String(message[..<match.range.lowerBound])
        }
        return message
    }

    // MARK: arguments

    /// Local time as `yyyy-MM-dd HH:mm:ss`. The script builds a Mail date from it.
    static func dateText(_ date: Date) -> String {
        dateFormatter().string(from: date)
    }

    static func searchArguments(account: String?, mailbox: String, since: Date, before: Date) -> [String] {
        [account ?? none, mailbox, dateText(since), dateText(before)]
    }

    static func changeArguments(
        action: String, value: String, targetAccount: String?, refs: [MessageRef]
    ) -> [String] {
        [action, value, targetAccount ?? none, String(refs.count)] + refs.flatMap { [$0.accountId, $0.mailbox, $0.id] }
    }

    static func composeArguments(_ mail: OutgoingMail, send: Bool) -> [String] {
        [
            send ? "send" : "draft", mail.subject, mail.body, String(mail.to.count), String(mail.cc.count),
            String(mail.bcc.count), mail.from ?? none,
        ] + mail.to + mail.cc + mail.bcc
    }

    static func replyArguments(ref: MessageRef, body: String, replyAll: Bool, send: Bool) -> [String] {
        [send ? "send" : "draft", replyAll ? "true" : "false", body, ref.accountId, ref.mailbox, ref.id]
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

    static func parseAccounts(_ text: String) -> [MailAccount] {
        records(text).compactMap { fields in
            guard fields.count >= 2 else { return nil }
            let emails = fields.count > 2 ? fields[2].split(separator: ",").map(String.init) : []
            return MailAccount(id: fields[0], name: fields[1], emails: emails)
        }
    }

    static func parseMailboxes(_ text: String) -> [MailboxInfo] {
        records(text).compactMap { fields in
            guard fields.count >= 4 else { return nil }
            let path = fields[2]
            return MailboxInfo(
                name: path.split(separator: "/").last.map(String.init) ?? path, path: path, accountId: fields[0],
                account: fields[1], unread: Int(fields[3]))
        }
    }

    static func parseSearch(_ text: String) -> [MessageSummary] {
        records(text).compactMap { fields in
            guard fields.count >= 8 else { return nil }
            let flagged = fields[5] == "true"
            return MessageSummary(
                id: fields[0], subject: fields[1], from: fields[2], date: parseDate(fields[3]), mailbox: fields[6],
                accountId: fields[7], read: fields[4] == "true", flagged: flagged, hasAttachments: nil,
                flagColor: colorName(fields.count > 8 ? fields[8] : "", flagged: flagged))
        }
    }

    /// The slower search filters in code, because the script only filters by date.
    /// It sorts newest first and cuts at `limit`.
    static func filter(_ items: [MessageSummary], _ query: MailSearchQuery) -> SearchPage {
        func contains(_ haystack: String, _ needle: String) -> Bool {
            haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let kept = items.filter { item in
            if let text = query.text, !(contains(item.subject, text) || contains(item.from, text)) { return false }
            if let from = query.from, !contains(item.from, from) { return false }
            if let subject = query.subject, !contains(item.subject, subject) { return false }
            if let unread = query.unread, unread == item.read { return false }
            if let flagged = query.flagged, flagged != item.flagged { return false }
            if let color = query.flagColor, !item.flagged || item.flagColor != color.rawValue { return false }
            return true
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return SearchPage(items: Array(kept.prefix(query.limit)), truncated: kept.count > query.limit)
    }

    /// Reads the output of the `message` script.
    static func parseMessage(_ text: String, ref: MessageRef) -> MailMessage? {
        let fields = text.split(separator: fieldSeparator, maxSplits: 9, omittingEmptySubsequences: false).map(
            String.init)
        guard fields.count == 10 else { return nil }
        func list(_ text: String) -> [String] { text.split(separator: ",").map(String.init) }
        let attachments = fields[8].split(separator: "\u{1D}").map { item -> MailAttachment in
            let parts = item.split(separator: "\u{1C}", omittingEmptySubsequences: false).map(String.init)
            return MailAttachment(name: parts.first ?? "", size: parts.count > 1 ? Int(parts[1]) : nil)
        }
        let (body, truncated) = limitBody(fields[9])
        let flagged = fields[4] == "true"
        return MailMessage(
            id: ref.id, subject: fields[0], from: fields[1], to: list(fields[6]), cc: list(fields[7]),
            date: parseDate(fields[2]), mailbox: ref.mailbox, accountId: ref.accountId, read: fields[3] == "true",
            flagged: flagged, messageId: nil, body: body, bodySource: "applescript",
            truncated: truncated, partial: false, attachments: attachments, note: nil,
            flagColor: colorName(fields[5], flagged: flagged))
    }

    /// The color name for the text of a `flag index`. Nil for an unflagged message, -1 or a value that is not a color.
    static func colorName(_ index: String, flagged: Bool) -> String? {
        guard flagged, let number = Int(index) else { return nil }
        return FlagColor(index: number)?.rawValue
    }

    static func limitBody(_ text: String, limit: Int = bodyLimit) -> (String, Bool) {
        text.count > limit ? (String(text.prefix(limit)), true) : (text, false)
    }
}
