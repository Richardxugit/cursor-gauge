import XCTest
@testable import CursorGaugeCore

final class UsageMetricsTests: XCTestCase {
    // Real cycle bounds observed on the account: 2026-08-01 → 2026-09-01.
    private let cycleStart = Date(timeIntervalSince1970: 1_785_542_400)
    private let cycleEnd = Date(timeIntervalSince1970: 1_788_220_800)

    private func snapshot(
        settled: Double = 0, live: Double = 0, limit: Double? = 200,
        today: Double = 0, lastActivity: Date? = nil, capturedAt: Date? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            settledSpendCents: settled, liveSpendCents: live, limitDollars: limit,
            cycleStart: cycleStart, cycleEnd: cycleEnd, todayCents: today,
            models: [], lastActivity: lastActivity, capturedAt: capturedAt ?? cycleStart
        )
    }

    private func day(_ n: Double) -> Date { cycleStart.addingTimeInterval(n * 86_400) }

    // MARK: - Headline number

    func testUsesLargerOfSettledAndLiveSpend() {
        // Observed live: settled lagged at 251 cents while the aggregation read 308.8.
        let metrics = UsageMetrics(snapshot: snapshot(settled: 251, live: 308.8), now: day(1.5))
        XCTAssertEqual(metrics.spentCents, 308.8, accuracy: 0.001)
    }

    func testFallsBackToSettledWhenLiveIsBehind() {
        let metrics = UsageMetrics(snapshot: snapshot(settled: 400, live: 100), now: day(1.5))
        XCTAssertEqual(metrics.spentCents, 400, accuracy: 0.001)
    }

    // MARK: - Fraction

    func testFractionIsSpendOverLimit() {
        // $50 of $200 = 25%
        let metrics = UsageMetrics(snapshot: snapshot(settled: 5_000), now: day(10))
        XCTAssertEqual(metrics.fraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(metrics.rawFraction ?? -1, 0.25, accuracy: 0.0001)
    }

    func testFractionIsClampedForDrawingButRawIsNot() {
        // $224 of $200 = 112%
        let metrics = UsageMetrics(snapshot: snapshot(settled: 22_400), now: day(30))
        XCTAssertEqual(metrics.fraction ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.rawFraction ?? -1, 1.12, accuracy: 0.0001)
    }

    func testNoLimitYieldsNoFractionAndStaysNormal() {
        let metrics = UsageMetrics(snapshot: snapshot(settled: 90_000, limit: nil), now: day(10))
        XCTAssertNil(metrics.fraction)
        XCTAssertNil(metrics.rawFraction)
        XCTAssertEqual(metrics.level, .normal)
        XCTAssertFalse(metrics.isAheadOfPace)
    }

    func testZeroLimitIsTreatedAsNoLimitRatherThanDividingByZero() {
        let metrics = UsageMetrics(snapshot: snapshot(settled: 100, limit: 0), now: day(10))
        XCTAssertNil(metrics.fraction)
        XCTAssertEqual(metrics.level, .normal)
    }

    // MARK: - Threshold boundaries

    func testExactlyAtWarningThresholdIsWarning() {
        // 60% of $200 = $120
        let metrics = UsageMetrics(snapshot: snapshot(settled: 12_000), now: day(25))
        XCTAssertEqual(metrics.level, .warning)
    }

    func testJustBelowWarningThresholdIsNormal() {
        let metrics = UsageMetrics(snapshot: snapshot(settled: 11_999), now: day(25))
        XCTAssertEqual(metrics.level, .normal)
    }

    func testExactlyAtCriticalThresholdIsCritical() {
        // 85% of $200 = $170
        let metrics = UsageMetrics(snapshot: snapshot(settled: 17_000), now: day(28))
        XCTAssertEqual(metrics.level, .critical)
    }

    func testJustBelowCriticalThresholdIsWarning() {
        let metrics = UsageMetrics(snapshot: snapshot(settled: 16_999), now: day(28))
        XCTAssertEqual(metrics.level, .warning)
    }

    // MARK: - Pace

    func testSpendingFasterThanTheCalendarTripsPaceWarning() {
        // Day 10 of 31 = 32% elapsed, but 50% of budget spent.
        let metrics = UsageMetrics(snapshot: snapshot(settled: 10_000), now: day(10))
        XCTAssertTrue(metrics.isAheadOfPace)
        XCTAssertEqual(metrics.level, .warning)
    }

    func testSpendingInLineWithTheCalendarStaysNormal() {
        // Day 10 of 31 ≈ 32% elapsed, 32% spent.
        let metrics = UsageMetrics(snapshot: snapshot(settled: 6_450), now: day(10))
        XCTAssertFalse(metrics.isAheadOfPace)
        XCTAssertEqual(metrics.level, .normal)
    }

    func testPaceWarningCanBeDisabled() {
        var thresholds = GaugeThresholds.default
        thresholds.paceModeEnabled = false
        let metrics = UsageMetrics(snapshot: snapshot(settled: 10_000), thresholds: thresholds, now: day(10))
        XCTAssertTrue(metrics.isAheadOfPace)     // still reported
        XCTAssertEqual(metrics.level, .normal)   // but doesn't colour the ring
    }

    func testPaceDoesNotTripDuringTheFirstDay() {
        // 1.5% spent at 12h elapsed is way ahead of pace proportionally, but far too
        // early to mean anything.
        let metrics = UsageMetrics(snapshot: snapshot(settled: 309), now: day(0.5))
        XCTAssertEqual(metrics.level, .normal)
    }

    // MARK: - Burn rate and projection

    func testBurnRateIsSpendPerElapsedDay() {
        let metrics = UsageMetrics(snapshot: snapshot(settled: 1_000), now: day(4))
        XCTAssertEqual(metrics.burnRateCentsPerDay, 250, accuracy: 0.001)
    }

    func testProjectionExtrapolatesToEndOfCycle() {
        // $10 spent over 4 of 31 days → ~$77.50 projected.
        let metrics = UsageMetrics(snapshot: snapshot(settled: 1_000), now: day(4))
        XCTAssertEqual(metrics.projectedCents ?? -1, 1_000 / (4.0 / 31.0), accuracy: 1)
    }

    func testProjectionIsSuppressedInTheFirstDay() {
        let metrics = UsageMetrics(snapshot: snapshot(settled: 309), now: day(0.9))
        XCTAssertNil(metrics.projectedCents)
    }

    func testProjectionAppearsOnceADayHasElapsed() {
        let metrics = UsageMetrics(snapshot: snapshot(settled: 309), now: day(1.0))
        XCTAssertNotNil(metrics.projectedCents)
    }

    // MARK: - Cycle rollover

    func testFreshCycleResetsElapsedFractionToZero() {
        let metrics = UsageMetrics(snapshot: snapshot(settled: 0), now: cycleStart)
        XCTAssertEqual(metrics.cycleElapsedFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(metrics.burnRateCentsPerDay, 0)
        XCTAssertNil(metrics.projectedCents)
    }

    func testClockPastCycleEndClampsElapsedFraction() {
        // A stale cycleEnd shouldn't push elapsed above 100% and distort projections.
        let metrics = UsageMetrics(snapshot: snapshot(settled: 5_000), now: day(45))
        XCTAssertEqual(metrics.cycleElapsedFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.projectedCents ?? -1, 5_000, accuracy: 0.001)
    }

    func testClockBeforeCycleStartDoesNotProduceNegatives() {
        let metrics = UsageMetrics(snapshot: snapshot(settled: 100), now: cycleStart.addingTimeInterval(-3_600))
        XCTAssertEqual(metrics.cycleElapsedFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(metrics.burnRateCentsPerDay, 0)
        XCTAssertNil(metrics.projectedCents)
    }
}

final class FormatTests: XCTestCase {
    func testMoneyUsesCentsBelowOneHundredDollars() {
        XCTAssertEqual(Format.money(cents: 308.8), "$3.09")
        XCTAssertEqual(Format.money(cents: 0), "$0.00")
        XCTAssertEqual(Format.money(cents: 12_345), "$123")
    }

    func testPercentGainsAPlaceBelowTen() {
        XCTAssertEqual(Format.percent(0.0154), "1.5%")
        XCTAssertEqual(Format.percent(0.25), "25%")
    }

    func testTokensAbbreviate() {
        XCTAssertEqual(Format.tokens(319_174), "319K")
        XCTAssertEqual(Format.tokens(3_732_298), "3.7M")
        XCTAssertEqual(Format.tokens(842), "842")
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_785_658_392)
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-5), now: now), "just now")
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-120), now: now), "2 min ago")
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-7_200), now: now), "2h ago")
        XCTAssertEqual(Format.relative(now.addingTimeInterval(-172_800), now: now), "2d ago")
    }
}
