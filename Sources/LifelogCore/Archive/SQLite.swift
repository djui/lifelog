import Foundation
import SQLite3

/// A small read-write SQLite connection for the archive's own databases: the index cache and `_archive.sqlite`.
/// (WhatsApp's database is read with the read-only `SQLiteDB`.)
final class SQLite {
    enum Value {
        case null, int(Int64), double(Double), text(String), blob(Data)
    }

    struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
        func blob(_ column: Int32) -> Data? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: count)
        }
    }

    /// A prepared statement, reused for many rows.
    final class Statement {
        let handle: OpaquePointer
        let database: SQLite

        init(_ database: SQLite, _ sql: String) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database.handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw database.error(sql) }
            handle = statement; self.database = database
        }

        deinit { sqlite3_finalize(handle) }

        func run(_ values: [Value]) throws { try query(values) { _ in } }

        func query(_ values: [Value], _ body: (Row) throws -> Void) throws {
            sqlite3_reset(handle)
            sqlite3_clear_bindings(handle)
            for (index, value) in values.enumerated() {
                let position = Int32(index + 1)
                let status: Int32
                switch value {
                case .null: status = sqlite3_bind_null(handle, position)
                case .int(let number): status = sqlite3_bind_int64(handle, position, number)
                case .double(let number): status = sqlite3_bind_double(handle, position, number)
                case .text(let text): status = sqlite3_bind_text(handle, position, text, -1, SQLite.transient)
                case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(handle, position, $0.baseAddress, Int32(data.count), SQLite.transient) }
                }
                guard status == SQLITE_OK else { throw database.error("bind") }
            }
            while true {
                let step = sqlite3_step(handle)
                if step == SQLITE_DONE { return }
                guard step == SQLITE_ROW else { throw database.error("step") }
                try body(Row(statement: handle))
            }
        }
    }

    fileprivate static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    fileprivate let handle: OpaquePointer
    let url: URL

    init(_ url: URL, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw ExportError.message("Cannot open \(url.lastPathComponent): \(message)")
        }
        handle = db; self.url = url
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close(handle) }

    func error(_ context: String) -> ExportError {
        .message("SQLite error in \(url.lastPathComponent) (\(context.prefix(60))): \(String(cString: sqlite3_errmsg(handle)))")
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error(sql) }
    }

    func prepare(_ sql: String) throws -> Statement { try Statement(self, sql) }

    func run(_ sql: String, _ values: [Value] = []) throws { try prepare(sql).run(values) }

    func query(_ sql: String, _ values: [Value] = [], _ body: (Row) throws -> Void) throws { try prepare(sql).query(values, body) }

    /// Runs `body` in one transaction: all of it or none of it.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
