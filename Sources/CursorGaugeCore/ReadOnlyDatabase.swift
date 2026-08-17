import Foundation
import SQLite3

/// A read-only handle on Cursor's SQLite store.
///
/// Opened with `mode=ro` so Cursor's own write-ahead log is never disturbed — the app is a
/// spectator on someone else's database and must stay one.
///
/// Nothing here throws. Both callers treat the local store as a garnish: it supplies chat
/// names and activity detail, never the spend figures. An absent, locked, corrupt or
/// renamed database must cost the user detail and nothing else, so every failure path
/// yields "no rows" and lets the caller carry on.
final class ReadOnlyDatabase {
    private let handle: OpaquePointer

    init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uri = components.string else { return nil }

        var opened: OpaquePointer?
        guard sqlite3_open_v2(uri, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let opened else {
            if opened != nil { sqlite3_close_v2(opened) }
            return nil
        }
        handle = opened
    }

    deinit { sqlite3_close_v2(handle) }

    /// Runs `sql`, binding `parameters` in order, and hands each row to `consume`.
    ///
    /// Returns `false` when the statement could not even be prepared — which is what a
    /// renamed table looks like — so a caller can tell "no rows" from "no such table".
    @discardableResult
    func query(_ sql: String, _ parameters: [String] = [], consume: (Row) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT: SQLite copies the bytes, so the Swift strings need not outlive
        // the bind call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, parameter) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), parameter, -1, transient)
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            consume(Row(statement: statement))
        }
        return true
    }

    /// One row, read by column index. A thin wrapper so call sites never touch a raw pointer.
    struct Row {
        let statement: OpaquePointer

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(statement, column))
        }
    }
}
