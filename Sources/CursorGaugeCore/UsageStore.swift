import AppKit
import Foundation
import Observation

/// How often to poll, based on whether the user is plausibly spending money right now.
public enum RefreshCadence: TimeInterval, CaseIterable {
    /// Cursor is open and was frontmost recently — spend can move minute to minute.
    case active = 60
    /// Cursor is open but idle.
    case idle = 300
    /// Cursor isn't running; nothing can change except by another machine.
    case dormant = 1_800

    public var label: String {
        switch self {
        case .active: return "every minute"
        case .idle: return "every 5 minutes"
        case .dormant: return "every 30 minutes"
        }
    }
}

public protocol CursorActivityObserving {
    var isCursorRunning: Bool { get }
    var secondsSinceCursorFrontmost: TimeInterval? { get }
}

public struct WorkspaceActivityObserver: CursorActivityObserving {
    public static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    /// Set by the app whenever Cursor becomes the active application.
    public static var lastFrontmostAt: Date?

    public init() {}

    public var isCursorRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.cursorBundleID
        }
    }

    public var secondsSinceCursorFrontmost: TimeInterval? {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.cursorBundleID { return 0 }
        return Self.lastFrontmostAt.map { Date().timeIntervalSince($0) }
    }
}

@MainActor
@Observable
public final class UsageStore {
    public enum Status: Equatable {
        case loading
        case ready
        /// A reading failed. Any previous snapshot stays visible but is marked stale.
        case failed(String)
    }

    public private(set) var status: Status = .loading
    public var preferredTeamID: Int? {
        didSet { selectionGeneration += 1 }
    }
    public private(set) var teamOptions: [CursorAPI.TeamOption] = []
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var metrics: UsageMetrics?
    public private(set) var lastUpdated: Date?
    public private(set) var cadence: RefreshCadence = .idle
    public private(set) var isRefreshing = false

    public var thresholds: GaugeThresholds {
        didSet { recomputeMetrics() }
    }

    private let api: CursorAPI
    private let credentials: CredentialsProviding
    private let activity: CursorActivityObserving
    private let clock: () -> Date
    private let deadline: TimeInterval
    private var timer: Timer?
    /// The interval the live timer was armed with; internal for re-arm tests.
    private(set) var armedInterval: TimeInterval?
    private var consecutiveFailures = 0
    private var menuIsOpen = false
    private var needsDetailedRefresh = false
    private var selectionGeneration = 0
    /// The merged event set backing the published full snapshot, per selection.
    private var mergedEvents: [SessionEvent] = []
    /// The cycle the merge was built against, so a rollover is spotted after the fetch.
    private var mergedCycleStart: Date?
    /// How many full refreshes were published; drives the periodic reconciliation.
    private var fullPublishCount = 0
    /// Set when a feed came back truncated, so the next fetch re-reads the whole window.
    private var forceNextWholeWindow = false
    /// Every Nth published full refresh re-reads the entire window from scratch.
    private static let reconciliationEvery = 10
    /// Consecutive published refreshes whose activity signature did not change.
    private var quietStreak = 0
    /// The signature of the last published snapshot, for quiet detection.
    private var lastSignature: ActivitySignature?
    /// The poll interval in effect at the last publish; staleness is measured
    /// against it so a quiet-backed-off reading is not flagged between polls.
    private var lastPublishInterval = RefreshCadence.idle.rawValue

    public init(
        credentials: CredentialsProviding,
        api: CursorAPI? = nil,
        activity: CursorActivityObserving = WorkspaceActivityObserver(),
        thresholds: GaugeThresholds = .default,
        deadline: TimeInterval = 45,
        clock: @escaping () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.api = api ?? CursorAPI(credentials: credentials, clock: clock)
        self.activity = activity
        self.thresholds = thresholds
        self.deadline = deadline
        self.clock = clock
    }

    // MARK: - Polling

    public func start() {
        Task { await refresh() }
        scheduleNext()

        // A machine that slept through a poll should catch up immediately, not wait
        // out the remainder of an interval that elapsed while it was off.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == WorkspaceActivityObserver.cursorBundleID {
                WorkspaceActivityObserver.lastFrontmostAt = Date()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        armedInterval = nil
    }

