import Foundation
import MCP

extension ToolOutput {
    /// Text for the model plus a structured JSON payload.
    /// Keys become snake_case (`allDay` is `all_day`). Dates become ISO 8601 with an offset. Nil fields are left out.
    public init<Payload: Encodable>(text: String, payload: Payload) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISODate.string(date))
        }
        do {
            let data = try encoder.encode(payload)
            self.init(text: text, structured: try JSONDecoder().decode(Value.self, from: data))
        } catch {
            throw ToolError(
                .internalError, "Could not encode the result: \(error)",
                fix: "Report this error.")
        }
    }
}
