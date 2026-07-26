import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable, Equatable {
    case text(String)
    case double(Double)
    case int(Int64)
    case null

    public var stringValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        default:             return nil
        }
    }

    public var intValue: Int64? {
        switch self {
        case .int(let i):    return i
        case .double(let d): return Int64(d)
        default:             return nil
        }
    }
}

public enum DatabaseError: Error, Sendable {
    case open(String)
    case prepare(String)
    case step(String)
}

/// Thin wrapper over the system SQLite3 C API. Deliberately dependency-free:
/// the schema is four tables with trivial queries, so pulling in GRDB would cost
/// more than it saves.
public final class Database {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var h: OpaquePointer?
        guard sqlite3_open(path, &h) == SQLITE_OK, h != nil else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.open(msg)
        }
        handle = h
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    private var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
    }

    public func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.step(lastError)
        }
    }

    private func prepare(_ sql: String, _ binds: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare(lastError)
        }
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s):   sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .int(let n):    sqlite3_bind_int64(stmt, idx, n)
            case .null:          sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    public func run(_ sql: String, _ binds: [SQLValue] = []) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError.step(lastError)
        }
    }

    public func query(_ sql: String, _ binds: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: SQLValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_TEXT:
                    row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_FLOAT:
                    row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_INTEGER:
                    row[name] = .int(sqlite3_column_int64(stmt, c))
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
}
