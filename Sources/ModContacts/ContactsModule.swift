import AppleSauceCore
import Foundation
import MCP

/// Contacts tools. The data comes from a `ContactsStore` (the Contacts framework in the real binary).
public struct ContactsModule: Module {
    public static let moduleName = "contacts"
    public var name: String { Self.moduleName }
    public static let requiredPermissions: [Permission] = [.contacts]
    public var permissions: [Permission] { Self.requiredPermissions }

    let store: any ContactsStore
    let permissionTimeout: Double
    let backendTimeout: Double

    /// The real module, backed by the Contacts framework.
    #if os(macOS)
    public init() {
        self.init(store: CNContactsStore())
    }
    #endif

    init(store: any ContactsStore, permissionTimeout: Double = 120, backendTimeout: Double = 30) {
        self.store = store
        self.permissionTimeout = permissionTimeout
        self.backendTimeout = backendTimeout
    }

    // MARK: tools

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static let labelNote =
        "Label, for example home, work, mobile or other. Any other text becomes a custom label."

    private static func labeledList(_ noun: String) -> Value {
        [
            "type": "array",
            "items": [
                "type": "object",
                "properties": [
                    "label": property("string", Self.labelNote),
                    "value": property("string", "The \(noun)."),
                ],
                "required": ["value"],
            ],
            "description": .string("List of {label, value} objects with the \(noun)."),
        ]
    }

    private static let addressList: Value = [
        "type": "array",
        "items": [
            "type": "object",
            "properties": [
                "label": property("string", Self.labelNote),
                "street": property("string", "Street and number."),
                "city": property("string", "City."),
                "state": property("string", "State or region."),
                "postal_code": property("string", "Postal code."),
                "country": property("string", "Country."),
            ],
        ],
        "description": "List of postal addresses. Each has at least one of street, city, state, postal_code, country.",
    ]

    private static let birthdayNote = "Date as 2026-11-12, or --11-12 when the year is not known."

    public var tools: [ToolSpec] { Self.toolSpecs }

