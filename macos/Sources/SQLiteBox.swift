import Foundation
import SQLite3

final class SQLiteBox {
    var db: OpaquePointer?

    func open(_ path: String, readonly: Bool) throws {
        close()
        // WAL 库用 mode=ro 时无法创建 -shm，会误报 unable to open database file。
        // 已有文件一律读写打开；只读场景再开 query_only，避免改数据。
        var flags = SQLITE_OPEN_READWRITE
        if !readonly { flags |= SQLITE_OPEN_CREATE }
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        if rc != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw EngineError.message(friendlySQLite(msg))
        }
        try exec("PRAGMA busy_timeout=120000")
        if readonly {
            try exec("PRAGMA query_only=ON")
        }
    }

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    deinit { close() }

    var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? ""
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw EngineError.message(friendlySQLite(msg))
        }
    }

    func scalarInt(_ sql: String, binds: [String] = []) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), b, -1, SQLITE_TRANSIENT)
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func scalarText(_ sql: String, binds: [String] = []) throws -> String? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), b, -1, SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            throw EngineError.message(friendlySQLite(String(cString: sqlite3_errmsg(db))))
        }
        return stmt
    }

    func queryRows(_ sql: String) throws -> [[SQLValue]] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var rows: [[SQLValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.readRow(stmt))
        }
        return rows
    }

    static func readRow(_ stmt: OpaquePointer?) -> [SQLValue] {
        let n = sqlite3_column_count(stmt)
        var row: [SQLValue] = []
        for i in 0..<n {
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER:
                row.append(.int(sqlite3_column_int64(stmt, i)))
            case SQLITE_NULL:
                row.append(.null)
            case SQLITE_BLOB:
                let bytes = sqlite3_column_bytes(stmt, i)
                if let ptr = sqlite3_column_blob(stmt, i), bytes > 0 {
                    row.append(.blob(Data(bytes: ptr, count: Int(bytes))))
                } else {
                    row.append(.null)
                }
            default:
                if let c = sqlite3_column_text(stmt, i) {
                    row.append(.text(String(cString: c)))
                } else {
                    row.append(.null)
                }
            }
        }
        return row
    }

    func bind(_ stmt: OpaquePointer?, index: Int32, _ value: SQLValue) {
        switch value {
        case .null:
            sqlite3_bind_null(stmt, index)
        case .int(let n):
            sqlite3_bind_int64(stmt, index, n)
        case .text(let s):
            sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
        case .blob(let d):
            _ = d.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(d.count), SQLITE_TRANSIENT)
            }
        }
    }
}

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case text(String)
    case blob(Data)

    var string: String? {
        switch self {
        case .text(let s): return s
        case .blob(let d): return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    var int: Int64 {
        if case .int(let n) = self { return n }
        return 0
    }

    var asKVValue: SQLValue {
        switch self {
        case .blob(let d):
            if let s = String(data: d, encoding: .utf8) { return .text(s) }
            return .blob(d)
        default:
            return self
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
