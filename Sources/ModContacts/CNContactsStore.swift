// The real contacts store. The Contacts framework exists on macOS only.
#if os(macOS)
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
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
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
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
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
            return Self.info(
                try store.unifiedContact(withIdentifier: id, keysToFetch: detailKeys()), detailed: true)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            return nil
        } catch {
            throw Self.failure(error)
        }
    }

    func create(_ draft: NewContact) async throws -> ContactInfo {
        let contact = CNMutableContact()
        contact.givenName = draft.givenName ?? ""
        contact.familyName = draft.familyName ?? ""
        contact.organizationName = draft.organization ?? ""
        contact.jobTitle = draft.jobTitle ?? ""
        contact.emailAddresses = draft.emails.map { Self.emailItem($0) }
        contact.phoneNumbers = draft.phones.map { Self.phoneItem($0) }
        contact.postalAddresses = draft.addresses.map { Self.addressItem($0) }
        contact.birthday = draft.birthday.map(Self.components)
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try execute(request)
        // The saved contact is the truth. The local object is the fallback.
        return (try? fetch(contact.identifier)).map { Self.info($0, detailed: true) }
            ?? Self.info(contact, detailed: true)
    }

    func update(id: String, _ patch: ContactPatch) async throws -> ContactInfo {
        let fetched: CNContact
        do {
            fetched = try fetch(id)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            throw ToolError(
                .notFound, "No contact has the id '\(id)'.", fix: "Use an id from search_contacts.")
        } catch {
            throw Self.failure(error)
        }
        guard let contact = fetched.mutableCopy() as? CNMutableContact else {
            throw ToolError(.internalError, "The Contacts framework gave no editable copy.", fix: "Report this error.")
        }
        if let value = patch.givenName { contact.givenName = value }
        if let value = patch.familyName { contact.familyName = value }
        if let value = patch.organization { contact.organizationName = value }
        if let value = patch.jobTitle { contact.jobTitle = value }
        switch patch.birthday {
        case .set(let birthday)?: contact.birthday = Self.components(birthday)
        case .clear?: contact.birthday = nil
        case nil: break
        }
        var emails = contact.emailAddresses.filter { item in
            !patch.removeEmails.contains { ContactEdit.sameEmail(item.value as String, $0) }
        }
        for new in patch.addEmails
        where !emails.contains(where: { ContactEdit.sameEmail($0.value as String, new.value) }) {
            emails.append(Self.emailItem(new))
        }
        if !patch.addEmails.isEmpty || !patch.removeEmails.isEmpty { contact.emailAddresses = emails }
        var phones = contact.phoneNumbers.filter { item in
            !patch.removePhones.contains { ContactEdit.samePhone(item.value.stringValue, $0) }
        }
        for new in patch.addPhones
        where !phones.contains(where: { ContactEdit.samePhone($0.value.stringValue, new.value) }) {
            phones.append(Self.phoneItem(new))
        }
        if !patch.addPhones.isEmpty || !patch.removePhones.isEmpty { contact.phoneNumbers = phones }
        if let addresses = patch.addresses { contact.postalAddresses = addresses.map { Self.addressItem($0) } }

        let request = CNSaveRequest()
        request.update(contact)
        try execute(request)
        let saved = try fetch(id)
        return Self.info(saved, detailed: true)
    }

    func delete(id: String) async throws {
        let fetched: CNContact
        do {
            fetched = try fetch(id)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            throw ToolError(
                .notFound, "No contact has the id '\(id)'.", fix: "Use an id from search_contacts.")
        } catch {
            throw Self.failure(error)
        }
        let cards = linkedCardCount(of: fetched)
        guard cards <= 1 else {
            throw ToolError(
                .invalidInput,
                "This contact is linked from \(cards) cards (for example iCloud and Gmail). A delete could remove all of them. Nothing was deleted.",
                fix: "Delete it in the Contacts app, where you can see each linked card.")
        }
        guard let contact = fetched.mutableCopy() as? CNMutableContact else {
            throw ToolError(.internalError, "The Contacts framework gave no editable copy.", fix: "Report this error.")
        }
        let request = CNSaveRequest()
        request.delete(contact)
        try execute(request, verb: "delete")
    }

    /// The number of separate cards that Contacts shows as this one contact. The cards are found by name, then
    /// kept only when the contact says it is unified with them.
    private func linkedCardCount(of contact: CNContact) -> Int {
        let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let search = name.isEmpty ? contact.organizationName : name
        guard !search.isEmpty else { return 1 }
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        request.predicate = CNContact.predicateForContacts(matchingName: search)
        request.unifyResults = false
        var count = 0
        try? store.enumerateContacts(with: request) { card, _ in
            if card.identifier == contact.identifier || contact.isUnifiedWithContact(withIdentifier: card.identifier) {
                count += 1
            }
        }
        return max(count, 1)
    }

    private func fetch(_ id: String) throws -> CNContact {
        try store.unifiedContact(withIdentifier: id, keysToFetch: detailKeys())
    }

    /// Runs a save request. Contacts must not return a stale list after it.
    private func execute(_ request: CNSaveRequest, verb: String = "change") throws {
        cache = nil
        do {
            try store.execute(request)
        } catch {
            throw Self.saveFailure(error, verb: verb)
        }
    }

    /// macOS refuses to save a contact that has a note when the app has no notes entitlement (error 134092).
    /// `verb` is `change` or `delete`. It words the message.
    static func saveFailure(_ error: Error, verb: String = "change") -> ToolError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == 134092 {
            return ToolError(
                .permissionDenied,
                "macOS refuses to \(verb) this contact. It has a note, and only apps with the Apple Contacts notes entitlement can save such a contact.",
                fix:
                    "\(verb.capitalized) this contact in the Contacts app. Nothing was \(verb == "delete" ? "deleted" : "changed")."
            )
        }
        return ToolError(
            .internalError,
            "The Contacts framework could not \(verb == "delete" ? "delete the contact" : "save the change"): \(error.localizedDescription)",
            fix: "Call the 'doctor' tool. If the error stays, report it.")
    }

    private static func components(_ birthday: Birthday) -> DateComponents {
        DateComponents(
            calendar: Calendar(identifier: .gregorian), year: birthday.year, month: birthday.month, day: birthday.day)
    }

    private static func emailItem(_ item: LabeledValue) -> CNLabeledValue<NSString> {
        CNLabeledValue(label: label(item.label, kind: .email), value: item.value as NSString)
    }

    private static func phoneItem(_ item: LabeledValue) -> CNLabeledValue<CNPhoneNumber> {
        CNLabeledValue(label: label(item.label, kind: .phone), value: CNPhoneNumber(stringValue: item.value))
    }

    private static func addressItem(_ address: PostalAddress) -> CNLabeledValue<CNPostalAddress> {
        let value = CNMutablePostalAddress()
        value.street = address.street ?? ""
        value.city = address.city ?? ""
        value.state = address.state ?? ""
        value.postalCode = address.postalCode ?? ""
        value.country = address.country ?? ""
        return CNLabeledValue(label: label(address.label, kind: .address), value: value)
    }

    private enum LabelKind { case email, phone, address }

    /// Known names (any case) become the system labels. Other text is a custom label.
    private static func label(_ text: String?, kind: LabelKind) -> String? {
        guard let text, !text.isEmpty else { return nil }
        switch text.lowercased() {
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "other": return CNLabelOther
        case "icloud" where kind == .email: return CNLabelEmailiCloud
        case "mobile" where kind == .phone: return CNLabelPhoneNumberMobile
        case "iphone" where kind == .phone: return CNLabelPhoneNumberiPhone
        case "main" where kind == .phone: return CNLabelPhoneNumberMain
        case "home fax" where kind == .phone: return CNLabelPhoneNumberHomeFax
        case "work fax" where kind == .phone: return CNLabelPhoneNumberWorkFax
        case "pager" where kind == .phone: return CNLabelPhoneNumberPager
        default: return text
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
        info.givenName = contact.givenName.isEmpty ? nil : contact.givenName
        info.familyName = contact.familyName.isEmpty ? nil : contact.familyName
        info.addressDetails = contact.postalAddresses.map { item in
            func part(_ text: String) -> String? { text.isEmpty ? nil : text }
            let address = item.value
            return PostalAddress(
                label: item.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) },
                street: part(address.street), city: part(address.city), state: part(address.state),
                postalCode: part(address.postalCode), country: part(address.country))
        }
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
#endif