    private func scheduleNext() {
        timer?.invalidate()
        let interval = currentInterval()
        armedInterval = interval
        // Repeating, deliberately. A one-shot timer re-armed from inside its own fire
        // handler makes the next poll conditional on this one finishing, so a single
        // reading that never returned left the app with no timer at all and no way back.
        // The clock now runs independently of whether any given reading succeeds.
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // refresh() re-arms at its end whenever the effective interval moved.
                await self.refresh()
            }
        }
    }

    /// Re-arms the live timer when the effective interval changed outside the
    /// timer's own fire handler — menu open/close, team switch, manual refresh.
    /// Without this, opening the menu could leave a quiet-backed-off timer
    /// armed for up to 30 minutes while the open menu should poll at base rate.
    private func rearmIfNeeded() {
        guard timer != nil, let armed = armedInterval else { return }
        if currentInterval() != armed { scheduleNext() }
    }

    func currentInterval() -> TimeInterval {
        let base: RefreshCadence
        if !activity.isCursorRunning {
            base = .dormant
        } else if let since = activity.secondsSinceCursorFrontmost, since < 300 {
            base = .active
        } else {
            base = .idle
        }
        cadence = base

        guard consecutiveFailures > 0 else {
            // Quiet backoff: repeated polls that change nothing stretch the
            // background interval. The open menu always keeps the base cadence,
            // dormant is already the slowest cadence, and the two backoffs never
            // compound (failures return above).
            guard !menuIsOpen, base != .dormant else { return base.rawValue }
            let exponent = max(0, min(quietStreak - 1, 3))
            return min(base.rawValue * pow(2, Double(exponent)), 1_800)
        }
        // Back off on repeated failure so a broken endpoint doesn't hammer cursor.com,
        // but never stall longer than 15 minutes or recovery feels dead.
        let backoff = base.rawValue * pow(2, Double(min(consecutiveFailures, 4)))
        return min(backoff, 900)
    }

    // MARK: - Fetching

    public func setMenuOpen(_ open: Bool) {
        menuIsOpen = open
        if open {
            needsDetailedRefresh = true
            quietStreak = 0
        }
        rearmIfNeeded()
    }

    public func selectTeam(_ id: Int?) {
        preferredTeamID = id
        snapshot = nil
        metrics = nil
        lastUpdated = nil
        status = .loading
        mergedEvents = []
        mergedCycleStart = nil
        fullPublishCount = 0
        forceNextWholeWindow = false
        quietStreak = 0
        lastSignature = nil
        rearmIfNeeded()
    }

    @discardableResult
    public func refresh() async -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        defer { isRefreshing = false }

        var succeeded = false
        var attemptWasSuperseded = false
        repeat {
            let generation = selectionGeneration
            let preferredTeamID = self.preferredTeamID
            let detail: CursorAPI.SnapshotDetail = menuIsOpen ? .full : .summary
            if detail == .full { needsDetailedRefresh = false }
            attemptWasSuperseded = false
            succeeded = false
            // A full read tops up from the newest merged event; a whole-window read is
            // forced on an empty base, after a truncated feed, and every Nth publish.
            let fetchedWholeWindow = detail == .full && shouldFetchWholeWindow()
            let eventsSince: Date? =
                detail == .full && !fetchedWholeWindow ? mergedEvents.map(\.timestamp).max() : nil
            do {
                let fresh = try await withDeadline(deadline) { [api] in
                    if detail == .full {
                        return try await api.fetchSnapshotForMerge(
                            detail: detail, preferredTeamID: preferredTeamID, eventsSince: eventsSince
                        )
                    }
                    return try await api.fetchSnapshot(
                        detail: detail, preferredTeamID: preferredTeamID, eventsSince: eventsSince
                    )
                }
                if selectionGeneration != generation {
                    attemptWasSuperseded = true
                } else {
                    // A summary that finishes after the menu opens must not erase visible details.
                    if detail == .full || !menuIsOpen {
                        var published = fresh
                        var prospectiveMergedEvents: [SessionEvent]?
                        if detail == .full {
                            let events = mergedFeed(from: fresh, fetchedWholeWindow: fetchedWholeWindow)
                            let resolved = await resolveForPublish(fresh, events: events)
                            published = resolved.snapshot
                            prospectiveMergedEvents = resolved.events
                        }
                        if selectionGeneration != generation {
                            // Resolution outlived the selection. Drop both the snapshot and
                            // its prospective merge base; the repeat loop reads the new team.
                            attemptWasSuperseded = true
                        } else {
                            if let events = prospectiveMergedEvents {
                                mergedEvents = events
                                mergedCycleStart = fresh.cycleStart
                                fullPublishCount += 1
                                forceNextWholeWindow = fresh.sessionsTruncated
                            }
                            snapshot = published
                            lastUpdated = fresh.capturedAt
                            status = .ready
                            consecutiveFailures = 0
                            teamOptions = api.teamOptions
                            recomputeMetrics()
                            updateQuietState(with: published)
                        }
                    }
                    if !attemptWasSuperseded { succeeded = true }
                }
            } catch {
                if selectionGeneration != generation {
                    attemptWasSuperseded = true
                } else {
                    consecutiveFailures += 1
                    if let apiError = error as? APIError, apiError.isRecoverableByReauth {
                        // Token may have rotated under us; drop the cached identity too, since a
                        // re-auth can mean a different account.
                        credentials.invalidate()
                        api.forgetIdentity()
                    }
                    status = .failed(describe(error))
                }
            }
        } while attemptWasSuperseded || (menuIsOpen && needsDetailedRefresh)
        rearmIfNeeded()
        return succeeded
    }

    /// Whether the next full feed should cover the whole window rather than a top-up.
    ///
    /// The merge base is only as good as its inputs: an empty base has nothing to extend,
    /// a truncated feed is missing rows, and a periodic rebuild bounds how long any merge
    /// mistake can live.
    private func shouldFetchWholeWindow() -> Bool {
        mergedEvents.isEmpty
            || forceNextWholeWindow
            || (fullPublishCount + 1) % Self.reconciliationEvery == 0
    }

    /// Folds a fetched feed into the merged set. Replaced outright on a whole-window
    /// fetch, a cycle rollover, or a truncated feed — all make the previous set an
    /// unreliable base to merge onto.
    private func mergedFeed(from fresh: UsageSnapshot, fetchedWholeWindow: Bool) -> [SessionEvent] {
        if fetchedWholeWindow || mergedCycleStart != fresh.cycleStart || fresh.sessionsTruncated {
            return fresh.events
        }
        var byKey: [EventKey: SessionEvent] = [:]
        for event in mergedEvents { byKey[EventKey(event)] = event }
        for event in fresh.events { byKey[EventKey(event)] = event }
        return byKey.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Resolves names and rebuilds the presentable snapshot over a merged event set off
    /// the main actor. The merged events travel with the snapshot so publish can commit
    /// both only after confirming that the selection is still current.
    private func resolveForPublish(
        _ fresh: UsageSnapshot, events: [SessionEvent]
    ) async -> (snapshot: UsageSnapshot, events: [SessionEvent]) {
        let api = api
        return await Task.detached {
            let sessions = SessionBreakdown.build(
                events: events,
                catalog: api.sessionRecords(for: Array(Set(events.compactMap(\.conversationID))))
            )
            let snapshot = UsageSnapshot(
                settledSpendCents: fresh.settledSpendCents,
                liveSpendCents: fresh.liveSpendCents,
                limitDollars: fresh.limitDollars,
                cycleStart: fresh.cycleStart,
                cycleEnd: fresh.cycleEnd,
                todayCents: fresh.todayCents,
                models: fresh.models,
                lastActivity: events.map(\.timestamp).max(),
                capturedAt: fresh.capturedAt,
                sessions: sessions,
                sessionsTruncated: fresh.sessionsTruncated,
                events: events
            )
            return (snapshot, events)
        }.value
    }

    /// One billed request's identity for merge deduplication.
    private struct EventKey: Hashable {
        let conversationID: String?
        let timestamp: Date

        init(_ event: SessionEvent) {
            conversationID = event.conversationID
            timestamp = event.timestamp
        }
    }

    /// Folds a published snapshot into the quiet-streak bookkeeping. An open
    /// menu counts as engagement: the streak never grows while it is open.
    private func updateQuietState(with published: UsageSnapshot) {
        let signature = ActivitySignature(published)
        if menuIsOpen {
            quietStreak = 0
        } else if signature == lastSignature {
            quietStreak = min(quietStreak + 1, 8)
        } else {
            quietStreak = 0
        }
        lastSignature = signature
        lastPublishInterval = currentInterval()
    }

    /// The user-visible activity fields; two snapshots with the same signature
    /// mean a poll taught us nothing.
    private struct ActivitySignature: Equatable {
        let settledSpendCents: Double
        let liveSpendCents: Double
        let todayCents: Double
        let lastActivity: Date?
        let eventsCount: Int

        init(_ snapshot: UsageSnapshot) {
            settledSpendCents = snapshot.settledSpendCents
            liveSpendCents = snapshot.liveSpendCents
            todayCents = snapshot.todayCents
            lastActivity = snapshot.lastActivity
            eventsCount = snapshot.events.count
        }
    }

    /// Runs `operation`, abandoning it after `seconds`.
    ///
    /// This is what stops `isRefreshing` latching: that guard makes every other way into
    /// the store — opening the menu, ⌘R, waking from sleep — a no-op while a reading is
    /// outstanding, so a reading that never finishes silently disables all of them.
    ///
    /// Cancelling the loser also tears down the underlying request, so a stalled socket
    /// is released rather than left open for the next poll to queue up behind.
    private func withDeadline<T>(
        _ seconds: TimeInterval,
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw APIError.timedOut
            }
            guard let first = try await group.next() else { throw APIError.timedOut }
            group.cancelAll()
            return first
        }
    }

    private func recomputeMetrics() {
        guard let snapshot else { return }
        metrics = UsageMetrics(snapshot: snapshot, thresholds: thresholds, now: clock())
    }

    private func describe(_ error: Error) -> String {
        if let tokenError = error as? TokenError { return tokenError.description }
        if let apiError = error as? APIError { return apiError.description }
        return error.localizedDescription
    }

    // MARK: - Derived presentation

    /// True once the visible reading is old enough that presenting it as current
    /// would be misleading.
    public var isStale: Bool {
        guard let lastUpdated else { return true }
        return clock().timeIntervalSince(lastUpdated) > lastPublishInterval * 2.5
    }

    public var menuBarImage: NSImage {
        guard let metrics else { return GaugeIcon.problemImage() }
        return GaugeIcon.image(fraction: metrics.fraction, level: metrics.level)
    }

    public var menuBarText: String? {
        guard let metrics else { return nil }
        return Format.money(cents: metrics.spentCents)
    }
}
