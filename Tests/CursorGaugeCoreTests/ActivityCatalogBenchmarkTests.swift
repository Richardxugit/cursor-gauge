import Foundation
import SQLite3
import XCTest
@testable import CursorGaugeCore

/// Temporary, opt-in benchmark harness. The database persists in /tmp so the original and
/// refactored implementations are timed on exactly the same bytes.
final class ActivityCatalogBenchmarkTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/cursor-gauge-activity-50k-benchmark.vscdb")

    func testBenchmark50KRows() throws {
        guard ProcessInfo.processInfo.environment["RUN_ACTIVITY_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RUN_ACTIVITY_BENCHMARK=1 to run the 50k-row benchmark")
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try makeDatabase()
        }

        let catalog = ActivityCatalog(databaseURL: url, timeZone: TimeZone(secondsFromGMT: 0)!)
        let since = Date(timeIntervalSince1970: 1_785_542_400)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] ?? 0
        print("BENCHMARK_DB=\(url.path) BYTES=\(size)")
        for run in 1...3 {
            let start = Date()
            let result = catalog.digest(since: since)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertFalse(result.isEmpty)
            print("BENCHMARK_RUN=\(run) SECONDS=\(String(format: "%.6f", elapsed)) PROMPTS=\(result.prompts.count) TOOLS=\(result.tools.reduce(0) { $0 + $1.calls })")
        }
    }

    private func makeDatabase() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        XCTAssertEqual(sqlite3_exec(handle, """
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, value TEXT);
            BEGIN;
            """, nil, nil, nil), SQLITE_OK)

        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle,
            "INSERT INTO cursorDiskKV (key, value) VALUES (?1, ?2)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let body = String(repeating: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", count: 64)

        for index in 0..<50_000 {
            let day = index % 28 + 1
            let hour = index % 24
            let minute = index % 60
            let timestamp = String(format: "2026-08-%02dT%02d:%02d:00.000Z", day, hour, minute)
            let key = "bubbleId:conversation-\(index % 100):bubble-\(index)"
            let json: String
            if index % 5 == 0 {
                let prompt = index % 20 == 0
                    ? "/ko-feature synthetic prompt \(index) " + String(repeating: "p", count: index % 200)
                    : "synthetic prompt \(index) " + String(repeating: "p", count: index % 200)
                json = "{\"type\":1,\"createdAt\":\"\(timestamp)\",\"text\":\"\(prompt)\"}"
            } else {
                let tool = index % 2 == 0 ? "read_file_v2" : "edit_file_v2"
                let status = index % 101 == 0 ? "error" : index % 103 == 0 ? "cancelled" : "completed"
                let decision = index % 107 == 0 ? ",\"userDecision\":\"rejected\"" : ""
                let params = "{\"relativeWorkspacePath\":\"/repo/Sources/File\(index % 500).swift\",\"streamingContent\":\"\(index):\(body)\"}"
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                json = "{\"type\":2,\"createdAt\":\"\(timestamp)\",\"toolFormerData\":{\"name\":\"\(tool)\",\"status\":\"\(status)\"\(decision),\"params\":\"\(params)\"}}"
            }
            key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
            json.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            XCTAssertEqual(sqlite3_reset(statement), SQLITE_OK)
            XCTAssertEqual(sqlite3_clear_bindings(statement), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(handle, "COMMIT", nil, nil, nil), SQLITE_OK)
    }
}
