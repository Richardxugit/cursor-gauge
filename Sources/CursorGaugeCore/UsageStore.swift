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
    public var preferredTeamID: Int?
    public var teamOptions: [CursorAPI.TeamOption] { api.teamOptions }
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
    private var consecutiveFailures = 0
    private var menuIsOpen = false
    private var needsDetailedRefresh = false

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
    }

    private func scheduleNext() {
        timer?.invalidate()
        let interval = currentInterval()
        // Repeating, deliberately. A one-shot timer re-armed from inside its own fire
        // handler makes the next poll conditional on this one finishing, so a single
        // reading that never returned left the app with no timer at all and no way back.
        // The clock now runs independently of whether any given reading succeeds.
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refresh()
                // Cursor may have quit or come to the front since this timer was armed.
                if self.currentInterval() != interval { self.scheduleNext() }
            }
        }
    }

    private func currentInterval() -> TimeInterval {
        let base: RefreshCadence
        if !activity.isCursorRunning {
            base = .dormant
        } else if let since = activity.secondsSinceCursorFrontmost, since < 300 {
            base = .active
        } else {
            base = .idle
        }
        cadence = base

        guard consecutiveFailures > 0 else { return base.rawValue }
        // Back off on repeated failure so a broken endpoint doesn't hammer cursor.com,
        // but never stall longer than 15 minutes or recovery feels dead.
        let backoff = base.rawValue * pow(2, Double(min(consecutiveFailures, 4)))
        return min(backoff, 900)
    }

    // MARK: - Fetching

    public func setMenuOpen(_ open: Bool) {
        menuIsOpen = open
        if open { needsDetailedRefresh = true }
    }

    public func selectTeam(_ id: Int?) {
        preferredTeamID = id
        snapshot = nil
        metrics = nil
        lastUpdated = nil
        status = .loading
    }

    @discardableResult
    public func refresh() async -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        defer { isRefreshing = false }

        var succeeded = false
        repeat {
            let detail: CursorAPI.SnapshotDetail = menuIsOpen ? .full : .summary
            if detail == .full { needsDetailedRefresh = false }
            succeeded = false
            do {
                let fresh = try await withDeadline(deadline) { [api] in
                    try await api.fetchSnapshot(detail: detail, preferredTeamID: self.preferredTeamID)
                }
                // A summary that finishes after the menu opens must not erase visible details.
                if detail == .full || !menuIsOpen {
                    snapshot = fresh
                    lastUpdated = fresh.capturedAt
                    status = .ready
                    consecutiveFailures = 0
                    recomputeMetrics()
                }
                succeeded = true
            } catch {
                consecutiveFailures += 1
                if let apiError = error as? APIError, apiError.isRecoverableByReauth {
                    // Token may have rotated under us; drop the cached identity too, since a
                    // re-auth can mean a different account.
                    credentials.invalidate()
                    api.forgetIdentity()
                }
                status = .failed(describe(error))
            }
        } while menuIsOpen && needsDetailedRefresh
        return succeeded
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
        return clock().timeIntervalSince(lastUpdated) > cadence.rawValue * 2.5
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
