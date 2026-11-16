import AppleSauceCore
import Contacts
import Foundation

/// The real contacts store. It is the only code that touches the Contacts framework.
/// `CNContact` objects stay inside this actor. Only plain structs leave it.
actor CNContactsStore: ContactsStore {
    private let store = CNContactStore()
    /// The last full read, and the history token it belongs to. Any change to Contacts changes the token.
    private var cache: (token: Data, contacts: [ContactInfo])?

    nonisolated func accessState() -> PermissionState {
        SystemPermissionChecker().state(of: .contacts)
    }

    /// Uses the completion handler form. The async form sends the store out of this actor, which Swift 6.1 rejects.
    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
    }

    /// Keys for search: names, organization, emails and phones.
    private func summaryKeys() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
    }

    /// Keys for one contact. There is no note key: it needs a special entitlement.
    private func detailKeys() -> [CNKeyDescriptor] {
        summaryKeys() + [
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
        ]
    }

    func allContacts() async throws -> [ContactInfo] {
        let token = store.currentHistoryToken
        if let cache, let token, cache.token == token { return cache.contacts }
        let request = CNContactFetchRequest(keysToFetch: summaryKeys())
        request.unifyResults = true
        var found: [ContactInfo] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                found.append(Self.info(contact, detailed: false))
            }
        } catch {
            throw Self.failure(error)
        }
        if let token { cache = (token, found) }
        return found
    }

    func contact(id: String) async throws -> ContactInfo? {
        do {
            return Self.info(try store.unifiedContact(withIdentifier: id, keysToFetch: detailKeys()), detailed: true)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            return nil
        } catch {
            throw Self.failure(error)
        }
    }

    private static func failure(_ error: Error) -> ToolError {
        ToolError(
            .internalError, "The Contacts framework failed: \(error.localizedDescription)",
            fix: "Call the 'doctor' tool. If the error stays, report it.")
    }

    private static func info(_ contact: CNContact, detailed: Bool) -> ContactInfo {
        let organization = contact.organizationName.isEmpty ? nil : contact.organizationName
        let fullName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        var info = ContactInfo(
            id: contact.identifier,
            name: fullName.isEmpty ? (organization ?? "(no name)") : fullName)
        info.organization = organization
        info.emails = contact.emailAddresses.map { labeled($0.label, $0.value as String) }
        info.phones = contact.phoneNumbers.map { labeled($0.label, $0.value.stringValue) }
        guard detailed else { return info }

        info.jobTitle = contact.jobTitle.isEmpty ? nil : contact.jobTitle
        info.addresses = contact.postalAddresses.compactMap { item in
            let text = CNPostalAddressFormatter.string(from: item.value, style: .mailingAddress)
                .split(separator: "\n").joined(separator: ", ")
            return text.isEmpty ? nil : labeled(item.label, text)
        }
        info.birthday = contact.birthday.flatMap(birthdayText)
        return info
    }

    private static func labeled(_ label: String?, _ value: String) -> LabeledValue {
        LabeledValue(label: label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) }, value: value)
    }

    /// Date only. `--MM-DD` when the year is not set.
    static func birthdayText(_ parts: DateComponents) -> String? {
        guard let month = parts.month, let day = parts.day else { return nil }
        let monthDay = String(format: "%02d-%02d", month, day)
        guard let year = parts.year, year != NSDateComponentUndefined else { return "--" + monthDay }
        return String(format: "%04d-", year) + monthDay
    }
}
