import AppleSauceCore
import Foundation

@testable import ModContacts

/// A contacts store in memory. It records every call. It never touches the Contacts framework.
final class FakeContactsStore: ContactsStore, @unchecked Sendable {
    struct State {
        var permission: PermissionState = .granted
        /// What `requestAccess` returns. On true the permission becomes granted.
        var requestResult = true
        /// Seconds that `requestAccess` waits first (to test time limits).
        var requestDelay: Double = 0
        /// Seconds that `allContacts` waits first.
        var listDelay: Double = 0
        var contacts: [ContactInfo] = []
        /// What `contact(id:)` returns, with all fields. Falls back to `contacts`.
        var details: [ContactInfo] = []
        var calls: [String] = []
        var created: NewContact?
        var updated: (id: String, patch: ContactPatch)?
        var deleted: String?
        /// An error that `delete` throws.
        var deleteError: ToolError?
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

    fileprivate func write(_ body: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&state)
    }

    func accessState() -> PermissionState { read(\.permission) }

    func requestAccess() async throws -> Bool {
        write { $0.calls.append("request") }
        let delay = read(\.requestDelay)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        let result = read(\.requestResult)
        if result { write { $0.permission = .granted } }
        return result
    }

    func allContacts() async throws -> [ContactInfo] {
        write { $0.calls.append("all") }
        let delay = read(\.listDelay)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return read(\.contacts)
    }

    func contact(id: String) async throws -> ContactInfo? {
        write { $0.calls.append("contact") }
        return read(\.details).first { $0.id == id } ?? read(\.contacts).first { $0.id == id }
    }
}

extension FakeContactsStore {
    func create(_ contact: NewContact) async throws -> ContactInfo {
        write {
            $0.calls.append("create")
            $0.created = contact
        }
        let name = [contact.givenName, contact.familyName].compactMap { $0 }.joined(separator: " ")
        var info = ContactInfo(id: "NEW", name: name.isEmpty ? (contact.organization ?? "") : name)
        info.givenName = contact.givenName
        info.familyName = contact.familyName
        info.organization = contact.organization
        info.emails = contact.emails
        info.phones = contact.phones
        info.birthday = contact.birthday?.text
        return info
    }

    func update(id: String, _ patch: ContactPatch) async throws -> ContactInfo {
        write {
            $0.calls.append("update")
            $0.updated = (id, patch)
        }
        return read(\.details).first { $0.id == id } ?? read(\.contacts).first { $0.id == id }!
    }

    func delete(id: String) async throws {
        write { $0.calls.append("delete") }
        if let error = read(\.deleteError) { throw error }
        write { $0.deleted = id }
    }
}

func contactInfo(
    _ id: String, _ name: String, organization: String? = nil, emails: [String] = [], phones: [String] = []
) -> ContactInfo {
    var info = ContactInfo(id: id, name: name)
    info.organization = organization
    info.emails = emails.map { LabeledValue(label: "work", value: $0) }
    info.phones = phones.map { LabeledValue(label: "mobile", value: $0) }
    return info
}
