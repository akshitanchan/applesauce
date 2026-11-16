import Foundation

/// Decides whether a contact matches a search query. Pure, so tests need no address book.
///
/// - Text query: every word must appear (any case, any accent) somewhere in the name,
///   organization or an email address.
/// - Phone query (only digits and `+ - ( ) . space`, at least 3 digits): the digits must appear in a phone number.
enum ContactMatcher {
    static func matches(_ contact: ContactInfo, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }

        let haystack = ([contact.name, contact.organization].compactMap { $0 } + contact.emails.map(\.value))
            .joined(separator: "\n")
        if words.allSatisfy({ haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
            return true
        }

        guard let wanted = phoneDigits(query) else { return false }
        return contact.phones.contains { digits(in: $0.value).contains(wanted) }
    }

    /// The digits of a phone-like query, or nil when the query is not phone-like.
    static func phoneDigits(_ query: String) -> String? {
        let allowed = Set("+-(). 0123456789")
        guard query.allSatisfy({ allowed.contains($0) }) else { return nil }
        let found = digits(in: query)
        return found.count >= 3 ? found : nil
    }

    private static func digits(in text: String) -> String {
        String(text.filter(\.isASCII).filter(\.isNumber))
    }
}
