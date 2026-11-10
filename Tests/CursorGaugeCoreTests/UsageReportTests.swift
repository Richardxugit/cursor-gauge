import XCTest
@testable import CursorGaugeCore

final class UsageReportTests: XCTestCase {
    private let cycleStart = Date(timeIntervalSince1970: 1_785_542_400) // 2026-08-01T00:00:00Z
    private let cycleEnd = Date(timeIntervalSince1970: 1_788_220_800)   // 2026-09-01T00:00:00Z
    private let now = Date(timeIntervalSince1970: 1_786_492_800)        // 2026-08-12T00:00:00Z
    private let utc = TimeZone(secondsFromGMT: 0)!

    // MARK: - Fixtures

    private func event(
        _ conversation: String?, cents: Double, model: String = "claude-sonnet-5",
        cloud: Bool = false, day: Int = 5
    ) -> SessionEvent {
        SessionEvent(
            conversationID: conversation, model: model, cents: cents,
            timestamp: cycleStart.addingTimeInterval(Double(day - 1) * 86_400 + 3_600),
            isCloud: cloud
        )
    }

    private func activity(
        _ entries: [String: ConversationActivity], daily: [DayActivity] = []
    ) -> ActivityDigest {
        ActivityDigest(
            tools: [], prompts: .empty, files: [], byConversation: entries, daily: daily
        )
    }

    private func conversation(
        workspace: String?, prompts: Int = 0, toolCalls: Int = 0, linesAdded: Int = 0,
        source: ActivitySource = .gui
    ) -> ConversationActivity {
        ConversationActivity(
            workspace: workspace, workspacePath: workspace.map { "/Users/pxu/Desktop/\($0)" },
            mode: "agent", prompts: prompts, toolCalls: toolCalls, linesAdded: linesAdded,
            source: source
        )
    }

    private func snapshot(
        events: [SessionEvent], catalog: [String: SessionRecord] = [:]
    ) -> UsageSnapshot {
        UsageSnapshot(
            settledSpendCents: events.reduce(0) { $0 + $1.cents },
            liveSpendCents: events.reduce(0) { $0 + $1.cents },
            limitDollars: 200,
            cycleStart: cycleStart, cycleEnd: cycleEnd,
            todayCents: 0, models: [], lastActivity: events.map(\.timestamp).max(),
            capturedAt: now,
            sessions: SessionBreakdown.build(events: events, catalog: catalog),
            events: events
        )
    }

    private func report(
        events: [SessionEvent],
        catalog: [String: SessionRecord] = [:],
        activity digest: ActivityDigest = .empty
    ) -> UsageReport {
        let snap = snapshot(events: events, catalog: catalog)
        return UsageReport.build(
            snapshot: snap, metrics: UsageMetrics(snapshot: snap, now: now),
            activity: digest, timeZone: utc, now: now
        )
    }

    // MARK: - Attribution

    func testAttributesSpendToTheRepoTheChatBelongsTo() {
        let result = report(
            events: [event("c1", cents: 300), event("c2", cents: 100)],
            activity: activity([
                "c1": conversation(workspace: "ko-services"),
                "c2": conversation(workspace: "ko-ui-lib"),
            ])
        )
        XCTAssertEqual(result.workspaces.map(\.workspace), ["ko-services", "ko-ui-lib"],
                       "ranked by cost")
        XCTAssertEqual(result.workspaces.first?.cents, 300)
        XCTAssertEqual(result.workspaces.first?.sessions, 1)
    }

    func testSpendFromSeveralChatsInOneRepoIsCombined() throws {
        let result = report(
            events: [event("c1", cents: 100), event("c2", cents: 50), event("c3", cents: 400)],
            activity: activity([
                "c1": conversation(workspace: "ko-services"),
                "c2": conversation(workspace: "ko-services"),
                "c3": conversation(workspace: "ko-ui-lib"),
            ])
        )
        let services = try XCTUnwrap(result.workspaces.first { $0.workspace == "ko-services" })
        XCTAssertEqual(services.cents, 150)
        XCTAssertEqual(services.sessions, 2)
    }

