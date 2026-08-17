import XCTest
import SQLite3
@testable import CursorGaugeCore

final class ActivityCatalogTests: XCTestCase {
    private var databaseURL: URL!

    /// Every fixture timestamp sits inside this window unless a test says otherwise.
    private let cycleStart = Date(timeIntervalSince1970: 1_785_542_400) // 2026-08-01T00:00:00Z

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-\(UUID().uuidString).vscdb")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
    }

    // MARK: - Fixture

    /// Builds a stand-in for Cursor's store with the same two tables and the same shapes,
    /// including the detail that `params` and `rawArgs` hold JSON *as a string*.
    private func makeDatabase(bubbles: [(key: String, json: String)],
                              headers: [(id: String, json: String)] = []) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        let schema = """
            CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, value TEXT);
            """
        XCTAssertEqual(sqlite3_exec(handle, schema, nil, nil, nil), SQLITE_OK)

        func insert(_ sql: String) {
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK,
                           String(cString: sqlite3_errmsg(handle)))
        }
        for bubble in bubbles {
            insert("""
                INSERT INTO cursorDiskKV (key, value) \
                VALUES ('\(bubble.key)', '\(escape(bubble.json))')
                """)
        }
        for header in headers {
            insert("""
                INSERT INTO composerHeaders (composerId, value) \
                VALUES ('\(header.id)', '\(escape(header.json))')
                """)
        }
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private var bubbleSerial = 0

    /// A tool-call bubble. `params` is embedded as a JSON string, as Cursor stores it.
    private func toolBubble(
        conversation: String, tool: String, status: String = "completed",
        decision: String? = nil, params: String? = nil, at: String = "2026-08-05T10:00:00.000Z"
    ) -> (key: String, json: String) {
        bubbleSerial += 1
        var fields = [
            "\"type\":2",
            "\"createdAt\":\"\(at)\"",
            "\"toolFormerData\":{"
                + "\"name\":\"\(tool)\",\"status\":\"\(status)\""
                + (decision.map { ",\"userDecision\":\"\($0)\"" } ?? "")
                + (params.map { ",\"params\":\"\(escapeJSONString($0))\"" } ?? "")
                + "}",
        ]
        fields.append("\"bubbleId\":\"b\(bubbleSerial)\"")
        return ("bubbleId:\(conversation):b\(bubbleSerial)", "{\(fields.joined(separator: ","))}")
    }

    /// A user-prompt bubble.
    private func promptBubble(
        conversation: String, text: String, at: String = "2026-08-05T09:00:00.000Z"
    ) -> (key: String, json: String) {
        bubbleSerial += 1
        return ("bubbleId:\(conversation):b\(bubbleSerial)",
                "{\"type\":1,\"createdAt\":\"\(at)\",\"text\":\"\(escapeJSONString(text))\"}")
    }

    /// Escapes a value so it survives being embedded inside a JSON string literal.
    private func escapeJSONString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func header(
        id: String, workspace: String?, mode: String = "agent",
        linesAdded: Int = 0, linesRemoved: Int = 0, filesChanged: Int = 0
    ) -> (id: String, json: String) {
        var fields = [
            "\"composerId\":\"\(id)\"",
            "\"unifiedMode\":\"\(mode)\"",
            "\"totalLinesAdded\":\(linesAdded)",
            "\"totalLinesRemoved\":\(linesRemoved)",
            "\"filesChangedCount\":\(filesChanged)",
        ]
        if let workspace {
            fields.append("\"workspaceIdentifier\":{\"uri\":{\"fsPath\":\"\(workspace)\"}}")
        }
        return (id, "{\(fields.joined(separator: ","))}")
    }

    /// Pinned to UTC so day boundaries are not a function of where the test runs.
    private func digest(since: Date? = nil) -> ActivityDigest {
        ActivityCatalog(databaseURL: databaseURL, timeZone: TimeZone(secondsFromGMT: 0)!)
            .digest(since: since ?? cycleStart)
    }

    // MARK: - Tool calls

    func testCountsToolCallsByName() throws {
        try makeDatabase(bubbles: [
            toolBubble(conversation: "c1", tool: "read_file_v2"),
            toolBubble(conversation: "c1", tool: "read_file_v2"),
            toolBubble(conversation: "c2", tool: "edit_file_v2"),
        ])
        let tools = digest().tools
        XCTAssertEqual(tools.map(\.name), ["read_file_v2", "edit_file_v2"], "ranked by call count")
        XCTAssertEqual(tools.first?.calls, 2)
    }

    func testTalliesToolOutcomesSeparately() throws {
        try makeDatabase(bubbles: [
            toolBubble(conversation: "c1", tool: "edit_file_v2"),
            toolBubble(conversation: "c1", tool: "edit_file_v2", status: "error"),
            toolBubble(conversation: "c1", tool: "edit_file_v2", status: "cancelled"),
            toolBubble(conversation: "c1", tool: "edit_file_v2", decision: "rejected"),
            toolBubble(conversation: "c1", tool: "edit_file_v2", decision: "accepted"),
        ])
        let edit = try XCTUnwrap(digest().tools.first)
        XCTAssertEqual(edit.calls, 5)
        XCTAssertEqual(edit.errors, 1)
        XCTAssertEqual(edit.cancelled, 1)
        XCTAssertEqual(edit.rejected, 1, "an accepted edit must not count as rejected")
    }

    /// Cursor names MCP tools `mcp-<server>-<tool>`, so the server is worth surfacing
    /// without the renderer having to re-parse the name.
    func testIdentifiesTheMCPServerBehindATool() throws {
        try makeDatabase(bubbles: [
            toolBubble(conversation: "c1", tool: "mcp-atlassian-getJiraIssue"),
            toolBubble(conversation: "c1", tool: "read_file_v2"),
        ])
        let tools = digest().tools
        XCTAssertEqual(tools.first(where: { $0.name.hasPrefix("mcp-") })?.server, "atlassian")
        XCTAssertNil(tools.first(where: { $0.name == "read_file_v2" })?.server,
                     "a built-in tool has no MCP server")
    }

    func testATruncatedMCPNameYieldsNoServerRatherThanAnEmptyOne() throws {
        // The real account holds 51 calls literally named `mcp--`.
        try makeDatabase(bubbles: [toolBubble(conversation: "c1", tool: "mcp--")])
        XCTAssertNil(digest().tools.first?.server)
    }

    // MARK: - The window

    func testIgnoresActivityBeforeTheWindowStarts() throws {
        try makeDatabase(bubbles: [
            toolBubble(conversation: "c1", tool: "read_file_v2", at: "2026-07-30T10:00:00.000Z"),
            toolBubble(conversation: "c1", tool: "read_file_v2", at: "2026-08-02T10:00:00.000Z"),
            promptBubble(conversation: "c1", text: "old", at: "2026-07-15T10:00:00.000Z"),
            promptBubble(conversation: "c1", text: "new", at: "2026-08-02T10:00:00.000Z"),
        ])
        let result = digest()
        XCTAssertEqual(result.tools.first?.calls, 1, "six months of tools must not sit beside one cycle of spend")
        XCTAssertEqual(result.prompts.count, 1)
    }

    /// `createdAt` carries milliseconds. Comparing against a boundary formatted without
    /// them would sort `…T00:00:00Z` *after* `…T00:00:00.500Z` and silently drop the event.
    func testKeepsActivityInTheFirstSecondOfTheWindow() throws {
        try makeDatabase(bubbles: [
            toolBubble(conversation: "c1", tool: "read_file_v2", at: "2026-08-01T00:00:00.500Z"),
        ])
        XCTAssertEqual(digest().tools.first?.calls, 1)
    }

    // MARK: - Prompts

    func testSummarisesPromptsWithoutRetainingTheirText() throws {
        try makeDatabase(bubbles: [
            promptBubble(conversation: "c1", text: String(repeating: "a", count: 10)),
            promptBubble(conversation: "c1", text: String(repeating: "b", count: 100)),
            promptBubble(conversation: "c1", text: String(repeating: "c", count: 1_000)),
        ])
        let prompts = digest().prompts
        XCTAssertEqual(prompts.count, 3)
        XCTAssertEqual(prompts.medianChars, 100)
        XCTAssertEqual(prompts.longestChars, 1_000)
    }

    func testRanksSlashCommands() throws {
        try makeDatabase(bubbles: [
            promptBubble(conversation: "c1", text: "/ko-feature add a button"),
            promptBubble(conversation: "c1", text: "/ko-feature something else"),
            promptBubble(conversation: "c1", text: "/ko-review"),
            promptBubble(conversation: "c1", text: "just a normal question"),
        ])
        let commands = digest().prompts.commands
        XCTAssertEqual(commands.map(\.command), ["/ko-feature", "/ko-review"])
        XCTAssertEqual(commands.first?.count, 2)
        XCTAssertEqual(digest().prompts.count, 4, "the plain prompt still counts as a prompt")
    }

    func testIgnoresEmptyPrompts() throws {
        try makeDatabase(bubbles: [
            promptBubble(conversation: "c1", text: ""),
            promptBubble(conversation: "c1", text: "real"),
        ])
        XCTAssertEqual(digest().prompts.count, 1)
    }

    // MARK: - Files

    /// `params` is a JSON string, not a nested object, so the path needs a double extract —
    /// and the tools disagree on which key holds it.
    func testReadsFilePathsFromBothParameterNames() throws {
        try makeDatabase(bubbles: [
            toolBubble(conversation: "c1", tool: "edit_file_v2",
                       params: #"{"relativeWorkspacePath":"/repo/src/app.ts"}"#),
            toolBubble(conversation: "c1", tool: "read_file_v2",
                       params: #"{"targetFile":"/repo/README.md"}"#),
            toolBubble(conversation: "c1", tool: "read_file_v2",
                       params: #"{"targetFile":"/repo/docs/guide.md"}"#),
        ])
        let files = digest().files
        XCTAssertEqual(files.map(\.ext), [".md", ".ts"], "ranked by total operations")
        XCTAssertEqual(files.first { $0.ext == ".md" }?.reads, 2)
        XCTAssertEqual(files.first { $0.ext == ".ts" }?.edits, 1)
    }

    func testFilesWithNoExtensionAreGroupedRatherThanDropped() throws {
        try makeDatabase(bubbles: [
            toolBubble(conversation: "c1", tool: "read_file_v2",
                       params: #"{"targetFile":"/repo/Makefile"}"#),
        ])
        XCTAssertEqual(digest().files.map(\.ext), ["(none)"])
    }

    /// `params.streamingContent` holds whole file bodies. Nothing but the path may escape.
    func testFileContentNeverLeavesTheDatabase() throws {
        let secret = "SUPER SECRET SOURCE CODE"
        try makeDatabase(bubbles: [
            toolBubble(conversation: "c1", tool: "edit_file_v2",
                       params: #"{"relativeWorkspacePath":"/repo/a.ts","streamingContent":"\#(secret)"}"#),
        ])
        XCTAssertFalse("\(digest())".contains(secret))
    }

    // MARK: - Per conversation

    func testAttributesActivityToItsConversationAndWorkspace() throws {
        try makeDatabase(
            bubbles: [
                promptBubble(conversation: "c1", text: "hello"),
                toolBubble(conversation: "c1", tool: "read_file_v2"),
                toolBubble(conversation: "c1", tool: "edit_file_v2"),
                toolBubble(conversation: "c2", tool: "read_file_v2"),
            ],
            headers: [
                header(id: "c1", workspace: "/Users/pxu/Desktop/ko-services",
                       mode: "agent", linesAdded: 40, linesRemoved: 5, filesChanged: 3),
                header(id: "c2", workspace: "/Users/pxu/Desktop/ko-ui-lib", mode: "chat"),
            ]
        )
        let byConversation = digest().byConversation
        let first = try XCTUnwrap(byConversation["c1"])
        XCTAssertEqual(first.workspace, "ko-services", "the repo name, not the whole path")
        XCTAssertEqual(first.mode, "agent")
        XCTAssertEqual(first.prompts, 1)
        XCTAssertEqual(first.toolCalls, 2)
        XCTAssertEqual(first.linesAdded, 40)
        XCTAssertEqual(first.linesRemoved, 5)
        XCTAssertEqual(first.filesChanged, 3)
        XCTAssertEqual(byConversation["c2"]?.workspace, "ko-ui-lib")
    }

    func testAConversationWithNoHeaderStillReportsItsActivity() throws {
        // Cloud agents bill against a conversation that has no local row at all.
        try makeDatabase(bubbles: [toolBubble(conversation: "orphan", tool: "read_file_v2")])
        let orphan = try XCTUnwrap(digest().byConversation["orphan"])
        XCTAssertNil(orphan.workspace)
        XCTAssertEqual(orphan.toolCalls, 1)
    }

    /// A chat can bill in this cycle while its messages were written in the last one.
    /// Its workspace must still be reachable, or its cost lands in the unattributed bucket.
    func testAChatWithNoActivityInTheWindowIsStillLookedUp() throws {
        try makeDatabase(
            bubbles: [toolBubble(conversation: "c1", tool: "read_file_v2", at: "2026-07-02T10:00:00.000Z")],
            headers: [header(id: "c1", workspace: "/Users/pxu/Desktop/ko-services")]
        )
        let quiet = try XCTUnwrap(digest().byConversation["c1"])
        XCTAssertEqual(quiet.workspace, "ko-services")
        XCTAssertEqual(quiet.toolCalls, 0, "its activity is still outside the window")
    }

    func testAHeaderWithNoWorkspaceDoesNotInventOne() throws {
        try makeDatabase(
            bubbles: [toolBubble(conversation: "c1", tool: "read_file_v2")],
            headers: [header(id: "c1", workspace: nil)]
        )
        XCTAssertNil(digest().byConversation["c1"]?.workspace)
    }

    // MARK: - Daily rhythm

    func testGroupsActivityByDay() throws {
        try makeDatabase(bubbles: [
            promptBubble(conversation: "c1", text: "a", at: "2026-08-03T09:00:00.000Z"),
            toolBubble(conversation: "c1", tool: "read_file_v2", at: "2026-08-03T11:00:00.000Z"),
            toolBubble(conversation: "c1", tool: "read_file_v2", at: "2026-08-04T11:00:00.000Z"),
        ])
        let daily = digest().daily
        XCTAssertEqual(daily.count, 2, "one row per day with activity, in order")
        XCTAssertEqual(daily.first?.prompts, 1)
        XCTAssertEqual(daily.first?.toolCalls, 1)
        XCTAssertEqual(daily.last?.toolCalls, 1)
        XCTAssertEqual(daily.last?.prompts, 0)
        XCTAssertTrue(daily[0].day < daily[1].day, "chronological, so a chart can plot it")
    }

    // MARK: - Degradation

    func testMissingDatabaseYieldsAnEmptyDigestRatherThanThrowing() {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("nope.vscdb")
        XCTAssertEqual(ActivityCatalog(databaseURL: absent).digest(since: cycleStart), .empty)
    }

    func testUnreadableDatabaseYieldsAnEmptyDigest() throws {
        try Data("this is not a database".utf8).write(to: databaseURL)
        XCTAssertEqual(digest(), .empty)
    }

    /// Cursor could rename a table tomorrow. Losing the activity half must not cost the
    /// cost half, so a missing table is empty rather than fatal.
    func testAStoreWithoutTheExpectedTablesYieldsAnEmptyDigest() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE somethingElse (a TEXT)", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(handle)
        XCTAssertEqual(digest(), .empty)
    }
}
