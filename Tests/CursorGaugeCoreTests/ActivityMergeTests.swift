import XCTest
@testable import CursorGaugeCore

/// Cursor's editor and its CLI keep unrelated stores. These cover the seam where the two
/// are combined into one window.
final class ActivityMergeTests: XCTestCase {
    private func digest(
        tools: [ToolUsage] = [], files: [FileTypeUsage] = [],
        conversations: [String: ConversationActivity] = [:],
        daily: [DayActivity] = [], prompts: PromptStats = .empty
    ) -> ActivityDigest {
        ActivityDigest(tools: tools, prompts: prompts, files: files,
                       byConversation: conversations, daily: daily)
    }

    func testConversationsFromBothFrontEndsSurvive() {
        let merged = digest(conversations: ["gui-1": ConversationActivity(workspace: "ko-ui-lib")])
            .merging(digest(conversations: [
                "cli-1": ConversationActivity(workspace: "ko-services", source: .cli),
            ]))
        XCTAssertEqual(Set(merged.byConversation.keys), ["gui-1", "cli-1"])
        XCTAssertEqual(merged.byConversation["gui-1"]?.source, .gui)
        XCTAssertEqual(merged.byConversation["cli-1"]?.source, .cli)
    }

    /// The editor calls it `read_file_v2`, the CLI calls it `Read`. They do comparable work,
    /// but asserting they are the same tool is an equivalence this code cannot verify — so
    /// they stay separate rows and the reader decides.
    func testDifferentToolVocabulariesAreNotSilentlyUnified() {
        let merged = digest(tools: [ToolUsage(name: "read_file_v2", calls: 10)])
            .merging(digest(tools: [ToolUsage(name: "Read", calls: 4)]))
        XCTAssertEqual(merged.tools.map(\.name), ["read_file_v2", "Read"])
    }

    func testTheSameToolNameFromBothSidesIsSummed() {
        let merged = digest(tools: [ToolUsage(name: "web_fetch", calls: 3, errors: 1)])
            .merging(digest(tools: [ToolUsage(name: "web_fetch", calls: 2, errors: 1)]))
        XCTAssertEqual(merged.tools.count, 1)
        XCTAssertEqual(merged.tools.first?.calls, 5)
        XCTAssertEqual(merged.tools.first?.errors, 2)
    }

    func testAnMCPServerSurvivesTheMerge() {
        let merged = digest(tools: [ToolUsage(name: "getJiraIssue", calls: 1, server: "atlassian")])
            .merging(digest(tools: [ToolUsage(name: "getJiraIssue", calls: 2)]))
        XCTAssertEqual(merged.tools.first?.server, "atlassian")
    }

    func testFileTypesAndDaysAreCombined() {
        let day = Date(timeIntervalSince1970: 1_785_628_800)
        let merged = digest(
            files: [FileTypeUsage(ext: ".ts", reads: 5, edits: 1)],
            daily: [DayActivity(day: day, prompts: 2, toolCalls: 10)]
        ).merging(digest(
            files: [FileTypeUsage(ext: ".ts", reads: 2, edits: 3), FileTypeUsage(ext: ".md", reads: 1, edits: 0)],
            daily: [DayActivity(day: day, prompts: 1, toolCalls: 4)]
        ))
        XCTAssertEqual(merged.files.first { $0.ext == ".ts" }?.reads, 7)
        XCTAssertEqual(merged.files.first { $0.ext == ".ts" }?.edits, 4)
        XCTAssertEqual(merged.daily.count, 1, "the same day from both sides is one row")
        XCTAssertEqual(merged.daily.first?.prompts, 3)
        XCTAssertEqual(merged.daily.first?.toolCalls, 14)
    }

