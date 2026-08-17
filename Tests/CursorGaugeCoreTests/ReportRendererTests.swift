import XCTest
@testable import CursorGaugeCore

final class ReportRendererTests: XCTestCase {
    private let cycleStart = Date(timeIntervalSince1970: 1_785_542_400) // 2026-08-01T00:00:00Z
    private let cycleEnd = Date(timeIntervalSince1970: 1_788_220_800)   // 2026-09-01T00:00:00Z
    private let now = Date(timeIntervalSince1970: 1_786_492_800)        // 2026-08-12T00:00:00Z

    private func page(
        events: [SessionEvent],
        catalog: [String: SessionRecord] = [:],
        activity: ActivityDigest = .empty
    ) -> String {
        let snapshot = UsageSnapshot(
            settledSpendCents: events.reduce(0) { $0 + $1.cents },
            liveSpendCents: events.reduce(0) { $0 + $1.cents },
            limitDollars: 200,
            cycleStart: cycleStart, cycleEnd: cycleEnd, todayCents: 0,
            models: [], lastActivity: nil, capturedAt: now,
            sessions: SessionBreakdown.build(events: events, catalog: catalog),
            events: events
        )
        let report = UsageReport.build(
            snapshot: snapshot, metrics: UsageMetrics(snapshot: snapshot, now: now),
            activity: activity, timeZone: TimeZone(secondsFromGMT: 0)!, now: now
        )
        return ReportRenderer.html(report)
    }

    private func event(_ id: String?, cents: Double, cloud: Bool = false) -> SessionEvent {
        SessionEvent(conversationID: id, model: "claude-sonnet-5", cents: cents,
                     timestamp: cycleStart.addingTimeInterval(86_400), isCloud: cloud)
    }

    private func digest(
        _ conversations: [String: ConversationActivity] = [:],
        tools: [ToolUsage] = [], prompts: PromptStats = .empty, files: [FileTypeUsage] = []
    ) -> ActivityDigest {
        ActivityDigest(tools: tools, prompts: prompts, files: files,
                       byConversation: conversations, daily: [])
    }

    // MARK: - Escaping

    /// Chat names are chat titles: user data, reaching the page verbatim. A name containing
    /// markup must not become markup.
    func testChatNamesAreEscapedNotInjected() {
        let html = page(
            events: [event("c1", cents: 100)],
            catalog: ["c1": SessionRecord(name: "<script>alert('x')</script>", parentID: nil)]
        )
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testRepositoryNamesAreEscaped() {
        let html = page(
            events: [event("c1", cents: 100)],
            activity: digest(["c1": ConversationActivity(workspace: "a&b<c>")])
        )
        XCTAssertTrue(html.contains("a&amp;b&lt;c&gt;"))
        XCTAssertFalse(html.contains("a&b<c>"))
    }

    /// `&` has to be replaced first, or the ampersands introduced by the other replacements
    /// get encoded a second time and the page shows `&amp;lt;`.
    func testAmpersandIsEscapedOnce() {
        XCTAssertEqual(ReportRenderer.escape("<&>"), "&lt;&amp;&gt;")
    }

    func testToolNamesAreEscaped() {
        let html = page(events: [event("c1", cents: 10)],
                        activity: digest(tools: [ToolUsage(name: "<b>evil</b>", calls: 3)]))
        XCTAssertFalse(html.contains("<b>evil</b>"))
    }

    // MARK: - Content

    func testTheHeadlineFiguresAppear() {
        let html = page(events: [event("c1", cents: 4_500)])
        XCTAssertTrue(html.contains("$45.00"), "spend")
        XCTAssertTrue(html.contains("$200"), "the limit")
    }

    func testTheReconciliationVerdictIsStated() {
        let html = page(events: [event("c1", cents: 100)],
                        activity: digest(["c1": ConversationActivity(workspace: "ko-services")]))
        XCTAssertTrue(html.contains("adds up to the cycle total"))
        XCTAssertFalse(html.contains("DOES NOT add up"))
    }

    func testCloudSpendIsNamedAsSuchRatherThanHidden() {
        let html = page(events: [event("bc-1", cents: 250, cloud: true)])
        XCTAssertTrue(html.contains("Cloud agents"))
        XCTAssertTrue(html.contains("$2.50"))
    }

    func testAMissingLocalStoreIsStatedOnThePage() {
        let html = page(events: [event("c1", cents: 100)], activity: .empty)
        XCTAssertTrue(html.contains("local store could not be read"),
                      "a cost-only report should say why the rest is absent")
    }

    func testAReadableStoreDoesNotShowTheMissingStoreNotice() {
        let html = page(
            events: [event("c1", cents: 100)],
            activity: digest(["c1": ConversationActivity(workspace: "ko-services")],
                             tools: [ToolUsage(name: "read_file_v2", calls: 10)])
        )
        XCTAssertFalse(html.contains("local store could not be read"))
    }

    // MARK: - Well-formedness

    func testThePageIsSelfContained() {
        let html = page(events: [event("c1", cents: 100)])
        for remote in ["http://", "https://", "<script", "src=", "@import"] {
            XCTAssertFalse(html.contains(remote),
                           "a report must open offline with no external request: found \(remote)")
        }
    }

    func testBothThemesAreDefined() {
        let html = page(events: [event("c1", cents: 100)])
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(html.contains("[data-theme=\"dark\"]"))
    }

    /// An empty cycle divides by zero in every bar width unless the helper guards it.
    func testAnEmptyCycleRendersWithoutProducingNaN() {
        let html = page(events: [])
        XCTAssertFalse(html.lowercased().contains("nan"))
        XCTAssertFalse(html.contains("inf%"))
        XCTAssertTrue(html.contains("Cursor usage"))
    }

    func testEveryOpenedSectionIsClosed() {
        let html = page(
            events: [event("c1", cents: 100), event("bc-1", cents: 50, cloud: true)],
            catalog: ["c1": SessionRecord(name: "Work", parentID: nil)],
            activity: digest(
                ["c1": ConversationActivity(workspace: "ko-services", prompts: 2, toolCalls: 8)],
                tools: [ToolUsage(name: "read_file_v2", calls: 8, errors: 1)],
                prompts: PromptStats(count: 2, medianChars: 40, longestChars: 90,
                                     commands: [CommandUsage(command: "/ko-feature", count: 1)]),
                files: [FileTypeUsage(ext: ".ts", reads: 5, edits: 2)]
            )
        )
        for tag in ["div", "section", "span", "table", "ul", "li", "figure"] {
            let opened = html.components(separatedBy: "<\(tag)").count - 1
            let closed = html.components(separatedBy: "</\(tag)>").count - 1
            XCTAssertEqual(opened, closed, "<\(tag)> opened \(opened) times, closed \(closed)")
        }
    }
}
