import Foundation
import SQLite3

// The only file allowed to call the SQLite C API (StructureTests.sqliteCallsOnlyInWrapper).

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let context: String
    public var description: String { "SQLite error \(code) (\(context)): \(message)" }
    public var isConstraintViolation: Bool { code & 0xFF == SQLITE_CONSTRAINT }
    public var isFull: Bool { code & 0xFF == SQLITE_FULL }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A row cursor valid only inside the `query` callback.
public struct SQLRow {
    fileprivate let stmt: OpaquePointer
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func text(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }
    public func blob(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return isNull(i) ? nil : Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

/// One SQLite connection. Not thread-safe by itself: callers confine it to one actor.
public final class SQLiteConnection: @unchecked Sendable {
    private let db: OpaquePointer
    private var cache: [String: OpaquePointer] = [:]
    /// Nesting depth of `transaction`. Re-entrant calls run inline instead of re-beginning (C39).
    private var transactionDepth = 0

    public init(path: String, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: rc, message: msg, context: "open \(path)")
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        for (_, s) in cache { sqlite3_finalize(s) }
        sqlite3_close_v2(db)
    }

    public static var libraryVersion: String { String(cString: sqlite3_libversion()) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg, context: String(sql.prefix(60)))
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            return s
        }
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &s, nil)
        guard rc == SQLITE_OK, let s else { throw error(rc, "prepare: \(sql.prefix(80))") }
        cache[sql] = s
        return s
    }

    private func bind(_ s: OpaquePointer, _ args: [SQLValue]) throws {
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case .null: rc = sqlite3_bind_null(s, idx)
            case .int(let x): rc = sqlite3_bind_int64(s, idx, x)
            case .double(let x): rc = sqlite3_bind_double(s, idx, x)
            case .text(let x): rc = sqlite3_bind_text(s, idx, x, -1, SQLITE_TRANSIENT)
            case .blob(let x):
                rc = x.withUnsafeBytes { p in
                    sqlite3_bind_blob64(s, idx, p.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, sqlite3_uint64(x.count), SQLITE_TRANSIENT)
                }
            }
            if rc != SQLITE_OK { throw error(rc, "bind \(idx)") }
        }
    }

    private func error(_ rc: Int32, _ ctx: String) -> SQLiteError {
        SQLiteError(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)), context: ctx)
    }

    /// Runs a statement that returns no rows of interest.
    @discardableResult
    public func run(_ sql: String, _ args: [any SQLBindable] = []) throws -> Int {
        let s = try statement(sql)
        defer { sqlite3_reset(s) }
        try bind(s, args.map(\.sqlValue))
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw error(rc, "step: \(sql.prefix(80))") }
        }
        return Int(sqlite3_changes(db))
    }

    public func query<T>(_ sql: String, _ args: [any SQLBindable] = [], _ map: (SQLRow) throws -> T) throws -> [T] {
        let s = try statement(sql)
        defer { sqlite3_reset(s) }
        try bind(s, args.map(\.sqlValue))
        var out: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw error(rc, "step: \(sql.prefix(80))") }
            out.append(try map(SQLRow(stmt: s)))
        }
        return out
    }

    /// Streams rows without materialising them (bulk loads such as the vector index).
    public func forEach(_ sql: String, _ args: [any SQLBindable] = [], _ body: (SQLRow) throws -> Void) throws {
        let s = try statement(sql)
        defer { sqlite3_reset(s) }
        try bind(s, args.map(\.sqlValue))
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw error(rc, "step: \(sql.prefix(80))") }
            try body(SQLRow(stmt: s))
        }
    }

    public func scalarInt(_ sql: String, _ args: [any SQLBindable] = []) throws -> Int64 {
        try query(sql, args) { $0.int(0) }.first ?? 0
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    /// `BEGIN IMMEDIATE` … `COMMIT`; rolls back on throw. Nested calls join the outer transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try exec("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let value = try body()
            transactionDepth = 0
            try exec("COMMIT")
            return value
        } catch {
            transactionDepth = 0
            try? exec("ROLLBACK")
            throw error
        }
    }
}
