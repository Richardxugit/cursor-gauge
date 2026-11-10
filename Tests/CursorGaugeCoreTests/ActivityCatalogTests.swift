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

    /// The per-chat breakdowns are the evidence a consumer classifies work from, so they
    /// have to survive alongside the cycle-wide ranking rather than being folded into it.
    func testEachConversationCarriesItsOwnToolAndFileBreakdown() throws {
        try makeDatabase(bubbles: [
            toolBubble(conversation: "docs", tool: "edit_file_v2",
                       params: #"{"relativeWorkspacePath":"/repo/README.md"}"#),
            toolBubble(conversation: "docs", tool: "read_file_v2",
                       params: #"{"targetFile":"/repo/guide.md"}"#),
            toolBubble(conversation: "code", tool: "edit_file_v2",
                       params: #"{"relativeWorkspacePath":"/repo/app.ts"}"#),
            toolBubble(conversation: "code", tool: "run_terminal_command_v2"),
        ])
        let result = digest().byConversation
        XCTAssertEqual(result["docs"]?.fileTypes, [".md": 2])
        XCTAssertEqual(result["code"]?.fileTypes, [".ts": 1])
        XCTAssertEqual(result["code"]?.tools,
                       ["edit_file_v2": 1, "run_terminal_command_v2": 1])
        XCTAssertEqual(result["docs"]?.tools, ["edit_file_v2": 1, "read_file_v2": 1])
        // The cycle-wide ranking still sees everything.
        XCTAssertEqual(digest().files.map(\.ext), [".md", ".ts"])
    }

    func testConversationActivityCarriesItsBoundsAndPromptLengths() throws {
        try makeDatabase(bubbles: [
            promptBubble(conversation: "c1", text: "hello", at: "2026-08-03T09:00:00.000Z"),
            promptBubble(conversation: "c1", text: "a longer follow-up", at: "2026-08-04T09:00:00.000Z"),
            toolBubble(conversation: "c1", tool: "read_file_v2", at: "2026-08-05T09:00:00.000Z"),
        ])
        let record = try XCTUnwrap(digest().byConversation["c1"])
        XCTAssertEqual(record.promptLengths, [5, 18], "in the order written")
        XCTAssertEqual(record.firstActivity, ISO8601DateFormatter().date(from: "2026-08-03T09:00:00Z"))
        XCTAssertEqual(record.lastActivity, ISO8601DateFormatter().date(from: "2026-08-05T09:00:00Z"))
    }

    // MARK: - Prompt text is a separate, deliberate call

    func testPromptTextIsNotInTheDigestAtAll() throws {
        try makeDatabase(bubbles: [promptBubble(conversation: "c1", text: "SECRET PROMPT")])
        XCTAssertFalse("\(digest())".contains("SECRET PROMPT"),
                       "the digest promises statistics, not content")
    }

    func testPromptTextIsReturnedWhenAskedForByName() throws {
        try makeDatabase(bubbles: [
            promptBubble(conversation: "c1", text: "first", at: "2026-08-03T09:00:00.000Z"),
            promptBubble(conversation: "c1", text: "second", at: "2026-08-04T09:00:00.000Z"),
            promptBubble(conversation: "c2", text: "other"),
            promptBubble(conversation: "c1", text: "too early", at: "2026-07-01T09:00:00.000Z"),
        ])
        let result = ActivityCatalog(databaseURL: databaseURL, timeZone: TimeZone(secondsFromGMT: 0)!)
            .promptText(since: cycleStart)
        XCTAssertEqual(result.texts["c1"], ["first", "second"], "in order, and only inside the window")
        XCTAssertEqual(result.texts["c2"], ["other"])
        XCTAssertFalse(result.unavailable, "a read that ran to completion is not unavailable")
    }

    /// An absent editor database is a readable, quiet store — normal for someone who never
    /// uses the editor — so prompt text must report complete-with-nothing, not a failure.
    func testMissingDatabaseReportsPromptTextAsReadableEmpty() {
        let result = ActivityCatalog(databaseURL: databaseURL, timeZone: TimeZone(secondsFromGMT: 0)!)
            .promptText(since: cycleStart)
        XCTAssertEqual(result.texts, [:])
        XCTAssertFalse(result.unavailable)
    }

    /// A store that exists but cannot be opened is a failure worth stating, unlike a
    /// genuinely quiet cycle.
    func testANonSQLiteFileMakesPromptTextUnavailable() throws {
        try "this is not a database".write(to: databaseURL, atomically: true, encoding: .utf8)
        let result = ActivityCatalog(databaseURL: databaseURL, timeZone: TimeZone(secondsFromGMT: 0)!)
            .promptText(since: cycleStart)
        XCTAssertEqual(result.texts, [:])
        XCTAssertTrue(result.unavailable)
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

    // MARK: - Whole-digest equivalence

    func testDigestMatchesFullActivitySnapshotAcrossAllAggregationBranches() throws {
        let feature = "/ko-feature add a button"
        let path = "/Users/pxu/project/File.swift"
        let multilineFeature = "/ko-feature\nagain"
        let plain = "plain question"
        let review = "/ko-review"
        let lengths = [feature, path, multilineFeature, plain, review].map(\.count)

        try makeDatabase(
            bubbles: [
                promptBubble(conversation: "c1", text: feature, at: "2026-08-03T08:00:00.000Z"),
                promptBubble(conversation: "c1", text: path, at: "2026-08-03T08:01:00.000Z"),
                toolBubble(conversation: "c1", tool: "read_file_v2",
                           params: #"{"targetFile":"/repo/Sources/App.swift"}"#,
                           at: "2026-08-03T09:00:00.000Z"),
                toolBubble(conversation: "c1", tool: "edit_file_v2", status: "error",
                           params: #"{"relativeWorkspacePath":"/repo/Sources/App.swift"}"#,
                           at: "2026-08-03T10:00:00.000Z"),
                toolBubble(conversation: "c1", tool: "edit_file_v2", decision: "rejected",
                           params: #"{"relativeWorkspacePath":"/repo/README.md"}"#,
                           at: "2026-08-03T11:00:00.000Z"),
                toolBubble(conversation: "c1", tool: "run_terminal_command_v2", status: "cancelled",
                           at: "2026-08-03T12:00:00.000Z"),
                promptBubble(conversation: "c1", text: multilineFeature,
                             at: "2026-08-04T08:00:00.000Z"),
                promptBubble(conversation: "c1", text: plain, at: "2026-08-04T08:01:00.000Z"),
                toolBubble(conversation: "c1", tool: "read_file_v2",
                           params: #"{"targetFile":"/repo/README.md"}"#,
                           at: "2026-08-04T09:00:00.000Z"),
                toolBubble(conversation: "c1", tool: "create_file", decision: "rejected",
                           params: #"{"relativeWorkspacePath":"/repo/New.txt"}"#,
                           at: "2026-08-04T10:00:00.000Z"),
                promptBubble(conversation: "c2", text: review, at: "2026-08-03T08:00:00.000Z"),
                toolBubble(conversation: "c2", tool: "mcp-atlassian-getJiraIssue", status: "error",
                           at: "2026-08-03T09:00:00.000Z"),
                toolBubble(conversation: "c2", tool: "read_file_v2",
                           params: #"{"targetFile":"/repo/Makefile"}"#,
                           at: "2026-08-04T09:00:00.000Z"),
                promptBubble(conversation: "c2", text: "", at: "2026-08-04T10:00:00.000Z"),
                toolBubble(conversation: "c1", tool: "read_file_v2",
                           at: "2026-07-31T23:59:59.000Z"),
            ],
            headers: [
                header(id: "c1", workspace: "/work/alpha", mode: "agent",
                       linesAdded: 40, linesRemoved: 5, filesChanged: 3),
                header(id: "c2", workspace: "/work/beta", mode: "chat",
                       linesAdded: 7, linesRemoved: 2, filesChanged: 1),
                header(id: "inactive", workspace: "/work/archive", mode: "debug",
                       linesAdded: 9, linesRemoved: 4, filesChanged: 2),
            ]
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: String) throws -> Date {
            try XCTUnwrap(formatter.date(from: value))
        }
        let expected = ActivityDigest(
            tools: [
                ToolUsage(name: "read_file_v2", calls: 3),
                ToolUsage(name: "edit_file_v2", calls: 2, errors: 1, rejected: 1),
                ToolUsage(name: "create_file", calls: 1, rejected: 1),
                ToolUsage(name: "mcp-atlassian-getJiraIssue", calls: 1, errors: 1),
                ToolUsage(name: "run_terminal_command_v2", calls: 1, cancelled: 1),
            ],
            prompts: PromptStats(
                count: 5, medianChars: lengths.sorted()[2], longestChars: lengths.max() ?? 0,
                commands: [CommandUsage(command: "/ko-feature", count: 2),
                           CommandUsage(command: "/ko-review", count: 1)]
            ),
            files: [
                FileTypeUsage(ext: ".md", reads: 1, edits: 1),
                FileTypeUsage(ext: ".swift", reads: 1, edits: 1),
                FileTypeUsage(ext: "(none)", reads: 1, edits: 0),
                FileTypeUsage(ext: ".txt", reads: 0, edits: 1),
            ],
            byConversation: [
                "c1": ConversationActivity(
                    workspace: "alpha", workspacePath: "/work/alpha", mode: "agent",
                    prompts: 4, toolCalls: 6, linesAdded: 40, linesRemoved: 5, filesChanged: 3,
                    tools: ["read_file_v2": 2, "edit_file_v2": 2,
                            "run_terminal_command_v2": 1, "create_file": 1],
                    firstActivity: try date("2026-08-03T08:00:00.000Z"),
                    lastActivity: try date("2026-08-04T10:00:00.000Z"),
                    promptLengths: [feature.count, path.count, multilineFeature.count, plain.count],
                    fileTypes: [".swift": 2, ".md": 2, ".txt": 1]
                ),
                "c2": ConversationActivity(
                    workspace: "beta", workspacePath: "/work/beta", mode: "chat",
                    prompts: 1, toolCalls: 2, linesAdded: 7, linesRemoved: 2, filesChanged: 1,
                    tools: ["mcp-atlassian-getJiraIssue": 1, "read_file_v2": 1],
                    firstActivity: try date("2026-08-03T08:00:00.000Z"),
                    lastActivity: try date("2026-08-04T10:00:00.000Z"),
                    promptLengths: [review.count], fileTypes: ["(none)": 1]
                ),
                "inactive": ConversationActivity(
                    workspace: "archive", workspacePath: "/work/archive", mode: "debug",
                    linesAdded: 9, linesRemoved: 4, filesChanged: 2
                ),
            ],
            daily: [
                DayActivity(day: try date("2026-08-03T00:00:00.000Z"), prompts: 3, toolCalls: 5),
                DayActivity(day: try date("2026-08-04T00:00:00.000Z"), prompts: 2, toolCalls: 3),
            ]
        )

        XCTAssertEqual(digest(), expected)
    }

    // MARK: - Degradation

    func testMissingDatabaseYieldsAnEmptyDigestRatherThanThrowing() {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("nope.vscdb")
        XCTAssertEqual(ActivityCatalog(databaseURL: absent).digest(since: cycleStart), .empty)
    }

    /// A database that exists but cannot be opened is a failure, not a quiet cycle: the
    /// digest must keep its empty stats but say the editor's store could not be read.
    func testUnreadableDatabaseYieldsAnEmptyDigest() throws {
        try Data("this is not a database".utf8).write(to: databaseURL)
        XCTAssertEqual(digest(), ActivityDigest(
            tools: [], prompts: .empty, files: [], byConversation: [:], daily: [],
            unavailableSources: [.gui]
        ))
    }

    /// Cursor could rename a table tomorrow. Losing the activity half must not cost the
    /// cost half, so a missing table is empty rather than fatal — but it is still a
    /// failure the report should say so about.
    func testAStoreWithoutTheExpectedTablesYieldsAnEmptyDigest() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE somethingElse (a TEXT)", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(handle)
        XCTAssertEqual(digest(), ActivityDigest(
            tools: [], prompts: .empty, files: [], byConversation: [:], daily: [],
            unavailableSources: [.gui]
        ))
    }

    /// A later aggregate query can fail after the bubble table was read. Keep the activity
    /// already extracted, but do not let that partial read look like a quiet store.
    func testLaterQueryFailureKeepsActivityAndMarksTheStoreUnavailable() throws {
        try makeDatabase(bubbles: [toolBubble(conversation: "c1", tool: "read_file_v2")])
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DROP TABLE composerHeaders", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(handle)

        let result = digest()
        XCTAssertEqual(result.tools.first?.calls, 1, "the successful tool query is preserved")
        XCTAssertEqual(result.byConversation["c1"]?.toolCalls, 1)
        XCTAssertEqual(result.unavailableSources, [.gui])
    }
}
