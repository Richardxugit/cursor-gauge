import XCTest
import SQLite3
@testable import CursorGaugeCore

final class ReadOnlyDatabaseTests: XCTestCase {
    func testMidStepFailureKeepsEarlierRowsAndMarksTheQueryFailed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("readonly-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let setup = """
            CREATE TABLE items (value TEXT);
            INSERT INTO items VALUES ('"first"');
            INSERT INTO items VALUES ('not json');
            """
        XCTAssertEqual(sqlite3_exec(handle, setup, nil, nil, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(handle)))
        sqlite3_close_v2(handle)

        let database = try XCTUnwrap(ReadOnlyDatabase(url: url))
        var rows: [String] = []
        let completed = database.query(
            "SELECT json_extract(value, '$') FROM items ORDER BY rowid"
        ) { row in
            rows.append(row.text(0) ?? "")
        }

        XCTAssertEqual(rows, ["first"], "rows consumed before the error are preserved")
        XCTAssertFalse(completed)
        XCTAssertTrue(database.hadQueryFailure)
    }
}
