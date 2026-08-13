import XCTest
@testable import CursorGaugeCore

final class SessionRollupTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_785_999_000)

    private func event(
        _ id: String?, _ cents: Double, _ offset: TimeInterval = 0,
        model: String? = nil, cloud: Bool = false
    ) -> SessionEvent {
        SessionEvent(
            conversationID: id, model: model, cents: cents,
            timestamp: t0.addingTimeInterval(offset), isCloud: cloud
        )
    }

    private func named(_ name: String, parent: String? = nil) -> SessionRecord {
        SessionRecord(name: name, parentID: parent)
    }

    // MARK: - Grouping

    func testSumsEventsSharingAConversation() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 100), event("a", 50), event("b", 25)],
            catalog: ["a": named("Alpha"), "b": named("Beta")]
        )
        XCTAssertEqual(breakdown.ranked.map(\.id), ["a", "b"])
        XCTAssertEqual(breakdown.ranked[0].ownCents, 150, accuracy: 0.001)
        XCTAssertEqual(breakdown.ranked[0].requestCount, 2)
    }

    func testTracksMostRecentActivityPerSession() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 10, 0), event("a", 10, 600), event("a", 10, 300)],
            catalog: ["a": named("Alpha")]
        )
        XCTAssertEqual(breakdown.ranked[0].lastActivity, t0.addingTimeInterval(600))
    }

    // MARK: - Subagent nesting

    func testNestsSubagentsUnderTheirParent() {
        // The real shape: a planning chat that spawned task chats.
        let breakdown = SessionBreakdown.build(
            events: [event("parent", 221), event("kid1", 283), event("kid2", 179)],
            catalog: [
                "parent": named("OXP-54 feature discussion"),
                "kid1": named("Implement Task 4", parent: "parent"),
                "kid2": named("Implement Task 6", parent: "parent"),
            ]
        )
        XCTAssertEqual(breakdown.ranked.count, 1, "subagents must not appear as roots")
        let root = breakdown.ranked[0]
        XCTAssertEqual(root.id, "parent")
        XCTAssertEqual(root.ownCents, 221, accuracy: 0.001)
        XCTAssertEqual(root.rolledCents, 683, accuracy: 0.001)
        XCTAssertEqual(root.children.map(\.id), ["kid1", "kid2"], "children rank by rolled cost")
    }

    func testRollsUpThroughMoreThanOneLevel() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 10), event("b", 20), event("c", 40)],
            catalog: ["a": named("A"), "b": named("B", parent: "a"), "c": named("C", parent: "b")]
        )
        XCTAssertEqual(breakdown.ranked.count, 1)
        XCTAssertEqual(breakdown.ranked[0].rolledCents, 70, accuracy: 0.001)
    }

    func testIncludesParentThatSpentNothingItself() {
        // A parent can have no billed requests of its own; it must still anchor its children.
        let breakdown = SessionBreakdown.build(
            events: [event("kid", 500)],
            catalog: ["parent": named("Planning"), "kid": named("Task", parent: "parent")]
        )
        XCTAssertEqual(breakdown.ranked.map(\.id), ["parent"])
        XCTAssertEqual(breakdown.ranked[0].ownCents, 0, accuracy: 0.001)
        XCTAssertEqual(breakdown.ranked[0].rolledCents, 500, accuracy: 0.001)
    }

    // MARK: - Ranking

    func testRanksRootsByRolledNotOwnCost() {
        // `big` outspends `small` on its own, but small's subagent makes it the larger job.
        let breakdown = SessionBreakdown.build(
            events: [event("big", 300), event("small", 50), event("kid", 500)],
            catalog: ["big": named("Big"), "small": named("Small"), "kid": named("Kid", parent: "small")]
        )
        XCTAssertEqual(breakdown.ranked.map(\.id), ["small", "big"])
    }

    // MARK: - Degenerate input

    func testPromotesOrphanToRootWhenParentIsUnknown() {
        let breakdown = SessionBreakdown.build(
            events: [event("kid", 100)],
            catalog: ["kid": named("Orphan", parent: "vanished")]
        )
        XCTAssertEqual(breakdown.ranked.map(\.id), ["kid"])
        XCTAssertEqual(breakdown.totalCents, 100, accuracy: 0.001)
    }

    func testBreaksParentCycleWithoutHangingOrDoubleCounting() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 100), event("b", 100)],
            catalog: ["a": named("A", parent: "b"), "b": named("B", parent: "a")]
        )
        XCTAssertEqual(breakdown.totalCents, 200, accuracy: 0.001)
        let emitted = breakdown.ranked.reduce(0) { $0 + $1.rolledCents } + breakdown.unnamedCents
        XCTAssertEqual(emitted, 200, accuracy: 0.001, "a cycle must not duplicate or drop spend")
    }

    func testEmptyInputProducesEmptyBreakdown() {
        let breakdown = SessionBreakdown.build(events: [], catalog: [:])
        XCTAssertTrue(breakdown.ranked.isEmpty)
        XCTAssertEqual(breakdown.totalCents, 0)
        XCTAssertEqual(breakdown.unnamedCount, 0)
    }

    // MARK: - Un-nameable sessions

    func testAggregatesRootsWithNoLocalRecord() {
        // Nine of sixteen roots had no local record on the real account.
        let breakdown = SessionBreakdown.build(
            events: [event("known", 100), event("ghost1", 40), event("ghost2", 60)],
            catalog: ["known": named("Known")]
        )
        XCTAssertEqual(breakdown.ranked.map(\.id), ["known"])
        XCTAssertEqual(breakdown.unnamedCents, 100, accuracy: 0.001)
        XCTAssertEqual(breakdown.unnamedCount, 2)
    }

    func testCountsEventsWithNoConversationIDAsUnattributed() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 100), event(nil, 25)],
            catalog: ["a": named("Alpha")]
        )
        XCTAssertEqual(breakdown.totalCents, 125, accuracy: 0.001)
        XCTAssertEqual(breakdown.unnamedCents, 25, accuracy: 0.001, "spend must never vanish")
        XCTAssertEqual(breakdown.unnamedCount, 0, "an unattributed event is not a session")
    }

    func testRankedPlusUnnamedAlwaysEqualsTotal() {
        let breakdown = SessionBreakdown.build(
            events: [
                event("a", 1_364), event("b", 301), event("ghost", 593),
                event("kid", 283), event(nil, 12),
            ],
            catalog: ["a": named("A"), "b": named("B"), "kid": named("Kid", parent: "a")]
        )
        let sum = breakdown.ranked.reduce(0) { $0 + $1.rolledCents } + breakdown.unnamedCents
        XCTAssertEqual(sum, breakdown.totalCents, accuracy: 0.001)
    }

    func testEventWithNoModelIsStillCountedInTheSessionTotal() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 100, model: "gpt"), event("a", 25, model: nil)],
            catalog: ["a": named("Alpha")]
        )
        XCTAssertEqual(breakdown.ranked[0].rolledCents, 125, accuracy: 0.001)
    }

    // MARK: - Cycle-wide model list

    func testCollectsModelSpendAcrossEveryEvent() {
        // Includes spend from sessions that could never be named, which is still real money.
        let breakdown = SessionBreakdown.build(
            events: [
                event("a", 100, model: "sonnet"), event("kid", 50, model: "fast"),
                event("ghost", 30, model: "sonnet"), event(nil, 20, model: "fast"),
            ],
            catalog: ["a": named("Alpha"), "kid": named("Kid", parent: "a")]
        )
        XCTAssertEqual(
            breakdown.models,
            [ModelSpend(model: "sonnet", cents: 130), ModelSpend(model: "fast", cents: 70)]
        )
    }

    func testCycleModelListIsOrderedByCost() {
        let breakdown = SessionBreakdown.build(
            events: [
                event("a", 10, model: "cheap"), event("a", 900, model: "dear"),
                event("a", 300, model: "middling"),
            ],
            catalog: ["a": named("Alpha")]
        )
        XCTAssertEqual(breakdown.models.map(\.model), ["dear", "middling", "cheap"])
    }

    /// `default` is what Cursor bills an Auto request under when it doesn't record which
    /// model it routed to. It names nothing and reads like a placeholder, so it carries
    /// the picker's own word instead — and merges with `auto-smart`, the other label the
    /// same setting produces.
    func testAutoRequestsAreLabelledAuto() {
        let breakdown = SessionBreakdown.build(
            events: [
                event("a", 100, model: "default"),
                event("a", 50, model: "auto-smart"),
                event("a", 25, model: "composer-2.5-fast"),
            ],
            catalog: ["a": named("Alpha")]
        )
        XCTAssertEqual(breakdown.models.map(\.model), ["Auto", "composer-2.5-fast"])
        XCTAssertEqual(breakdown.models.first?.cents, 150, "the two Auto labels are one row")
    }

    /// A model Cursor *did* name stays as Cursor named it, Auto pick or not: the name is
    /// strictly more information than "Auto", and inventing a shorter one risks being wrong.
    func testAResolvedAutoPickKeepsItsName() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 100, model: "Cursor Grok 4.5 (Auto Balanced)")],
            catalog: ["a": named("Alpha")]
        )
        XCTAssertEqual(breakdown.models.map(\.model), ["Cursor Grok 4.5 (Auto Balanced)"])
    }

    func testCycleModelListOmitsEventsWithNoModel() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 100, model: "sonnet"), event("a", 40, model: nil)],
            catalog: ["a": named("Alpha")]
        )
        XCTAssertEqual(breakdown.models, [ModelSpend(model: "sonnet", cents: 100)])
        XCTAssertEqual(breakdown.totalCents, 140, accuracy: 0.001, "the total still counts it")
    }

    // MARK: - Cloud agents

    /// A cloud agent runs on Cursor's servers, so its chat may never reach this Mac and
    /// cannot be named. Without this it would vanish into "Unnamed sessions" — the money
    /// visible but its origin not — which is the one thing a cost view shouldn't do.
    func testUnnameableCloudSpendIsSeparatedFromMerelyUnnamed() {
        let breakdown = SessionBreakdown.build(
            events: [
                event("known", 100),
                event("ghost", 40),                 // ran here, but no local record
                event("robot", 60, cloud: true),    // ran in the cloud
            ],
            catalog: ["known": named("Known")]
        )
        XCTAssertEqual(breakdown.cloudCents, 60, accuracy: 0.001)
        XCTAssertEqual(breakdown.cloudCount, 1)
        XCTAssertEqual(breakdown.unnamedCents, 40, accuracy: 0.001, "cloud spend is not counted twice")
        XCTAssertEqual(breakdown.unnamedCount, 1)
    }

    /// Cloud chats may well sync down, in which case they get a name like any other. The
    /// row still has to say where the work ran, so the flag rides on the node too.
    func testANamedSessionRunEntirelyInTheCloudIsMarked() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 100, cloud: true), event("a", 50, cloud: true)],
            catalog: ["a": named("Nightly refactor")]
        )
        XCTAssertEqual(breakdown.ranked.map(\.name), ["Nightly refactor"])
        XCTAssertTrue(breakdown.ranked[0].isCloud)
        XCTAssertEqual(breakdown.cloudCents, 0, "a named session is shown by name, not in the bucket")
    }

    /// Picking a cloud chat up locally and carrying on in it is a session that ran in both
    /// places. Calling that "cloud" would overstate what we know, so it stays unmarked.
    func testASessionRunInBothPlacesIsNotMarkedCloud() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 100, cloud: true), event("a", 50)],
            catalog: ["a": named("Started remote, finished here")]
        )
        XCTAssertFalse(breakdown.ranked[0].isCloud)
    }

    /// A parent billed nothing itself is cloud only if everything beneath it was.
    func testAParentIsCloudOnlyWhenItsWholeSubtreeIs() {
        let allCloud = SessionBreakdown.build(
            events: [event("kid", 50, cloud: true)],
            catalog: ["top": named("Top"), "kid": named("Kid", parent: "top")]
        )
        XCTAssertTrue(allCloud.ranked[0].isCloud)

        let mixed = SessionBreakdown.build(
            events: [event("kid", 50, cloud: true), event("kid2", 50)],
            catalog: [
                "top": named("Top"),
                "kid": named("Kid", parent: "top"), "kid2": named("Kid2", parent: "top"),
            ]
        )
        XCTAssertFalse(mixed.ranked[0].isCloud)
    }

    /// The invariant the whole list rests on: whatever is drawn must add up to the cycle.
    /// A cloud row is drawn separately, so the "show more" remainder has to exclude it.
    func testTheColumnStillAddsUpWithACloudRow() {
        let breakdown = SessionBreakdown.build(
            events: [
                event("a", 900), event("b", 500), event("c", 300),
                event("ghost", 111), event("robot", 222, cloud: true),
            ],
            catalog: ["a": named("A"), "b": named("B"), "c": named("C")]
        )
        let display = breakdown.display(limit: 2)
        let drawn = display.rows.reduce(0) { $0 + Format.displayedCents($1.rolledCents) }
            + Format.displayedCents(breakdown.cloudCents)
            + display.hiddenCents
        XCTAssertEqual(drawn, Format.displayedCents(breakdown.totalCents))
        XCTAssertEqual(display.hiddenCount, 2, "the cloud row is not also counted as hidden")
    }

    // MARK: - Subagent truncation

    func testShowsOnlyTheTopSubagentsAndCountsTheRest() {
        // The real shape that motivated this: one chat with fifteen subagents.
        let kids = (1...15).map { event("kid\($0)", Double($0) * 10) }
        var catalog: [String: SessionRecord] = ["root": named("Root")]
        for index in 1...15 { catalog["kid\(index)"] = named("Kid \(index)", parent: "root") }

        let breakdown = SessionBreakdown.build(events: [event("root", 5)] + kids, catalog: catalog)
        let display = breakdown.ranked[0].childDisplay(limit: 3)

        XCTAssertEqual(display.rows.map(\.id), ["kid15", "kid14", "kid13"], "priciest first")
        XCTAssertEqual(display.hiddenCount, 12)
        // 10+20+…+120, the twelve cheapest.
        XCTAssertEqual(display.hiddenCents, 780, accuracy: 0.001)
        XCTAssertTrue(display.hasMore)
    }

    func testNoSubagentRemainderWhenTheyAllFit() {
        let breakdown = SessionBreakdown.build(
            events: [event("root", 5), event("kid", 10)],
            catalog: ["root": named("Root"), "kid": named("Kid", parent: "root")]
        )
        let display = breakdown.ranked[0].childDisplay(limit: 3)
        XCTAssertEqual(display.rows.count, 1)
        XCTAssertFalse(display.hasMore)
    }

    func testLeafSessionHasNothingToExpand() {
        let breakdown = SessionBreakdown.build(events: [event("a", 50)], catalog: ["a": named("Alpha")])
        XCTAssertFalse(breakdown.ranked[0].childDisplay(limit: 3).hasMore)
        XCTAssertTrue(breakdown.ranked[0].childDisplay(limit: 3).rows.isEmpty)
    }

    // MARK: - Display truncation

    /// The property that failed twice on paper: the column the user reads must add up to
    /// the cycle total, which means the remainder is derived from *rounded* rows.
    func testRemainderMakesTheDisplayedColumnSumToTheTotal() {
        // Real cycle figures, whose raw cents do not land on exact pennies.
        let breakdown = SessionBreakdown.build(
            events: [
                event("a", 1_363.7), event("b", 301.4), event("c", 52.2),
                event("d", 17.1), event("e", 12.3), event("f", 7.2), event("g", 4.6),
                event("ghost", 592.9),
            ],
            catalog: [
                "a": named("A"), "b": named("B"), "c": named("C"),
                "d": named("D"), "e": named("E"), "f": named("F"), "g": named("G"),
            ]
        )
        let display = breakdown.display(limit: 5)
        XCTAssertEqual(display.rows.count, 5)

        let shown = display.rows.reduce(0) { $0 + Format.displayedCents($1.rolledCents) }
        XCTAssertEqual(
            shown + display.hiddenCents, Format.displayedCents(breakdown.totalCents),
            accuracy: 0.001, "displayed rows plus the remainder must equal the displayed total"
        )
    }

    func testRemainderCountsEveryHiddenRootIncludingUnnameableOnes() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 100), event("b", 50), event("c", 10), event("ghost", 5)],
            catalog: ["a": named("A"), "b": named("B"), "c": named("C")]
        )
        let display = breakdown.display(limit: 2)
        XCTAssertEqual(display.rows.map(\.id), ["a", "b"])
        XCTAssertEqual(display.hiddenCount, 2, "one ranked-out root plus one un-nameable root")
        XCTAssertEqual(display.hiddenCents, 15, accuracy: 0.001)
    }

    func testNoRemainderWhenEverythingFits() {
        let breakdown = SessionBreakdown.build(
            events: [event("a", 100), event("b", 50)],
            catalog: ["a": named("A"), "b": named("B")]
        )
        let display = breakdown.display(limit: 5)
        XCTAssertEqual(display.rows.count, 2)
        XCTAssertEqual(display.hiddenCount, 0)
        XCTAssertFalse(display.hasMore)
    }
}
