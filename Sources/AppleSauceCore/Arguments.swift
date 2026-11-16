import Foundation
import MCP

/// Typed access to tool call arguments.
/// Every getter throws `INVALID_INPUT` with a clear message on a bad value,
/// so a module checks its input before it touches any app or permission.
public struct Arguments: Sendable {
    public let raw: [String: Value]

    public init(_ raw: [String: Value]?) {
        self.raw = raw ?? [:]
    }

    public func string(_ key: String) throws -> String? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let text = value.stringValue else {
            throw ToolError.invalidInput("'\(key)' must be a string.")
        }
        return text
    }

    public func requiredString(_ key: String) throws -> String {
        guard let text = try string(key), !text.isEmpty else {
            throw ToolError.invalidInput("'\(key)' is required.")
        }
        return text
    }

    public func int(_ key: String) throws -> Int? {
        guard let value = raw[key], !value.isNull else { return nil }
        if let number = value.intValue { return number }
        // Some clients send whole numbers as doubles.
        if let number = value.doubleValue, number.rounded() == number, abs(number) < 1e15 {
            return Int(number)
        }
        throw ToolError.invalidInput("'\(key)' must be an integer.")
    }

    public func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        let number = try int(key) ?? fallback
        guard range.contains(number) else {
            throw ToolError.invalidInput("'\(key)' must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return number
    }

    public func bool(_ key: String) throws -> Bool? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let flag = value.boolValue else {
            throw ToolError.invalidInput("'\(key)' must be true or false.")
        }
        return flag
    }

    public func stringArray(_ key: String) throws -> [String]? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let items = value.arrayValue else {
            throw ToolError.invalidInput("'\(key)' must be an array of strings.")
        }
        return try items.map {
            guard let text = $0.stringValue else {
                throw ToolError.invalidInput("'\(key)' must be an array of strings.")
            }
            return text
        }
    }

    /// A URL argument. Returns the text as given. An empty string passes (updates use it to clear a field).
    /// Throws `INVALID_INPUT` when the text is not an absolute URL such as `https://example.com`.
    public func url(_ key: String) throws -> String? {
        guard let text = try string(key) else { return nil }
        if text.isEmpty { return text }
        guard let url = URL(string: text), url.scheme != nil else {
            throw ToolError(
                .invalidInput, "'\(key)' is not a valid URL: '\(text)'.",
                fix: "Use a full URL, for example https://example.com.")
        }
        return text
    }
}
