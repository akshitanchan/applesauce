import AppleSauceCore
import Foundation

/// A value with a label, for example a phone number labelled "mobile".
struct LabeledValue: Encodable, Sendable, Equatable {
    /// The label in the user's language, or nil when the contact has none.
    let label: String?
    let value: String
}

/// One contact. `search_contacts` fills the summary fields. `get_contact` fills all of them.
/// The note field is left out on purpose: reading it needs a special Apple entitlement.
struct ContactInfo: Encodable, Sendable, Equatable {
    let id: String
    /// The full name. For a contact with only an organization, the organization.
    let name: String
    var organization: String?
    var jobTitle: String?
    var emails: [LabeledValue] = []
    var phones: [LabeledValue] = []
    var addresses: [LabeledValue] = []
    /// `2026-11-12`, or `--11-12` when the year is not set.
    var birthday: String?
}

/// The only way the contacts module reaches the address book.
/// The real store uses the Contacts framework. Tests use a fake.
protocol ContactsStore: Sendable {
    func accessState() -> PermissionState
    func requestAccess() async throws -> Bool
    /// All contacts with the summary fields (name, organization, emails, phones).
    func allContacts() async throws -> [ContactInfo]
    /// One contact with all fields, or nil when the id is unknown.
    func contact(id: String) async throws -> ContactInfo?
}
