import Foundation
import SQLite3

/// A value that is bound to a `?` placeholder.
public enum SQLiteValue: Sendable, Equatable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
}

/// One result row. Columns count from 0. A SQL NULL gives nil.
public struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    public func int(_ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    public func double(_ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }

    public func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let bytes = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: bytes)
    }
}

/// A small read-only SQLite reader (the system `SQLite3` library).
///
/// - It opens the file read-only (`mode=ro`). It never writes. It does not use `immutable=1`,
///   because that ignores the write-ahead log and gives stale data.
/// - Values go only through `?` placeholders. Never build SQL text from user values.
/// - Every failure is a `ToolError`. A file that macOS does not let applesauce read gives `PERMISSION_DENIED`
///   with the Full Disk Access fix.
/// - One reader serves one caller at a time. Open a new reader for each call.
public final class SQLiteReader: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let name: String

    /// - Parameters:
    ///   - path: absolute path of the database file.
    ///   - busyTimeout: milliseconds to wait when another process holds a lock.
    public init(path: String, busyTimeout: Int32 = 5000) throws {
        self.name = (path as NSString).lastPathComponent
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var opened: OpaquePointer?
        let code = sqlite3_open_v2("file:\(encoded)?mode=ro", &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard code == SQLITE_OK, let opened else {
            let system = opened.map { sqlite3_system_errno($0) } ?? 0
            if let opened { sqlite3_close(opened) }
            throw Self.failure(code: code, system: system, message: nil, name: name)
        }
        sqlite3_busy_timeout(opened, busyTimeout)
        self.handle = opened
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// Runs a query and maps each row.
    public func rows<T>(
        _ sql: String, _ bindings: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        guard let handle else { throw ToolError(.internalError, "The database is closed.", fix: "Report this error.") }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw fail(prepared)
        }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT: SQLite copies the text before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
            case .real(let number): code = sqlite3_bind_double(statement, index, number)
            case .text(let text): code = sqlite3_bind_text(statement, index, text, -1, transient)
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw fail(code) }
        }

        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                result.append(try map(SQLiteRow(statement: statement)))
            } else if step == SQLITE_DONE {
                return result
            } else {
                throw fail(step)
            }
        }
    }

    public func tableExists(_ table: String) throws -> Bool {
        try rows(
            "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?", [.text(table)]
        ) { $0.int(0) }.isEmpty == false
    }

    /// Column names of a table (empty when the table does not exist). The table name is bound, not built in.
    public func columns(of table: String) throws -> Set<String> {
        Set(try rows("SELECT name FROM pragma_table_info(?)", [.text(table)]) { $0.text(0) ?? "" })
    }

    /// The wanted columns that the table does not have (all of them when the table does not exist).
    public func missingColumns(in table: String, _ wanted: [String]) throws -> [String] {
        let present = try columns(of: table)
        return wanted.filter { !present.contains($0) }
    }

    private func fail(_ code: Int32) -> ToolError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) }
        let system = handle.map { sqlite3_system_errno($0) } ?? 0
        return Self.failure(code: code, system: system, message: message, name: name)
    }

    /// Turns a SQLite result code into a `ToolError`.
    static func failure(code: Int32, system: Int32, message: String?, name: String) -> ToolError {
        let detail = message.map { ": \($0)" } ?? ""
        let primary = code & 0xFF
        if primary == SQLITE_AUTH || primary == SQLITE_PERM || system == EPERM || system == EACCES {
            return ToolError(
                .permissionDenied, "macOS does not let applesauce read '\(name)' (SQLite code \(code)).",
                fix: Permission.fullDiskAccess.fix(for: .denied) ?? "Grant Full Disk Access.")
        }
        if primary == SQLITE_CANTOPEN && system == ENOENT {
            return ToolError(
                .notFound, "The database file '\(name)' does not exist.", fix: "Check that the app has data.")
        }
        if primary == SQLITE_BUSY || primary == SQLITE_LOCKED {
            return ToolError(
                .timeout, "The database '\(name)' stayed locked.", fix: "Try again in a few seconds.")
        }
        return ToolError(
            .internalError, "Could not read the database '\(name)' (SQLite code \(code))\(detail).",
            fix: "Report this error.")
    }
}
