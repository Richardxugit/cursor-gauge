import XCTest
import SQLite3
@testable import CursorGaugeCore

final class SessionCatalogTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString).vscdb")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
    }

    /// Builds a stand-in for Cursor's store with the same `composerHeaders` shape.
    private func makeDatabase(_ rows: [(id: String, json: String)]) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        let schema = """
            CREATE TABLE composerHeaders (
                composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER,
                lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER,
                recency INTEGER, checkpointAt INTEGER, value TEXT)
            """
        XCTAssertEqual(sqlite3_exec(handle, schema, nil, nil, nil), SQLITE_OK)
        for row in rows {
            let escaped = row.json.replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO composerHeaders (composerId, value) VALUES ('\(row.id)', '\(escaped)')"
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    private func header(name: String?, parent: String? = nil) -> String {
        var fields: [String] = ["\"type\":\"head\""]
        if let name { fields.append("\"name\":\"\(name)\"") }
        if let parent { fields.append("\"subagentInfo\":{\"parentComposerId\":\"\(parent)\"}") }
        return "{\(fields.joined(separator: ","))}"
    }

    // MARK: -

    func testReadsNameAndParent() throws {
        try makeDatabase([
            ("root", header(name: "OXP-54 feature discussion")),
            ("kid", header(name: "Implement Task 7", parent: "root")),
        ])
        let records = SessionCatalog(databaseURL: databaseURL).records(for: ["root", "kid"])
        XCTAssertEqual(records["root"], SessionRecord(name: "OXP-54 feature discussion", parentID: nil))
        XCTAssertEqual(records["kid"], SessionRecord(name: "Implement Task 7", parentID: "root"))
    }

    /// A parent can bill nothing itself and so never appear in the usage events, yet still
    /// be the chat everything hangs off.
    func testFollowsParentsNotPresentInTheRequestedIDs() throws {
        try makeDatabase([
            ("root", header(name: "Planning")),
            ("kid", header(name: "Task", parent: "root")),
        ])
        let records = SessionCatalog(databaseURL: databaseURL).records(for: ["kid"])
        XCTAssertEqual(records["root"]?.name, "Planning")
    }

    func testFollowsAChainOfParents() throws {
        try makeDatabase([
            ("a", header(name: "A")),
            ("b", header(name: "B", parent: "a")),
            ("c", header(name: "C", parent: "b")),
        ])
        let records = SessionCatalog(databaseURL: databaseURL).records(for: ["c"])
        XCTAssertEqual(Set(records.keys), ["a", "b", "c"])
    }

    func testStopsFollowingBeyondTheDepthLimit() throws {
        // Longer than maxParentDepth: resolution must bound itself, not walk forever.
        let ids = (0...12).map { "n\($0)" }
        try makeDatabase(zip(ids.indices, ids).map { index, id in
            (id, header(name: id, parent: index == 0 ? nil : ids[index - 1]))
        })
        let records = SessionCatalog(databaseURL: databaseURL).records(for: ["n12"])
        XCTAssertLessThanOrEqual(records.count, 12)
        XCTAssertNotNil(records["n12"])
    }

    func testOmitsSessionsMissingFromTheTable() throws {
        // Nine of sixteen roots on the real account had no local row at all.
        try makeDatabase([("known", header(name: "Known"))])
        let records = SessionCatalog(databaseURL: databaseURL).records(for: ["known", "ghost"])
        XCTAssertEqual(records["known"]?.name, "Known")
        XCTAssertNil(records["ghost"], "an absent row must not become a named session")
    }

    func testHandlesRowWithNoName() throws {
        try makeDatabase([("untitled", header(name: nil, parent: "root")), ("root", header(name: "R"))])
        let records = SessionCatalog(databaseURL: databaseURL).records(for: ["untitled"])
        XCTAssertNil(records["untitled"]?.name)
        XCTAssertEqual(records["untitled"]?.parentID, "root")
    }

    // MARK: - Degradation

    func testMissingDatabaseYieldsNoRecordsRatherThanThrowing() {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("nope.vscdb")
        XCTAssertTrue(SessionCatalog(databaseURL: absent).records(for: ["a"]).isEmpty)
    }

    func testUnreadableDatabaseYieldsNoRecords() throws {
        try Data("this is not a database".utf8).write(to: databaseURL)
        XCTAssertTrue(SessionCatalog(databaseURL: databaseURL).records(for: ["a"]).isEmpty)
    }

    func testBatchesPastSQLiteParameterLimit() throws {
        // 999 host parameters is SQLite's default ceiling; ask for more than that.
        let ids = (0..<1_200).map { "id\($0)" }
        try makeDatabase(ids.map { ($0, header(name: "name-\($0)")) })
        let records = SessionCatalog(databaseURL: databaseURL).records(for: ids)
        XCTAssertEqual(records.count, 1_200)
    }
}
