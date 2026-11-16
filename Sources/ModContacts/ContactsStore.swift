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
    /// The name parts. Only `get_contact` and the results of the write tools fill them.
    var givenName: String?
    var familyName: String?
    /// The postal addresses as separate parts. Only `get_contact` and the results of the write tools fill them.
    var addressDetails: [PostalAddress]?
}

/// A postal address with its parts. A part that is empty is nil.
struct PostalAddress: Encodable, Sendable, Equatable {
    var label: String?
    var street: String?
    var city: String?
    var state: String?
    var postalCode: String?
    var country: String?
}

/// A birthday. The year is optional.
struct Birthday: Sendable, Equatable {
    var year: Int?
    var month: Int
    var day: Int

    /// `2026-11-12`, or `--11-12` when the year is not set. The same text that `get_contact` shows.
    var text: String {
        let monthDay = String(format: "%02d-%02d", month, day)
        guard let year else { return "--" + monthDay }
        return String(format: "%04d-", year) + monthDay
    }
}

/// A new contact for `create_contact`. A text field that is not given is nil.
struct NewContact: Sendable, Equatable {
    var givenName: String?
    var familyName: String?
    var organization: String?
    var jobTitle: String?
    var emails: [LabeledValue] = []
    var phones: [LabeledValue] = []
    var addresses: [PostalAddress] = []
    var birthday: Birthday?
}

enum BirthdayChange: Sendable, Equatable {
    case set(Birthday)
    case clear
}

/// Changes for `update_contact`. A nil field stays as it is. For a text field an empty string clears the value.
struct ContactPatch: Sendable, Equatable {
    var givenName: String?
    var familyName: String?
    var organization: String?
    var jobTitle: String?
    var birthday: BirthdayChange?
    var addEmails: [LabeledValue] = []
    /// Email values to remove.
    var removeEmails: [String] = []
    var addPhones: [LabeledValue] = []
    /// Phone numbers to remove.
    var removePhones: [String] = []
    /// Replaces all addresses. An empty array removes them.
    var addresses: [PostalAddress]?
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
    /// Saves a new contact and returns it with all fields.
    func create(_ contact: NewContact) async throws -> ContactInfo
    /// Applies the changes and returns the contact with all fields. The id must exist.
    func update(id: String, _ patch: ContactPatch) async throws -> ContactInfo
}
