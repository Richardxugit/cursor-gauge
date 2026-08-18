import XCTest
import SQLite3
@testable import CursorGaugeCore

final class CliCatalogTests: XCTestCase {
    private var root: URL!
    private let cycleStart = Date(timeIntervalSince1970: 1_785_542_400) // 2026-08-01T00:00:00Z
    private let utc = TimeZone(secondsFromGMT: 0)!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    /// Mirrors `~/.cursor/chats/<workspace-hash>/<agent-id>/` with a `meta.json` and the
    /// same `blobs(id, data)` store the CLI writes.
    @discardableResult
    private func makeConversation(
        id: String, title: String?, cwd: String?,
        created: Date, updated: Date? = nil, blobs: [String] = []
    ) throws -> URL {
        let directory = root.appendingPathComponent("workspace-hash/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var meta: [String: Any] = [
            "schemaVersion": 1,
            "createdAtMs": created.timeIntervalSince1970 * 1000,
            "updatedAtMs": (updated ?? created).timeIntervalSince1970 * 1000,
        ]
        if let title { meta["title"] = title }
        if let cwd { meta["cwd"] = cwd }
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: directory.appendingPathComponent("meta.json"))

        var handle: OpaquePointer?
        let path = directory.appendingPathComponent("store.db").path
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close_v2(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB)", nil, nil, nil),
            SQLITE_OK
        )
        for (index, blob) in blobs.enumerated() {
            let escaped = blob.replacingOccurrences(of: "'", with: "''")
            XCTAssertEqual(
                sqlite3_exec(handle, "INSERT INTO blobs VALUES ('b\(index)', '\(escaped)')", nil, nil, nil),
                SQLITE_OK
            )
        }
        return directory
    }

    private func toolCall(_ name: String, args: String = "{}") -> String {
        #"{"role":"assistant","content":[{"type":"tool-call","toolName":"\#(name)","args":\#(args)}]}"#
    }

    private func userMessage(_ text: String) -> String {
        #"{"role":"user","content":[{"type":"text","text":"\#(text)"}]}"#
    }

    private func digest(since: Date? = nil) -> ActivityDigest {
        CliCatalog(root: root, timeZone: utc).digest(since: since ?? cycleStart)
    }

    // MARK: - Reading

    func testReadsTitleAndWorkingDirectory() throws {
        try makeConversation(
            id: "agent-1", title: "Dashboard Spike Investigator",
            cwd: "/Users/pxu/Desktop/ko-services",
            created: cycleStart.addingTimeInterval(86_400)
        )
        let record = try XCTUnwrap(digest().byConversation["agent-1"])
        XCTAssertEqual(record.workspace, "ko-services", "the repo, from the CLI's working directory")
        XCTAssertEqual(record.source, .cli)
        XCTAssertEqual(record.mode, "cli")
    }

    func testCountsToolCallsAndPrompts() throws {
        try makeConversation(
            id: "agent-1", title: "Work", cwd: "/repo",
            created: cycleStart.addingTimeInterval(86_400),
            blobs: [
                userMessage("find the bug"),
                toolCall("Read", args: #"{"path":"/repo/app.ts"}"#),
                toolCall("Read", args: #"{"path":"/repo/other.ts"}"#),
                toolCall("Grep", args: #"{"pattern":"foo"}"#),
            ]
        )
        let result = digest()
        XCTAssertEqual(result.byConversation["agent-1"]?.prompts, 1)
        XCTAssertEqual(result.byConversation["agent-1"]?.toolCalls, 3)
        XCTAssertEqual(result.byConversation["agent-1"]?.tools, ["Read": 2, "Grep": 1])
        XCTAssertEqual(result.tools.first?.name, "Read")
        XCTAssertEqual(result.tools.first?.calls, 2)
    }

    /// The CLI names the bridge, not the work. Reporting `CallMcpTool` for every integration
    /// would collapse Atlassian and Buildkite into one indistinguishable row.
    func testAnMCPCallIsNamedForTheToolThatRanNotTheBridge() throws {
        try makeConversation(
            id: "agent-1", title: "Work", cwd: "/repo",
            created: cycleStart.addingTimeInterval(86_400),
            blobs: [toolCall("CallMcpTool", args: #"{"server":"atlassian","toolName":"getJiraIssue"}"#)]
        )
        let tool = try XCTUnwrap(digest().tools.first)
        XCTAssertEqual(tool.name, "getJiraIssue")
        XCTAssertEqual(tool.server, "atlassian")
    }

    func testFilePathsAreSplitIntoReadsAndEdits() throws {
        try makeConversation(
            id: "agent-1", title: "Work", cwd: "/repo",
            created: cycleStart.addingTimeInterval(86_400),
            blobs: [
                toolCall("Read", args: #"{"path":"/repo/README.md"}"#),
                toolCall("Write", args: #"{"path":"/repo/app.ts"}"#),
            ]
        )
        let files = digest().files
        XCTAssertEqual(files.first { $0.ext == ".md" }?.reads, 1)
        XCTAssertEqual(files.first { $0.ext == ".ts" }?.edits, 1)
    }

    /// Roughly two thirds of real blobs are not plaintext — the store carries a
    /// `blobEncryptionKey`. Unreadable blobs are skipped, never guessed at.
    func testUnreadableBlobsAreSkippedRatherThanGuessedAt() throws {
        try makeConversation(
            id: "agent-1", title: "Work", cwd: "/repo",
            created: cycleStart.addingTimeInterval(86_400),
            blobs: [toolCall("Read", args: #"{"path":"/repo/a.ts"}"#), "not json at all", ""]
        )
        XCTAssertEqual(digest().byConversation["agent-1"]?.toolCalls, 1)
    }

    // MARK: - The window

    func testConversationsThatEndedBeforeTheWindowAreIgnored() throws {
        try makeConversation(id: "old", title: "Last cycle", cwd: "/repo",
                             created: cycleStart.addingTimeInterval(-864_000),
                             updated: cycleStart.addingTimeInterval(-86_400),
                             blobs: [toolCall("Read")])
        try makeConversation(id: "new", title: "This cycle", cwd: "/repo",
                             created: cycleStart.addingTimeInterval(86_400),
                             blobs: [toolCall("Read")])
        XCTAssertEqual(Set(digest().byConversation.keys), ["new"])
    }

    /// A conversation started before the window but still going belongs to it. Messages carry
    /// no timestamps, so this is the finest cut available — and on real data the worst case
    /// is small: no CLI conversation spanned more than 1.5 hours.
    func testAConversationStillRunningIntoTheWindowIsIncluded() throws {
        try makeConversation(id: "straddler", title: "Long one", cwd: "/repo",
                             created: cycleStart.addingTimeInterval(-3_600),
                             updated: cycleStart.addingTimeInterval(3_600),
                             blobs: [toolCall("Read")])
        XCTAssertNotNil(digest().byConversation["straddler"])
    }

    // MARK: - Naming

    func testSuppliesTitlesForNaming() throws {
        try makeConversation(id: "agent-1", title: "Missing Refresh Token", cwd: "/repo",
                             created: cycleStart.addingTimeInterval(86_400))
        let records = CliCatalog(root: root).records(for: ["agent-1", "unknown"])
        XCTAssertEqual(records["agent-1"], SessionRecord(name: "Missing Refresh Token", parentID: nil))
        XCTAssertNil(records["unknown"])
    }

    /// Naming is not window-filtered: a caller asking about an id wants its name whenever it ran.
    func testNamingIgnoresTheWindow() throws {
        try makeConversation(id: "ancient", title: "Old Work", cwd: "/repo",
                             created: cycleStart.addingTimeInterval(-8_640_000))
        XCTAssertEqual(CliCatalog(root: root).records(for: ["ancient"])["ancient"]?.name, "Old Work")
    }

    func testATitlelessConversationIsNotNamed() throws {
        try makeConversation(id: "agent-1", title: nil, cwd: "/repo",
                             created: cycleStart.addingTimeInterval(86_400))
        XCTAssertNil(CliCatalog(root: root).records(for: ["agent-1"])["agent-1"])
    }

    // MARK: - Degradation

    func testAMissingDirectoryYieldsAnEmptyDigest() {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID())")
        XCTAssertEqual(CliCatalog(root: absent).digest(since: cycleStart), .empty)
        XCTAssertTrue(CliCatalog(root: absent).records(for: ["a"]).isEmpty)
    }

    func testAConversationWithNoStoreStillContributesItsMetadata() throws {
        let directory = try makeConversation(id: "agent-1", title: "Work", cwd: "/repo/ko-tests",
                                             created: cycleStart.addingTimeInterval(86_400))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("store.db"))
        let record = try XCTUnwrap(digest().byConversation["agent-1"])
        XCTAssertEqual(record.workspace, "ko-tests", "cost can still be attributed to the repo")
        XCTAssertEqual(record.toolCalls, 0)
    }

    func testCorruptMetadataIsSkipped() throws {
        let directory = root.appendingPathComponent("workspace-hash/broken")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("meta.json"))
        XCTAssertEqual(digest(), .empty)
    }
}
