import AppleSauceCore
import Foundation
import MCP

/// Input checks for the contact write tools.
extension Arguments {
    enum ValueKind {
        case email, phone

        var noun: String { self == .email ? "email address" : "phone number" }
    }

    /// A text field. Outer spaces are removed. Returns nil when the argument is missing.
    /// An empty text stays empty, because an update uses it to clear the field.
    func trimmed(_ key: String) throws -> String? {
        try string(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An array of `{label, value}` objects, for `emails`, `phones` and the `add_` arguments.
    func labeledValues(_ key: String, kind: ValueKind) throws -> [LabeledValue]? {
        guard let value = raw[key], !value.isNull else { return nil }
        let shape = "'\(key)' must be an array of objects like {\"label\": \"work\", \"value\": \"...\"}."
        guard let items = value.arrayValue else { throw ToolError.invalidInput(shape) }
        return try items.map { item in
            guard let object = item.objectValue else { throw ToolError.invalidInput(shape) }
            let inner = Arguments(object)
            guard let text = try inner.trimmed("value"), !text.isEmpty else {
                throw ToolError.invalidInput("Every item in '\(key)' needs a 'value' (an \(kind.noun)).")
            }
            if kind == .email && !ContactEdit.looksLikeEmail(text) {
                throw ToolError(
                    .invalidInput, "'\(text)' is not a valid email address.",
                    fix: "Use an address like name@example.com.")
            }
            let label = try inner.trimmed("label")
            return LabeledValue(label: label?.isEmpty == true ? nil : label, value: text)
        }
    }

    /// Values to remove, for the `remove_` arguments.
    func removeValues(_ key: String) throws -> [String]? {
        guard
            let items = try stringArray(key)?.map({ $0.trimmingCharacters(in: .whitespaces) })
        else { return nil }
        guard items.allSatisfy({ !$0.isEmpty }) else {
            throw ToolError.invalidInput("'\(key)' must not have empty values.")
        }
        return items
    }

    /// An array of postal address objects.
    func postalAddresses(_ key: String) throws -> [PostalAddress]? {
        guard let value = raw[key], !value.isNull else { return nil }
        let shape =
            "'\(key)' must be an array of objects with 'label', 'street', 'city', 'state', 'postal_code' and 'country'."
        guard let items = value.arrayValue else { throw ToolError.invalidInput(shape) }
        return try items.map { item in
            guard let object = item.objectValue else { throw ToolError.invalidInput(shape) }
            let inner = Arguments(object)
            func part(_ name: String) throws -> String? {
                let text = try inner.trimmed(name)
                return text?.isEmpty == true ? nil : text
            }
            let address = PostalAddress(
                label: try part("label"), street: try part("street"), city: try part("city"),
                state: try part("state"), postalCode: try part("postal_code"), country: try part("country"))
            guard
                [address.street, address.city, address.state, address.postalCode, address.country]
                    .contains(where: { $0 != nil })
            else {
                throw ToolError.invalidInput(
                    "Every address in '\(key)' needs at least one of street, city, state, postal_code or country.")
            }
            return address
        }
    }

    /// `2026-11-12`, or `--11-12` without a year. An empty text means clear (only for updates).
    func birthday() throws -> BirthdayChange? {
        guard let text = try trimmed("birthday") else { return nil }
        if text.isEmpty { return .clear }
        guard let parsed = BirthdayParser.parse(text) else {
            throw ToolError(
                .invalidInput, "'birthday' is not a valid date: '\(text)'.",
                fix: "Use 2026-11-12, or --11-12 when the year is not known.")
        }
        return .set(parsed)
    }
}
