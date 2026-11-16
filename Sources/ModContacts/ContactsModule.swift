import AppleSauceCore
import Foundation
import MCP

/// Contacts tools. The data comes from a `ContactsStore` (the Contacts framework in the real binary).
public struct ContactsModule: Module {
    public let name = "contacts"
    public let permissions: [Permission] = [.contacts]

    let store: any ContactsStore
    let permissionTimeout: Double
    let backendTimeout: Double

    /// The real module, backed by the Contacts framework.
    public init() {
        self.init(store: CNContactsStore())
    }

    init(store: any ContactsStore, permissionTimeout: Double = 120, backendTimeout: Double = 30) {
        self.store = store
        self.permissionTimeout = permissionTimeout
        self.backendTimeout = backendTimeout
    }

    // MARK: tools

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    public var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "search_contacts",
                description:
                    "Find contacts. The query matches name, organization and email (any case), and phone numbers when the query looks like a phone number. All words of the query must match. Returns name, organization, emails and phones. Use get_contact for the full card. Notes are never returned.",
                properties: [
                    "query": Self.property("string", "Name, organization, email or phone number to look for."),
                    "limit": Self.property("integer", "Most results to return. Default 25, maximum 200."),
                ],
                required: ["query"]),
            ToolSpec(
                name: "get_contact",
                description:
                    "Get one contact with all details: name, organization, job title, emails and phones with labels, postal addresses and birthday. Notes are never returned.",
                properties: ["id": Self.property("string", "Contact id from search_contacts. Use it as given.")],
                required: ["id"]),
        ]
    }

    // MARK: routing

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        switch tool {
        case "search_contacts": return try await searchContacts(args)
        case "get_contact": return try await getContact(args)
        default:
            throw ToolError(.unknownTool, "The contacts module has no tool named '\(tool)'.")
        }
    }

    // MARK: backend access

    /// Checks the permission (it may show the macOS prompt). Call it after the input checks.
    private func access() async throws {
        let store = store
        try await ensureAccess(
            .contacts, state: { store.accessState() }, request: { try await store.requestAccess() },
            timeout: permissionTimeout)
    }

    /// One backend call with the 30 second limit.
    private func backend<T: Sendable>(_ operation: @escaping @Sendable (any ContactsStore) async throws -> T)
        async throws -> T
    {
        let store = store
        return try await withTimeout(seconds: backendTimeout) { try await operation(store) }
    }

    // MARK: output

    private struct ContactList: Encodable {
        let contacts: [ContactInfo]
        let total: Int
        let truncated: Bool
    }

    static func describe(_ contact: ContactInfo) -> String {
        var parts = [contact.name]
        if let organization = contact.organization, !organization.isEmpty, organization != contact.name {
            parts.append(organization)
        }
        if let title = contact.jobTitle, !title.isEmpty { parts.append(title) }
        parts += contact.emails.map { labeled($0) }
        parts += contact.phones.map { labeled($0) }
        parts += contact.addresses.map { labeled($0) }
        if let birthday = contact.birthday { parts.append("birthday \(birthday)") }
        parts.append("id: \(contact.id)")
        return parts.joined(separator: " | ")
    }

    private static func labeled(_ item: LabeledValue) -> String {
        item.label.map { "\($0): \(item.value)" } ?? item.value
    }

    // MARK: read tools

    private func searchContacts(_ args: Arguments) async throws -> ToolOutput {
        let query = try args.requiredString("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError.invalidInput("'query' is required.") }
        let limit = try args.int("limit", default: 25, range: 1...200)

        try await access()
        let all = try await backend { try await $0.allContacts() }
        let hits = all.filter { ContactMatcher.matches($0, query: query) }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        let shown = Array(hits.prefix(limit))
        let truncated = hits.count > shown.count
        var lines = [
            truncated
                ? "Showing \(shown.count) of \(hits.count) contacts. Raise 'limit' (maximum 200) or use a more exact query."
                : "\(shown.count) contacts."
        ]
        lines += shown.map { "- " + Self.describe($0) }
        return try ToolOutput(
            text: lines.joined(separator: "\n"),
            payload: ContactList(contacts: shown, total: hits.count, truncated: truncated))
    }

    private func getContact(_ args: Arguments) async throws -> ToolOutput {
        let id = try args.requiredString("id").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ToolError.invalidInput("'id' is required.") }

        try await access()
        guard let contact = try await backend({ try await $0.contact(id: id) }) else {
            throw ToolError(
                .notFound, "No contact has the id '\(id)'.",
                fix: "Use an id from search_contacts. The contact may have been deleted.")
        }
        return try ToolOutput(text: Self.describe(contact), payload: contact)
    }
}