    /// Every subagent on the real account carries its own workspace, matching its parent's
    /// in all 123 cases — so a subagent's spend lands on the right repo directly.
    func testSubagentSpendLandsOnItsOwnRepo() {
        let result = report(
            events: [event("parent", cents: 100), event("child", cents: 200)],
            catalog: [
                "parent": SessionRecord(name: "Parent", parentID: nil),
                "child": SessionRecord(name: "Child", parentID: "parent"),
            ],
            activity: activity([
                "parent": conversation(workspace: "ko-services"),
                "child": conversation(workspace: "ko-services"),
            ])
        )
        XCTAssertEqual(result.workspaces.count, 1)
        XCTAssertEqual(result.workspaces.first?.cents, 300)
    }

    func testWorkspaceRowsCarryTheActivityBehindThem() {
        let result = report(
            events: [event("c1", cents: 100)],
            activity: activity(["c1": conversation(workspace: "ko-services", prompts: 4,
                                                   toolCalls: 90, linesAdded: 250)])
        )
        let repo = result.workspaces.first
        XCTAssertEqual(repo?.prompts, 4)
        XCTAssertEqual(repo?.toolCalls, 90)
        XCTAssertEqual(repo?.linesAdded, 250)
    }

    // MARK: - The three residual buckets

    /// A cloud agent's chat lives on Cursor's servers, so it has no local row and no repo.
    /// Saying "ran in the cloud" is worth more than saying "unattributed".
    func testCloudSpendIsItsOwnBucketRatherThanUnattributed() {
        let result = report(events: [
            event("bc-1", cents: 250, cloud: true),
            event("bc-2", cents: 50, cloud: true),
        ])
        XCTAssertEqual(result.cloudCents, 300)
        XCTAssertEqual(result.cloudCount, 2, "two distinct cloud conversations")
        XCTAssertEqual(result.unattributedCents, 0)
        XCTAssertTrue(result.workspaces.isEmpty)
    }

    func testBilledWorkWithNoLocalRecordIsUnattributed() {
        let result = report(events: [event("ghost", cents: 175)])
        XCTAssertEqual(result.unattributedCents, 175)
        XCTAssertEqual(result.cloudCents, 0)
    }

    func testAnEventWithNoConversationIsUnattributed() {
        let result = report(events: [event(nil, cents: 42)])
        XCTAssertEqual(result.unattributedCents, 42)
    }

    /// A cloud agent that did sync down has a repo, so it belongs to that repo. Counting it
    /// in both places would double it.
    func testCloudSpendWithAKnownRepoIsAttributedToTheRepo() {
        let result = report(
            events: [event("c1", cents: 100, cloud: true)],
            activity: activity(["c1": conversation(workspace: "ko-services")])
        )
        XCTAssertEqual(result.workspaces.first?.cents, 100)
        XCTAssertEqual(result.cloudCents, 0)
    }

    func testLocalWorkThatCostNothingIsCountedButNotCosted() {
        let result = report(
            events: [event("c1", cents: 100)],
            activity: activity([
                "c1": conversation(workspace: "ko-services", prompts: 2, toolCalls: 10),
                "free": conversation(workspace: "ko-tests", prompts: 3, toolCalls: 20),
                "idle": conversation(workspace: "ko-tests"),
            ])
        )
        XCTAssertEqual(result.unbilledConversations, 1,
                       "the chat with activity but no spend; the idle one is not work")
        XCTAssertEqual(result.totalCents, 100, "unbilled work must not inflate the total")
        XCTAssertEqual(result.workspaces.map(\.workspace), ["ko-services"])
    }

    // MARK: - Front ends

