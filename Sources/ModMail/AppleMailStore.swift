import AppKit
import AppleSauceCore
import Foundation

/// The real mail store. It reads the Envelope Index and the `.emlx` files (needs Full Disk Access),
/// and it talks to Mail through AppleScript.
struct AppleMailStore: MailStore {
    /// `~/Library/Mail`
    let mailRoot: URL
    let readTimeout: Double
    let writeTimeout: Double

    init(
        mailRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail"),
        readTimeout: Double = 30, writeTimeout: Double = 60
    ) {
        self.mailRoot = mailRoot
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
    }

    // MARK: state

    func isMailRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
    }

    /// The Mail folder is protected. It can be listed only with Full Disk Access.
    func hasFullDiskAccess() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: mailRoot.path)) != nil
    }

    private static func notRunning() -> ToolError {
        ToolError(.appNotRunning, "Mail is not running.", fix: "Open Mail, then try again.")
    }

    private func requireRunning() throws {
        guard isMailRunning() else { throw Self.notRunning() }
    }

    // MARK: index

    /// The highest `V<number>` folder that has a `MailData/Envelope Index` file (for example `V10`).
    static func latestVersionFolder(in root: URL) throws -> URL {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            throw ToolError(
                .permissionDenied, "macOS does not let applesauce list the Mail folder.",
                fix: Permission.fullDiskAccess.fix(for: .denied) ?? "Grant Full Disk Access.")
        }
        let versions = names.compactMap { name -> (Int, String)? in
            guard let match = name.wholeMatch(of: #/V(\d+)/#), let number = Int(match.1) else { return nil }
            return (number, name)
        }.sorted { $0.0 > $1.0 }
        for (_, name) in versions {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("MailData/Envelope Index").path) {
                return folder
            }
        }
        throw ToolError(
            .notFound, "No Mail data folder with an Envelope Index was found in \(root.path).",
            fix: "Open Mail once and let it set up an account.")
    }

    private func openIndex() throws -> (index: EnvelopeIndex, folder: URL) {
        let folder = try Self.latestVersionFolder(in: mailRoot)
        let reader = try SQLiteReader(path: folder.appendingPathComponent("MailData/Envelope Index").path)
        return (try EnvelopeIndex(db: reader), folder)
    }

    // MARK: accounts and mailboxes

    func accounts() async throws -> [MailAccount] {
        var failure = Self.notRunning()
        if isMailRunning() {
            do {
                return MailScripts.parseAccounts(
                    try await MailScripts.run(MailScripts.accounts, [], timeout: readTimeout))
            } catch let error as ToolError {
                failure = error
            }
        }
        // Without Mail, the index still knows the account ids. It does not know their names.
        if let boxes = try? openIndex().index.mailboxes(), !boxes.isEmpty {
            var seen = Set<String>()
            return boxes.map(\.accountId).filter { seen.insert($0).inserted }.map {
                MailAccount(id: $0, name: $0, emails: [])
            }
        }
        throw failure
    }

    func mailboxes(account: String?) async throws -> [MailboxInfo] {
        if hasFullDiskAccess(), let boxes = try? openIndex().index.mailboxes() {
            let names = Dictionary(
                ((try? await accounts()) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            return boxes.filter { account == nil || $0.accountId.caseInsensitiveCompare(account ?? "") == .orderedSame }
                .map {
                    MailboxInfo(
                        name: $0.name, path: $0.path, accountId: $0.accountId, account: names[$0.accountId],
                        unread: $0.unread)
                }
                .sorted { ($0.accountId, $0.path.lowercased()) < ($1.accountId, $1.path.lowercased()) }
        }
        try requireRunning()
        let text = try await MailScripts.run(
            MailScripts.mailboxes, [account ?? MailScripts.none], timeout: readTimeout)
        return MailScripts.parseMailboxes(text)
    }

    // MARK: search

    func searchIndex(_ query: MailSearchQuery) async throws -> SearchPage {
        try openIndex().index.search(query)
    }

    func searchScripted(_ query: MailSearchQuery) async throws -> SearchPage {
        try requireRunning()
        guard let mailbox = query.mailbox, let since = query.since, let before = query.before else {
            throw ToolError.invalidInput("The scoped search needs a mailbox and a date range.")
        }
        let text = try await MailScripts.run(
            MailScripts.search,
            MailScripts.searchArguments(account: query.account, mailbox: mailbox, since: since, before: before),
            timeout: readTimeout)
        return MailScripts.filter(MailScripts.parseSearch(text), query)
    }

    // MARK: messages

    func indexMessage(id: String) async throws -> MailMessage {
        let (index, folder) = try openIndex()
        guard let rowid = Int64(id), let detail = try index.message(rowid: rowid) else {
            throw ToolError(
                .notFound, "No message has the id '\(id)'.", fix: "Use an id from search_mail.")
        }
        let summary = detail.summary
        var body: String?
        var source = "none"
        var truncated = false
        var partial = false
        var note: String?
        var messageID: String?
        var attachments = detail.attachmentNames.map { MailAttachment(name: $0, size: nil) }
        var to = detail.to
        var cc = detail.cc

        let located = EmlxLocator(root: folder).find(accountId: summary.accountId, mailbox: summary.mailbox, rowid: id)
        let file = located.map { MIMEReader.readEmlx(at: $0.url) }
        if let located, case .data(let data)? = file {
            let parsed = MIMEReader.parse(MIMEReader.messageBytes(inEmlx: data))
            (body, truncated) = MailScripts.limitBody(parsed.body)
            source = "emlx"
            partial = located.partial
            messageID = parsed.messageID
            attachments = parsed.attachments
            if to.isEmpty, let header = parsed.to { to = [header] }
            if cc.isEmpty, let header = parsed.cc { cc = [header] }
            if partial { note = "Mail has only part of this message on disk. The body may be incomplete." }
        } else if case .tooLarge(let bytes)? = file {
            // No body: the module then asks Mail for it.
            let (size, limit) = (bytes / 1_000_000, MIMEReader.emlxLimit / 1_000_000)
            note = "The message file is too large to read (\(size) MB, the limit is \(limit) MB)."
        } else {
            note = "The message file is not on disk. Mail may not have downloaded it."
        }
        return MailMessage(
            id: id, subject: summary.subject, from: summary.from, to: to, cc: cc, date: summary.date,
            mailbox: summary.mailbox, accountId: summary.accountId, read: summary.read, flagged: summary.flagged,
            messageId: messageID, body: body, bodySource: source, truncated: truncated, partial: partial,
            attachments: attachments, note: note)
    }

    func scriptedMessage(_ ref: MessageRef) async throws -> MailMessage {
        try requireRunning()
        let text = try await MailScripts.run(
            MailScripts.message, [ref.accountId, ref.mailbox, ref.id], timeout: readTimeout)
        guard let message = MailScripts.parseMessage(text, ref: ref) else {
            throw ToolError(
                .internalError, "Mail gave an answer that could not be read.", fix: "Report this error.")
        }
        return message
    }

    func locate(ids: [String]) async throws -> [MessageRef] {
        let rowids = ids.compactMap { Int64($0) }
        let refs = try openIndex().index.refs(rowids: rowids)
        let found = Set(refs.map(\.id))
        let missing = ids.filter { !found.contains($0) }
        if !missing.isEmpty {
            throw ToolError(
                .notFound, "No message has the id \(missing.map { "'\($0)'" }.joined(separator: ", ")).",
                fix: "Use ids from search_mail.")
        }
        return refs
    }

    // MARK: writes

    func compose(_ mail: OutgoingMail, send: Bool) async throws {
        _ = try await MailScripts.run(
            MailScripts.compose, MailScripts.composeArguments(mail, send: send), timeout: writeTimeout)
    }

    func reply(to ref: MessageRef, body: String, replyAll: Bool, send: Bool) async throws {
        _ = try await MailScripts.run(
            MailScripts.reply, MailScripts.replyArguments(ref: ref, body: body, replyAll: replyAll, send: send),
            timeout: writeTimeout)
    }

    func move(_ refs: [MessageRef], mailbox: String, account: String?) async throws {
        _ = try await MailScripts.run(
            MailScripts.change,
            MailScripts.changeArguments(action: "move", value: mailbox, targetAccount: account, refs: refs),
            timeout: writeTimeout)
    }

    func setFlagged(_ refs: [MessageRef], _ flagged: Bool) async throws {
        _ = try await MailScripts.run(
            MailScripts.change,
            MailScripts.changeArguments(
                action: "flag", value: flagged ? "true" : "false", targetAccount: nil, refs: refs),
            timeout: writeTimeout)
    }

    func setRead(_ refs: [MessageRef], _ read: Bool) async throws {
        _ = try await MailScripts.run(
            MailScripts.change,
            MailScripts.changeArguments(
                action: "read", value: read ? "true" : "false", targetAccount: nil, refs: refs),
            timeout: writeTimeout)
    }

    func delete(_ refs: [MessageRef]) async throws {
        _ = try await MailScripts.run(
            MailScripts.change,
            MailScripts.changeArguments(action: "delete", value: "true", targetAccount: nil, refs: refs),
            timeout: writeTimeout)
    }
}
