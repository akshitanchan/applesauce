import Foundation

/// Pure rules for contact writes. Tests need no address book.
enum ContactEdit {
    /// Two email addresses are the same when they match without regard to case and outer spaces.
    static func sameEmail(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces))
            == .orderedSame
    }

    /// Two phone numbers are the same when their digits are the same (spaces, dashes and brackets do not count).
    /// Text without digits must match as it is.
    static func samePhone(_ a: String, _ b: String) -> Bool {
        let (x, y) = (digits(a), digits(b))
        if x.isEmpty || y.isEmpty {
            return a.trimmingCharacters(in: .whitespaces) == b.trimmingCharacters(in: .whitespaces)
        }
        return x == y
    }

    private static func digits(_ text: String) -> String {
        String(text.filter(\.isASCII).filter(\.isNumber))
    }

    /// A loose email check: no spaces, one `@`, text before it, and a dot inside the domain.
    static func looksLikeEmail(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    /// Words of a name without case, accents and order.
    private static func words(_ name: String) -> [String] {
        name.split(whereSeparator: \.isWhitespace)
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
            .sorted()
    }

    /// Existing contacts that look like the new one: the same full name, or the same email address.
    static func duplicates(of draft: NewContact, in contacts: [ContactInfo]) -> [ContactInfo] {
        let person = words([draft.givenName, draft.familyName].compactMap { $0 }.joined(separator: " "))
        let organization = draft.organization.map { words($0) } ?? []
        return contacts.filter { contact in
            let name = words(contact.name)
            if !person.isEmpty {
                if name == person { return true }
            } else if !organization.isEmpty, name == organization {
                return true
            }
            return draft.emails.contains { new in contact.emails.contains { sameEmail($0.value, new.value) } }
        }
    }

    /// The names of the contact after the patch. Used to refuse a patch that leaves the contact without a name.
    static func hasName(_ contact: ContactInfo, after patch: ContactPatch) -> Bool {
        func result(_ change: String?, _ old: String?) -> String {
            (change ?? old ?? "").trimmingCharacters(in: .whitespaces)
        }
        return !result(patch.givenName, contact.givenName).isEmpty
            || !result(patch.familyName, contact.familyName).isEmpty
            || !result(patch.organization, contact.organization).isEmpty
    }
}

/// Parses a birthday: `2026-11-12`, or `--11-12` when the year is not known.
enum BirthdayParser {
    static func parse(_ text: String) -> Birthday? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let parts: [String]
        var year: Int?
        if text.hasPrefix("--") {
            parts = text.dropFirst(2).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
        } else {
            let all = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard all.count == 3, all[0].count == 4, let value = Int(all[0]), value >= 1 else { return nil }
            year = value
            parts = Array(all.dropFirst())
        }
        guard parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) }),
            let month = Int(parts[0]), let day = Int(parts[1])
        else { return nil }
        // A birthday without a year may be 29 February. Check it against a leap year.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let check = DateComponents(year: year ?? 2000, month: month, day: day)
        guard let date = calendar.date(from: check) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.month == month, back.day == day, back.year == (year ?? 2000) else { return nil }
        return Birthday(year: year, month: month, day: day)
    }
}