    /// Billed work with no local record — a cloud agent, a ledger-only chat, or an event
    /// with no conversation id at all — must not be dressed up as editor work. Labelling it
    /// `unknown` keeps the editor/CLI split honest.
    func testUnknownActivityIsNotLabelledAsEditorWork() throws {
        let result = report(
            events: [
                event("gui-1", cents: 200),
                event("cli-1", cents: 100),
                event(nil, cents: 42),
                event("ghost", cents: 58),
            ],
            activity: activity([
                "gui-1": conversation(workspace: "ko-services"),
                "cli-1": conversation(workspace: "ko-services", source: .cli),
            ])
        )

        let gui = try XCTUnwrap(result.bySource[.gui])
        XCTAssertEqual(gui.cents, 200, "only the known GUI chat belongs to the editor")
        XCTAssertEqual(gui.conversations, 1)

        let cli = try XCTUnwrap(result.bySource[.cli])
        XCTAssertEqual(cli.cents, 100)

        let unknown = try XCTUnwrap(result.bySource[.unknown])
        XCTAssertEqual(unknown.cents, 100, "the no-id event plus the unknown conversation")
        XCTAssertEqual(unknown.conversations, 1, "a nil conversation id is not a chat")
    }

    // MARK: - The identity that proves nothing was lost

    func testEveryBucketTogetherEqualsTheCycleTotal() {
        let result = report(
            events: [
                event("c1", cents: 300), event("c2", cents: 125),
                event("bc-1", cents: 60, cloud: true),
                event("ghost", cents: 15), event(nil, cents: 5),
            ],
            activity: activity([
                "c1": conversation(workspace: "ko-services"),
                "c2": conversation(workspace: "ko-ui-lib"),
            ])
        )
        let parts = result.workspaces.reduce(0) { $0 + $1.cents }
            + result.cloudCents + result.unattributedCents
        XCTAssertEqual(parts, 505)
        XCTAssertEqual(result.totalCents, 505)
        XCTAssertTrue(result.reconciles)
    }

    func testReconciliationHoldsWhenEverythingIsAttributed() {
        let result = report(
            events: [event("c1", cents: 100)],
            activity: activity(["c1": conversation(workspace: "ko-services")])
        )
        XCTAssertTrue(result.reconciles)
    }

    // MARK: - Sessions

    func testSessionsCarryBothCostAndActivity() throws {
        let result = report(
            events: [event("c1", cents: 300)],
            catalog: ["c1": SessionRecord(name: "OXP-54 tracking view", parentID: nil)],
            activity: activity(["c1": conversation(workspace: "ko-services", prompts: 6, toolCalls: 40)])
        )
        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(session.name, "OXP-54 tracking view")
        XCTAssertEqual(session.workspace, "ko-services")
        XCTAssertEqual(session.cents, 300)
        XCTAssertEqual(session.prompts, 6)
        XCTAssertEqual(session.toolCalls, 40)
    }

    /// The cost shown against a session rolls its subagents in, so the activity must too.
    func testASessionsActivityIncludesItsSubagents() throws {
        let result = report(
            events: [event("parent", cents: 100), event("child", cents: 200)],
            catalog: [
                "parent": SessionRecord(name: "Parent", parentID: nil),
                "child": SessionRecord(name: "Child", parentID: "parent"),
            ],
            activity: activity([
                "parent": conversation(workspace: "ko-services", prompts: 2, toolCalls: 10),
                "child": conversation(workspace: "ko-services", prompts: 1, toolCalls: 30),
            ])
        )
        let root = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(root.cents, 300)
        XCTAssertEqual(root.prompts, 3)
        XCTAssertEqual(root.toolCalls, 40)
    }

    // MARK: - Models

    func testModelsArriveRelabelledAndMerged() {
        let result = report(events: [
            event("c1", cents: 100, model: "default"),
            event("c1", cents: 50, model: "auto-smart"),
            event("c1", cents: 25, model: "claude-sonnet-5"),
        ])
        XCTAssertEqual(result.models.map(\.model), [ModelName.auto, "claude-sonnet-5"])
        XCTAssertEqual(result.models.first?.cents, 150, "both Auto spellings are one row")
    }

    // MARK: - Daily rhythm

