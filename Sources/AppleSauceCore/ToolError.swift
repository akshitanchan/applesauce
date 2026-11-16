import Foundation

/// The one error shape that every tool returns: `{code, message, fix}`.
/// `fix` tells the user what to do next.
public struct ToolError: Error, Equatable, Sendable, Codable {
    public enum Code: String, Codable, Sendable {
        case permissionDenied = "PERMISSION_DENIED"
        case permissionTimeout = "PERMISSION_TIMEOUT"
        case appNotRunning = "APP_NOT_RUNNING"
        case notFound = "NOT_FOUND"
        case ambiguous = "AMBIGUOUS"
        case timeout = "TIMEOUT"
        case invalidInput = "INVALID_INPUT"
        case unknownTool = "UNKNOWN_TOOL"
        case readOnly = "READ_ONLY"
        case internalError = "INTERNAL_ERROR"
    }

    public let code: Code
    public let message: String
    public let fix: String?

    public init(_ code: Code, _ message: String, fix: String? = nil) {
        self.code = code
        self.message = message
        self.fix = fix
    }

    public static func invalidInput(_ message: String) -> ToolError {
        ToolError(.invalidInput, message, fix: "Check the tool's input schema and try again.")
    }

    /// JSON text of the error, for the tool result content.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return #"{"code":"INTERNAL_ERROR","message":"could not encode error"}"#
        }
        return text
    }
}
