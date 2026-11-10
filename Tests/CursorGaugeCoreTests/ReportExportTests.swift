import XCTest
@testable import CursorGaugeCore

final class ReportExportTests: XCTestCase {
    private let cycleStart = Date(timeIntervalSince1970: 1_785_542_400) // 2026-08-01T00:00:00Z
    private let cycleEnd = Date(timeIntervalSince1970: 1_788_220_800)   // 2026-09-01T00:00:00Z
    private let now = Date(timeIntervalSince1970: 1_786_492_800)        // 2026-08-12T00:00:00Z
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func event(_ id: String?, cents: Double, cloud: Bool = false) -> SessionEvent {
        SessionEvent(conversationID: id, model: "claude-sonnet-5", cents: cents,
                     timestamp: cycleStart.addingTimeInterval(86_400), isCloud: cloud)
    }

    private func export(
        events: [SessionEvent],
        catalog: [String: SessionRecord] = [:],
        activity: ActivityDigest = .empty,
        truncated: Bool = false,
        promptText: [String: [String]]? = nil
    ) -> ReportExport {
        let snapshot = UsageSnapshot(
            settledSpendCents: events.reduce(0) { $0 + $1.cents },
            liveSpendCents: events.reduce(0) { $0 + $1.cents },
            limitDollars: 200, cycleStart: cycleStart, cycleEnd: cycleEnd,
            todayCents: 0, models: [], lastActivity: nil, capturedAt: now,
            sessions: SessionBreakdown.build(events: events, catalog: catalog),
            sessionsTruncated: truncated,
            events: events
        )
        let report = UsageReport.build(
            snapshot: snapshot, metrics: UsageMetrics(snapshot: snapshot, now: now),
            activity: activity, timeZone: utc, now: now
        )
        return ReportExport.build(report: report, activity: activity,
                                  promptText: promptText, timeZone: utc)
    }

    private func digest(
        _ conversations: [String: ConversationActivity] = [:],
        unavailable: Set<ActivitySource> = []
    ) -> ActivityDigest {
        ActivityDigest(tools: [], prompts: .empty, files: [],
                       byConversation: conversations, daily: [],
                       unavailableSources: unavailable)
    }