    /// A median cannot be merged from two medians. It is recomputed from the underlying
    /// lengths, because quoting a figure that was never measured is worse than quoting none.
    func testTheMedianIsRecomputedNotAveraged() {
        let merged = digest(
            conversations: ["a": ConversationActivity(prompts: 3, promptLengths: [10, 20, 30])],
            prompts: PromptStats(count: 3, medianChars: 20, longestChars: 30, commands: [])
        ).merging(digest(
            conversations: ["b": ConversationActivity(prompts: 2, promptLengths: [1000, 2000], source: .cli)],
            prompts: PromptStats(count: 2, medianChars: 2000, longestChars: 2000, commands: [])
        ))
        XCTAssertEqual(merged.prompts.count, 5)
        XCTAssertEqual(merged.prompts.medianChars, 30, "the middle of 10,20,30,1000,2000")
        XCTAssertEqual(merged.prompts.longestChars, 2000)
    }

    func testMergingWithNothingChangesNothing() {
        let original = digest(
            tools: [ToolUsage(name: "read_file_v2", calls: 3)],
            conversations: ["a": ConversationActivity(workspace: "ko-tests")]
        )
        XCTAssertEqual(original.merging(.empty), original)
    }
}

/// The reconciliation identity, which asks whether money was lost — not whether it rounds.
final class ReconciliationTests: XCTestCase {
    private let cycleStart = Date(timeIntervalSince1970: 1_785_542_400)
    private let now = Date(timeIntervalSince1970: 1_786_492_800)

    private func report(_ events: [SessionEvent], workspaces: [String: String]) -> UsageReport {
        let snapshot = UsageSnapshot(
            settledSpendCents: events.reduce(0) { $0 + $1.cents },
            liveSpendCents: events.reduce(0) { $0 + $1.cents }, limitDollars: 200,
            cycleStart: cycleStart, cycleEnd: cycleStart.addingTimeInterval(2_678_400),
            todayCents: 0, models: [], lastActivity: nil, capturedAt: now,
            sessions: SessionBreakdown.build(events: events, catalog: [:]), events: events
        )
        let activity = ActivityDigest(
            tools: [], prompts: .empty, files: [],
            byConversation: workspaces.mapValues { ConversationActivity(workspace: $0) }, daily: []
        )
        return UsageReport.build(snapshot: snapshot, metrics: UsageMetrics(snapshot: snapshot, now: now),
                                 activity: activity, timeZone: TimeZone(secondsFromGMT: 0)!, now: now)
    }

    private func event(_ id: String, _ cents: Double) -> SessionEvent {
        SessionEvent(conversationID: id, model: "m", cents: cents,
                     timestamp: cycleStart.addingTimeInterval(86_400))
    }

    /// Many repositories with fractional cents each: summing them already rounded drifts from
    /// the rounded total, which once reported a failure on a cycle whose raw figures agreed
    /// exactly. Rounding is a display concern; this check is about lost money.
    func testManyRepositoriesWithFractionalCentsStillReconcile() {
        let events = (1...9).map { event("c\($0)", Double($0) * 11.117) }
        let workspaces = Dictionary(uniqueKeysWithValues: (1...9).map { ("c\($0)", "repo-\($0)") })
        let result = report(events, workspaces: workspaces)
        XCTAssertEqual(result.workspaces.count, 9)
        XCTAssertEqual(result.attributedCents, result.totalCents, accuracy: 0.000_001)
        XCTAssertTrue(result.reconciles)
    }

    func testTheCheckStillCatchesMoneyThatWentNowhere() {
        // Every event attributed, then a bucket understated: the identity must fail.
        let result = report([event("c1", 100)], workspaces: ["c1": "repo"])
        XCTAssertTrue(result.reconciles)
        let broken = UsageReport(
            generatedAt: now, cycleStart: cycleStart, cycleEnd: cycleStart, metrics: result.metrics,
            truncated: false, workspaces: [], cloudCents: 0, cloudCount: 0,
            unattributedCents: 0, unbilledConversations: 0, bySource: [:], totalCents: 100,
            models: [], sessions: [], ledger: [], tools: [], prompts: .empty, files: [], daily: []
        )
        XCTAssertFalse(broken.reconciles, "a cycle whose buckets hold nothing cannot reconcile")
    }
}
