import Foundation
import SQLite3
import Testing

@testable import AppleSauceCore

/// Makes a small database in a temp folder. The test never opens a real database.
struct TempDatabase {
    let folder: URL
    var path: String { folder.appendingPathComponent("test db #1.sqlite").path }

    init(_ statements: [String]) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "applesauce-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw ToolError(.internalError, "open failed") }
        defer { sqlite3_close(db) }
        for statement in statements {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
                throw ToolError(.internalError, "exec failed: \(statement)")
            }
        }
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

@Suite struct SQLiteReaderTests {
    func database() throws -> TempDatabase {
        try TempDatabase([
            "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, score REAL, note TEXT)",
            "INSERT INTO people (name, score, note) VALUES ('Ann', 1.5, NULL), ('Bob''s; DROP TABLE people', 2.5, 'x')",
        ])
    }

    @Test func readsRowsAndNulls() throws {
        let db = try database()
        defer { db.remove() }
        let reader = try SQLiteReader(path: db.path)
        let rows = try reader.rows("SELECT id, name, score, note FROM people ORDER BY id") {
            ($0.int(0), $0.text(1), $0.double(2), $0.text(3))
        }
        #expect(rows.count == 2)
        #expect(rows[0].1 == "Ann" && rows[0].2 == 1.5 && rows[0].3 == nil)
        #expect(rows[1].3 == "x")
    }

    @Test func valuesAreBoundNeverBuiltIn() throws {
        let db = try database()
        defer { db.remove() }
        let reader = try SQLiteReader(path: db.path)
        let hit = try reader.rows(
            "SELECT id FROM people WHERE name = ?", [.text("Bob's; DROP TABLE people")]
        ) { $0.int(0) }
        #expect(hit == [2])
        #expect(try reader.tableExists("people"))
        let number = try reader.rows("SELECT name FROM people WHERE id = ? AND score > ?", [.integer(1), .real(1.0)]) {
            $0.text(0)
        }
        #expect(number == ["Ann"])
    }

    @Test func checksTablesAndColumns() throws {
        let db = try database()
        defer { db.remove() }
        let reader = try SQLiteReader(path: db.path)
        #expect(try reader.tableExists("people"))
        #expect(try reader.tableExists("nothing") == false)
        #expect(try reader.columns(of: "people") == ["id", "name", "score", "note"])
        #expect(try reader.missingColumns(in: "people", ["name", "age", "city"]) == ["age", "city"])
        #expect(try reader.missingColumns(in: "nothing", ["a"]) == ["a"])
    }

    @Test func cannotWrite() throws {
        let db = try database()
        defer { db.remove() }
        let reader = try SQLiteReader(path: db.path)
        #expect(throws: ToolError.self) {
            _ = try reader.rows("INSERT INTO people (name) VALUES ('x')") { _ in 0 }
        }
        let count = try reader.rows("SELECT COUNT(*) FROM people") { $0.int(0) }
        #expect(count == [2])
    }

    @Test func missingFileIsNotCreated() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("applesauce-none-\(UUID()).sqlite")
            .path
        #expect(throws: ToolError.self) { _ = try SQLiteReader(path: path) }
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test func badSQLIsAnInternalError() throws {
        let db = try database()
        defer { db.remove() }
        let reader = try SQLiteReader(path: db.path)
        do {
            _ = try reader.rows("SELECT nope FROM people") { _ in 0 }
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("nope"))
        }
    }

    @Test func permissionCodesMapToFullDiskAccess() {
        let denied = SQLiteReader.failure(code: SQLITE_CANTOPEN, system: EPERM, message: nil, name: "Envelope Index")
        #expect(denied.code == .permissionDenied)
        #expect(denied.fix == Permission.fullDiskAccess.fix(for: .denied))
        #expect(SQLiteReader.failure(code: SQLITE_AUTH, system: 0, message: nil, name: "x").code == .permissionDenied)
        #expect(SQLiteReader.failure(code: SQLITE_CANTOPEN, system: ENOENT, message: nil, name: "x").code == .notFound)
        #expect(SQLiteReader.failure(code: SQLITE_BUSY, system: 0, message: nil, name: "x").code == .timeout)
    }
}