    func testTheDailySeriesPutsCostAndActivityOnTheSameDay() {
        let day5 = cycleStart.addingTimeInterval(4 * 86_400)
        let result = report(
            events: [event("c1", cents: 120, day: 5)],
            activity: activity([:], daily: [DayActivity(day: day5, prompts: 3, toolCalls: 20)])
        )
        XCTAssertEqual(result.daily.count, 1)
        XCTAssertEqual(result.daily.first?.cents, 120)
        XCTAssertEqual(result.daily.first?.prompts, 3)
        XCTAssertEqual(result.daily.first?.toolCalls, 20)
    }

    func testADayWithSpendButNoLocalRecordStillAppears() {
        let result = report(events: [event("bc-1", cents: 60, cloud: true, day: 7)])
        XCTAssertEqual(result.daily.count, 1)
        XCTAssertEqual(result.daily.first?.cents, 60)
        XCTAssertEqual(result.daily.first?.toolCalls, 0)
    }

    func testTheDailySeriesIsChronological() {
        let result = report(events: [
            event("c1", cents: 10, day: 9), event("c1", cents: 20, day: 2),
        ])
        XCTAssertEqual(result.daily.map(\.day), result.daily.map(\.day).sorted())
    }

    // MARK: - Degradation

    /// The local store is the activity half only. Losing it must cost detail, never numbers.
    func testAnUnreadableLocalStoreStillProducesTheCostHalf() {
        let blind = ActivityDigest(
            tools: [], prompts: .empty, files: [], byConversation: [:], daily: [],
            unavailableSources: [.gui]
        )
        let result = report(events: [event("c1", cents: 300), event("c2", cents: 100)],
                            activity: blind)
        XCTAssertEqual(result.totalCents, 400)
        XCTAssertEqual(result.unattributedCents, 400, "with no local store nothing has a repo")
        XCTAssertTrue(result.reconciles)
        XCTAssertFalse(result.hasActivity, "the report should say the activity half is missing")
        XCTAssertEqual(result.unavailableActivitySources, [.gui])
    }

    // MARK: - Availability

    /// The report carries which stores could not be read, so the page and the JSON can say
    /// so rather than guessing from the absence of data.
    func testTheReportCarriesUnavailableActivitySources() {
        let cliUnavailable = ActivityDigest(
            tools: [], prompts: .empty, files: [], byConversation: [:], daily: [],
            unavailableSources: [.cli]
        )
        let result = report(events: [event("c1", cents: 100)], activity: cliUnavailable)
        XCTAssertEqual(result.unavailableActivitySources, [.cli])
    }

    /// A quiet store and an unreadable one both have no activity rows, but only the
    /// unreadable one is flagged: `hasActivity` still describes data, not availability.
    func testUnavailableSourcesDoNotChangeHasActivitySemantics() {
        let quiet = report(events: [event("c1", cents: 100)], activity: .empty)
        XCTAssertFalse(quiet.hasActivity)
        XCTAssertTrue(quiet.unavailableActivitySources.isEmpty,
                      "a readable quiet store is not a failure")

        let blind = ActivityDigest(
            tools: [], prompts: .empty, files: [], byConversation: [:], daily: [],
            unavailableSources: [.gui, .cli]
        )
        let unreadable = report(events: [event("c1", cents: 100)], activity: blind)
        XCTAssertFalse(unreadable.hasActivity)
        XCTAssertEqual(unreadable.unavailableActivitySources, [.gui, .cli])

        let mixed = ActivityDigest(
            tools: [ToolUsage(name: "read_file_v2", calls: 1)], prompts: .empty,
            files: [], byConversation: [:], daily: [], unavailableSources: [.cli]
        )
        let partial = report(events: [event("c1", cents: 100)], activity: mixed)
        XCTAssertTrue(partial.hasActivity,
                      "data read alongside an unreadable store is still activity")
        XCTAssertEqual(partial.unavailableActivitySources, [.cli])
    }

    func testAReportOverAnEmptyCycleIsStillValid() {
        let result = report(events: [])
        XCTAssertEqual(result.totalCents, 0)
        XCTAssertTrue(result.reconciles)
        XCTAssertTrue(result.workspaces.isEmpty)
        XCTAssertTrue(result.unavailableActivitySources.isEmpty,
                      "an empty readable cycle is quiet, not broken")
    }
}