    private func object(_ export: ReportExport) throws -> [String: Any] {
        let data = Data(try export.json().utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The ledger

    /// The flat ledger must sum to the cycle. `sessions` rolls subagents into parents, so
    /// exporting that instead would double-count every subagent.
    func testConversationCostsSumToTheCycleTotal() {
        let result = export(
            events: [event("parent", cents: 100), event("child", cents: 200), event("solo", cents: 50)],
            catalog: [
                "parent": SessionRecord(name: "Parent", parentID: nil),
                "child": SessionRecord(name: "Child", parentID: "parent"),
            ]
        )
        XCTAssertEqual(result.conversations.reduce(0) { $0 + $1.cents }, 350)
        XCTAssertEqual(result.attribution.totalCents, 350)
    }

    func testAChatThatDidFreeWorkAppearsWithNoCost() {
        let result = export(
            events: [event("paid", cents: 100)],
            activity: digest([
                "paid": ConversationActivity(workspace: "ko-services", prompts: 1, toolCalls: 5),
                "free": ConversationActivity(workspace: "ko-tests", prompts: 3, toolCalls: 9),
            ])
        )
        let free = result.conversations.first { $0.id == "free" }
        XCTAssertNotNil(free, "a chat that cost nothing still did work and must be counted")
        XCTAssertEqual(free?.cents, 0)
        XCTAssertEqual(free?.toolCalls, 9)
    }

    func testCloudConversationsAreFlagged() {
        let result = export(events: [event("bc-1", cents: 60, cloud: true), event("c1", cents: 40)])
        XCTAssertEqual(result.conversations.first { $0.id == "bc-1" }?.isCloud, true)
        XCTAssertEqual(result.conversations.first { $0.id == "c1" }?.isCloud, false)
    }

    /// A cloud agent has no local record, so which front end ran it is genuinely
    /// unknowable. The export must say `unknown`, not guess `gui`.
    func testALedgerOnlyCloudEventExportsAsUnknownSource() throws {
        let result = export(events: [event("bc-1", cents: 150, cloud: true)])
        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.source, .unknown)
        XCTAssertTrue(conversation.isCloud)
        XCTAssertEqual(conversation.cents, 150)

        let parsed = try object(result)
        let conversations = try XCTUnwrap(parsed["conversations"] as? [[String: Any]])
        XCTAssertEqual(conversations.first?["source"] as? String, "unknown")
    }

    /// The per-chat tool breakdown is the evidence a consumer classifies from, so it has to
    /// survive the export rather than being flattened into a single count.
    func testPerConversationToolBreakdownIsExported() {
        let result = export(
            events: [event("c1", cents: 100)],
            activity: digest(["c1": ConversationActivity(
                toolCalls: 12, tools: ["edit_file_v2": 4, "read_file_v2": 8]
            )])
        )
        XCTAssertEqual(result.conversations.first?.tools, ["edit_file_v2": 4, "read_file_v2": 8])
    }

    // MARK: - Prompt text is opt-in

    func testPromptTextIsAbsentUnlessAskedFor() throws {
        let result = export(
            events: [event("c1", cents: 100)],
            activity: digest(["c1": ConversationActivity(prompts: 1, promptLengths: [42])])
        )
        XCTAssertFalse(result.includesPromptText)
        XCTAssertNil(result.conversations.first?.promptText)
        // Also absent from the encoded form, not merely null.
        XCTAssertFalse(try result.json().contains("promptText"))
        // The shape of the prompts still comes through.
        XCTAssertEqual(result.conversations.first?.promptLengths, [42])
    }

    func testPromptTextIsPresentWhenAskedFor() throws {
        let result = export(
            events: [event("c1", cents: 100)],
            activity: digest(["c1": ConversationActivity(prompts: 1)]),
            promptText: ["c1": ["fix the tracking view"]]
        )
        XCTAssertTrue(result.includesPromptText)
        XCTAssertEqual(result.conversations.first?.promptText, ["fix the tracking view"])
        XCTAssertTrue(try result.json().contains("fix the tracking view"))
    }

    /// With text requested, a chat that has none must say "none" rather than "not collected".
    func testAChatWithNoPromptsGetsAnEmptyListNotNull() {
        let result = export(
            events: [event("c1", cents: 100)],
            activity: digest(["c1": ConversationActivity(toolCalls: 3)]),
            promptText: [:]
        )
        XCTAssertEqual(result.conversations.first?.promptText, [])
    }

    // MARK: - The document

    func testTheDocumentIsValidJSONAndDeclaresItsSchema() throws {
        let parsed = try object(export(events: [event("c1", cents: 100)]))
        XCTAssertEqual(parsed["schema"] as? String, "cursor-gauge/report/1")
        for key in ["cycle", "attribution", "conversations", "daily", "tools", "models",
                    "activityAvailability"] {
            XCTAssertNotNil(parsed[key], "missing \(key)")
        }
    }

    /// A consumer must be able to tell a quiet cycle from an unreadable database per
    /// source, without guessing — and both keys are always present.
    func testAvailabilityIsExportedPerSource() throws {
        let parsed = try object(
            export(events: [event("c1", cents: 100)], activity: digest(unavailable: [.cli]))
        )
        let availability = try XCTUnwrap(parsed["activityAvailability"] as? [String: String])
        XCTAssertEqual(availability, ["cli": "unavailable", "gui": "available"])
    }

    func testAReadableStoreExportsBothSourcesAvailable() throws {
        let parsed = try object(export(events: [event("c1", cents: 100)], activity: .empty))
        let availability = try XCTUnwrap(parsed["activityAvailability"] as? [String: String])
        XCTAssertEqual(availability, ["cli": "available", "gui": "available"],
                       "a quiet readable store is still available")
    }

    /// A short page with a larger declared total is partial even though the page cap was
    /// never hit.
    func testAShortPageIsExportedAsPartial() {
        let complete = export(events: [event("c1", cents: 100)])
        XCTAssertFalse(complete.partial)

        let partial = export(events: [event("c1", cents: 100)], truncated: true)
        XCTAssertTrue(partial.partial,
                      "fewer rows than declared must read partial in JSON")
    }

    func testDatesAreISO8601AndDaysAreCalendarDates() throws {
        let parsed = try object(export(events: [event("c1", cents: 100)]))
        let cycle = try XCTUnwrap(parsed["cycle"] as? [String: Any])
        XCTAssertEqual(cycle["start"] as? String, "2026-08-01T00:00:00Z")
        let daily = try XCTUnwrap(parsed["daily"] as? [[String: Any]])
        XCTAssertEqual(daily.first?["day"] as? String, "2026-08-02",
                       "a day is a calendar date, not a timestamp")
    }

    /// A readable store with no rows is quiet; actual local activity flips the flag.
    func testTheExportStatesWhetherActivityWasSeen() {
        let quiet = export(events: [event("c1", cents: 100)], activity: .empty)
        XCTAssertFalse(quiet.hasActivity)

        let seeing = export(
            events: [event("c1", cents: 100)],
            activity: ActivityDigest(
                tools: [ToolUsage(name: "read_file_v2", calls: 3)], prompts: .empty,
                files: [], byConversation: [:], daily: []
            )
        )
        XCTAssertTrue(seeing.hasActivity)
    }

    func testReconciliationIsCarriedIntoTheExport() {
        let result = export(
            events: [event("c1", cents: 100)],
            activity: digest(["c1": ConversationActivity(workspace: "ko-services")])
        )
        XCTAssertTrue(result.attribution.reconciles)
        XCTAssertEqual(result.attribution.workspaces.first?.workspace, "ko-services")
    }

    /// The JSON workspace objects carry the full directory path, so a consumer can tell
    /// two same-named repos apart the same way the report does.
    func testWorkspaceObjectsCarryTheirFullPath() throws {
        let result = export(
            events: [event("a-1", cents: 120), event("b-1", cents: 80)],
            activity: digest([
                "a-1": ConversationActivity(workspace: "website", workspacePath: "/clients/a/website"),
                "b-1": ConversationActivity(workspace: "website", workspacePath: "/clients/b/website"),
            ])
        )
        let parsed = try object(result)
        let attribution = try XCTUnwrap(parsed["attribution"] as? [String: Any])
        let workspaces = try XCTUnwrap(attribution["workspaces"] as? [[String: Any]])
        let paths = Set(workspaces.compactMap { $0["workspacePath"] as? String })
        XCTAssertEqual(paths, ["/clients/a/website", "/clients/b/website"])
    }

    func testAnEmptyCycleStillEncodes() throws {
        let parsed = try object(export(events: []))
        XCTAssertEqual((parsed["conversations"] as? [Any])?.count, 0)
        XCTAssertNotNil(parsed["cycle"])
    }
}
