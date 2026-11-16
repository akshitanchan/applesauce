import AppleSauceCore
import Foundation

@testable import ModMail

/// A mail store in memory. It records every call. It never opens the real index and never runs AppleScript.
final class FakeMailStore: MailStore, @unchecked Sendable {
    struct State {
        var running = true
        /// True when `ensureRunning` cannot start Mail.
        var launchFails = false
        /// How many times `ensureRunning` started Mail.
        var launches = 0
        var fullDiskAccess = true
        var accounts: [MailAccount] = [
            MailAccount(id: "ACC1", name: "Work", emails: ["me@work.example"]),
            MailAccount(id: "ACC2", name: "Home", emails: []),
        ]
        var mailboxes: [MailboxInfo] = []
        var indexPage = SearchPage(items: [], truncated: false)
        var scriptedPage = SearchPage(items: [], truncated: false)
        /// An error that `searchIndex` throws.
        var indexError: ToolError?
        var message: MailMessage?
        var scriptedMessage: MailMessage?
        var locateError: ToolError?
        var refs: [String: MessageRef] = [:]
        var calls: [String] = []
        var searchQuery: MailSearchQuery?
        var scriptedQuery: MailSearchQuery?
        var composed: (mail: OutgoingMail, send: Bool)?
        var replied: (ref: MessageRef, body: String, replyAll: Bool, send: Bool)?
        var moved: (refs: [MessageRef], mailbox: String, account: String?)?
        var flagged: (refs: [MessageRef], value: Bool, color: FlagColor?)?
        var read: (refs: [MessageRef], value: Bool)?
        var deleted: [MessageRef]?
        var writeDelay: Double = 0
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

    func isMailRunning() -> Bool { read(\.running) }

    static let cannotStart = ToolError(
        .appNotRunning, "applesauce opened Mail, but Mail did not answer within 20 seconds.",
        fix: "Check that Mail is not stuck on a dialog, then try again.")

    func ensureRunning() async throws {
        if read(\.running) { return }
        if read(\.launchFails) { throw Self.cannotStart }
        write {
            $0.running = true
            $0.launches += 1
        }
    }
    func hasFullDiskAccess() -> Bool { read(\.fullDiskAccess) }

    func accounts() async throws -> [MailAccount] {
        write { $0.calls.append("accounts") }
        return read(\.accounts)
    }

    func mailboxes(account: String?) async throws -> [MailboxInfo] {
        write { $0.calls.append("mailboxes") }
        return read { $0.mailboxes.filter { account == nil || $0.accountId == account } }
    }

    func searchIndex(_ query: MailSearchQuery) async throws -> SearchPage {
        write {
            $0.calls.append("searchIndex")
            $0.searchQuery = query
        }
        if let error = read(\.indexError) { throw error }
        return read(\.indexPage)
    }

    func searchScripted(_ query: MailSearchQuery) async throws -> SearchPage {
        write {
            $0.calls.append("searchScripted")
            $0.scriptedQuery = query
        }
        return read(\.scriptedPage)
    }

    func indexMessage(id: String) async throws -> MailMessage {
        write { $0.calls.append("indexMessage") }
        if let error = read(\.indexError) { throw error }
        guard let message = read(\.message) else { throw ToolError(.notFound, "No message \(id).") }
        return message
    }

    func scriptedMessage(_ ref: MessageRef) async throws -> MailMessage {
        write { $0.calls.append("scriptedMessage") }
        guard let message = read(\.scriptedMessage) else { throw ToolError(.notFound, "No message \(ref.id).") }
        return message
    }

    func locate(ids: [String]) async throws -> [MessageRef] {
        write { $0.calls.append("locate") }
        if let error = read(\.locateError) { throw error }
        let known = read(\.refs)
        let missing = ids.filter { known[$0] == nil }
        if !missing.isEmpty { throw ToolError(.notFound, "No message \(missing.joined(separator: ", ")).") }
        return ids.compactMap { known[$0] }
    }

    private func delay() async throws {
        let seconds = read(\.writeDelay)
        if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
    }

    func compose(_ mail: OutgoingMail, send: Bool) async throws {
        write {
            $0.calls.append("compose")
            $0.composed = (mail, send)
        }
        try await delay()
    }

    func reply(to ref: MessageRef, body: String, replyAll: Bool, send: Bool) async throws {
        write {
            $0.calls.append("reply")
            $0.replied = (ref, body, replyAll, send)
        }
        try await delay()
    }

    func move(_ refs: [MessageRef], mailbox: String, account: String?) async throws {
        write {
            $0.calls.append("move")
            $0.moved = (refs, mailbox, account)
        }
        try await delay()
    }

    func setFlagged(_ refs: [MessageRef], _ flagged: Bool, color: FlagColor?) async throws {
        write {
            $0.calls.append("flag")
            $0.flagged = (refs, flagged, color)
        }
        try await delay()
    }

    func setRead(_ refs: [MessageRef], _ read: Bool) async throws {
        write {
            $0.calls.append("read")
            $0.read = (refs, read)
        }
        try await delay()
    }

    func delete(_ refs: [MessageRef]) async throws {
        write {
            $0.calls.append("delete")
            $0.deleted = refs
        }
        try await delay()
    }
}