    public static var toolSpecs: [ToolSpec] {
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
            ToolSpec(
                name: "create_contact",
                description:
                    "Create a contact. Give 'given_name' or 'family_name' or 'organization'. Before it saves, it looks for a contact with the same full name or the same email. If it finds one, it refuses with AMBIGUOUS and shows the contact, unless 'allow_duplicate' is true. Notes are not supported.",
                properties: [
                    "given_name": Self.property("string", "First name."),
                    "family_name": Self.property("string", "Last name."),
                    "organization": Self.property("string", "Company or organization."),
                    "job_title": Self.property("string", "Job title."),
                    "emails": Self.labeledList("email address"),
                    "phones": Self.labeledList("phone number"),
                    "addresses": Self.addressList,
                    "birthday": Self.property("string", "Birthday. \(Self.birthdayNote)"),
                    "allow_duplicate": Self.property(
                        "boolean", "true to save even when a contact with the same name or email exists."),
                ],
                write: true),
            ToolSpec(
                name: "update_contact",
                description:
                    "Change a contact. Send only the fields to change. Text fields replace the old value, and an empty string clears them. Emails and phones change with 'add_emails', 'remove_emails', 'add_phones' and 'remove_phones' (remove by value). 'addresses' replaces all addresses, and [] removes them. The result has 'previous' with the old values of the fields you sent, so you can undo the change. Notes are not supported. macOS refuses to change a contact that has a note, unless the app has a special Apple entitlement. Then the tool returns an error and nothing changes.",
                properties: [
                    "id": Self.property("string", "Contact id from search_contacts. Use it as given."),
                    "given_name": Self.property("string", "New first name. Empty string clears it."),
                    "family_name": Self.property("string", "New last name. Empty string clears it."),
                    "organization": Self.property("string", "New organization. Empty string clears it."),
                    "job_title": Self.property("string", "New job title. Empty string clears it."),
                    "birthday": Self.property(
                        "string", "New birthday. \(Self.birthdayNote) Empty string clears it."),
                    "add_emails": Self.labeledList("email address to add"),
                    "remove_emails": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Email addresses to remove (ignores case).",
                    ],
                    "add_phones": Self.labeledList("phone number to add"),
                    "remove_phones": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Phone numbers to remove. Spaces and dashes do not matter.",
                    ],
                    "addresses": Self.addressList,
                ],
                required: ["id"], write: true),
            ToolSpec(
                name: "delete_contact",
                description:
                    "Delete a contact. It needs 'confirm' true. Without it, nothing is deleted, and the result shows the contact (name, emails, phones) so you can ask the user. The result of a delete has a full copy of the contact in 'contact', and in 'recreate' the arguments for create_contact, so the contact can be made again. Notes are not copied, because the app cannot read them. macOS refuses to delete a contact that has a note, unless the app has a special Apple entitlement. Then the tool returns an error and nothing changes. A contact linked from several cards (for example iCloud and Gmail) is refused: delete it in the Contacts app.",
                properties: [
                    "id": Self.property("string", "Contact id from search_contacts. Use it as given."),
                    "confirm": Self.property(
                        "boolean", "Must be true to delete the contact. Without it, nothing is deleted."),
                ],
                required: ["id"], destructive: true, idempotent: true),
        ]
    }

    // MARK: routing

    public func call(_ tool: String, _ args: Arguments) async throws -> ToolOutput {
        switch tool {
        case "search_contacts": return try await searchContacts(args)
        case "get_contact": return try await getContact(args)
        case "create_contact": return try await createContact(args)
        case "update_contact": return try await updateContact(args)
        case "delete_contact": return try await deleteContact(args)
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

    fileprivate struct Updated: Encodable {
        let contact: ContactInfo
        /// The old values of the fields in the request. An empty string or list means the field was empty.
        let previous: Previous
    }

    fileprivate struct Previous: Encodable {
        var givenName: String?
        var familyName: String?
        var organization: String?
        var jobTitle: String?
        var birthday: String?
        var emails: [LabeledValue]?
        var phones: [LabeledValue]?
        var addresses: [PostalAddress]?
    }

    fileprivate struct ConfirmNeeded: Encodable {
        let confirmRequired = true
        let contact: ContactInfo
    }

    fileprivate struct Deleted: Encodable {
        let deleted: String
        /// Every field that applesauce can read, in the shape of get_contact.
        let contact: ContactInfo
        /// The same fields as the arguments of create_contact.
        let recreate: Recreate
    }

    /// The arguments of create_contact. An empty list or a missing value is left out.
    fileprivate struct Recreate: Encodable {
        var givenName: String?
        var familyName: String?
        var organization: String?
        var jobTitle: String?
        var emails: [LabeledValue]?
        var phones: [LabeledValue]?
        var addresses: [PostalAddress]?
        var birthday: String?

        init(_ contact: ContactInfo) {
            givenName = contact.givenName
            familyName = contact.familyName
            organization = contact.organization
            jobTitle = contact.jobTitle
            emails = contact.emails.isEmpty ? nil : contact.emails
            phones = contact.phones.isEmpty ? nil : contact.phones
            addresses = (contact.addressDetails ?? []).isEmpty ? nil : contact.addressDetails
            birthday = contact.birthday
        }
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

// MARK: write tools

extension ContactsModule {
    fileprivate func createContact(_ args: Arguments) async throws -> ToolOutput {
        func text(_ key: String) throws -> String? {
            let value = try args.trimmed(key)
            return value?.isEmpty == true ? nil : value
        }
        var draft = NewContact(
            givenName: try text("given_name"), familyName: try text("family_name"),
            organization: try text("organization"), jobTitle: try text("job_title"))
        draft.emails = try args.labeledValues("emails", kind: .email) ?? []
        draft.phones = try args.labeledValues("phones", kind: .phone) ?? []
        draft.addresses = try args.postalAddresses("addresses") ?? []
        if case .set(let birthday)? = try args.birthday() { draft.birthday = birthday }
        let allowDuplicate = try args.bool("allow_duplicate") == true
        guard draft.givenName != nil || draft.familyName != nil || draft.organization != nil else {
            throw ToolError(
                .invalidInput, "A contact needs 'given_name', 'family_name' or 'organization'.",
                fix: "Give at least one of them.")
        }

        try await access()
        if !allowDuplicate {
            let all = try await backend { try await $0.allContacts() }
            let same = ContactEdit.duplicates(of: draft, in: all)
            if !same.isEmpty {
                let shown = same.prefix(3).map { "- " + Self.describe($0) }.joined(separator: "\n")
                throw ToolError(
                    .ambiguous,
                    "\(same.count) existing contact(s) have the same full name or email as the new one:\n\(shown)",
                    fix:
                        "Use update_contact with the id of the existing contact, or call create_contact again with 'allow_duplicate' true."
                )
            }
        }
        let new = draft
        let contact = try await backend { try await $0.create(new) }
        return try ToolOutput(text: "Created contact: " + Self.describe(contact), payload: contact)
    }

    fileprivate func updateContact(_ args: Arguments) async throws -> ToolOutput {
        let id = try args.requiredString("id").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ToolError.invalidInput("'id' is required.") }
        var patch = ContactPatch(
            givenName: try args.trimmed("given_name"), familyName: try args.trimmed("family_name"),
            organization: try args.trimmed("organization"), jobTitle: try args.trimmed("job_title"),
            birthday: try args.birthday())
        patch.addEmails = try args.labeledValues("add_emails", kind: .email) ?? []
        patch.removeEmails = try args.removeValues("remove_emails") ?? []
        patch.addPhones = try args.labeledValues("add_phones", kind: .phone) ?? []
        patch.removePhones = try args.removeValues("remove_phones") ?? []
        patch.addresses = try args.postalAddresses("addresses")
        guard patch != ContactPatch() else {
            throw ToolError.invalidInput("Give at least one field to change.")
        }

        try await access()
        guard let current = try await backend({ try await $0.contact(id: id) }) else {
            throw ToolError(
                .notFound, "No contact has the id '\(id)'.",
                fix: "Use an id from search_contacts. The contact may have been deleted.")
        }
        for value in patch.removeEmails
        where !current.emails.contains(where: { ContactEdit.sameEmail($0.value, value) }) {
            throw ToolError(
                .notFound, "The contact has no email address '\(value)'.",
                fix: "Use a value from the contact's emails: \(current.emails.map(\.value).joined(separator: ", ")).")
        }
        for value in patch.removePhones
        where !current.phones.contains(where: { ContactEdit.samePhone($0.value, value) }) {
            throw ToolError(
                .notFound, "The contact has no phone number '\(value)'.",
                fix: "Use a value from the contact's phones: \(current.phones.map(\.value).joined(separator: ", ")).")
        }
        guard ContactEdit.hasName(current, after: patch) else {
            throw ToolError(
                .invalidInput, "The change would leave the contact without a name.",
                fix: "Keep at least one of given_name, family_name or organization.")
        }

        let changes = patch
        let updated = try await backend { try await $0.update(id: id, changes) }
        var previous = Previous()
        if patch.givenName != nil { previous.givenName = current.givenName ?? "" }
        if patch.familyName != nil { previous.familyName = current.familyName ?? "" }
        if patch.organization != nil { previous.organization = current.organization ?? "" }
        if patch.jobTitle != nil { previous.jobTitle = current.jobTitle ?? "" }
        if patch.birthday != nil { previous.birthday = current.birthday ?? "" }
        if !patch.addEmails.isEmpty || !patch.removeEmails.isEmpty { previous.emails = current.emails }
        if !patch.addPhones.isEmpty || !patch.removePhones.isEmpty { previous.phones = current.phones }
        if patch.addresses != nil { previous.addresses = current.addressDetails ?? [] }
        return try ToolOutput(
            text: "Updated contact: " + Self.describe(updated) + ". The old values are in 'previous'.",
            payload: Updated(contact: updated, previous: previous))
    }
}

extension ContactsModule {
    fileprivate func deleteContact(_ args: Arguments) async throws -> ToolOutput {
        let id = try args.requiredString("id").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ToolError.invalidInput("'id' is required.") }
        let confirmed = try args.bool("confirm") == true

        try await access()
        guard let current = try await backend({ try await $0.contact(id: id) }) else {
            throw ToolError(
                .notFound, "No contact has the id '\(id)'.",
                fix: "Use an id from search_contacts. The contact may have been deleted.")
        }
        guard confirmed else {
            return try ToolOutput(
                text:
                    "Nothing deleted. This deletes the contact: \(Self.describe(current)). Ask the user, then call again with 'confirm' true.",
                payload: ConfirmNeeded(contact: current))
        }
        try await backend { try await $0.delete(id: id) }
        return try ToolOutput(
            text:
                "Deleted contact: \(Self.describe(current)). To undo, call create_contact with the fields in 'recreate'. The note is not copied.",
            payload: Deleted(deleted: current.id, contact: current, recreate: Recreate(current)))
    }
}
