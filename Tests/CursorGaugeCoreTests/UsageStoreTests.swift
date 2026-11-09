import XCTest
@testable import CursorGaugeCore

// MARK: - Doubles

private final class StubCredentials: CredentialsProviding {
    func load() throws -> CursorCredentials {
        CursorCredentials(
            accessToken: "TOKEN",
            userSub: "user_ABC",
            expiresAt: Date(timeIntervalSince1970: 1_790_839_766)
        )
    }
    func invalidate() {}
}

private final class StubNaming: SessionNaming {
    func records(for ids: [String]) -> [String: SessionRecord] {
        guard ids.contains("session-1") else { return [:] }
        return ["session-1": SessionRecord(name: "Session One", parentID: nil)]
    }
}

private struct StubActivity: CursorActivityObserving {
    var isCursorRunning = true
    var secondsSinceCursorFrontmost: TimeInterval? = 0
}

/// Enough of a healthy account for `fetchSnapshot` to complete.
private enum Route {
    static let all: [String: String] = [
        "/api/auth/me": """
        {"email":"someone@example.com","name":"Someone","sub":"user_ABC","id":307093031}
        """,
        "/api/dashboard/teams": """
        {"teams":[{"name":"tech-digital","id":27362705,"role":"TEAM_ROLE_MEMBER","isEnterprise":true}]}
        """,
        "/api/dashboard/get-team-spend": """
        {"teamMemberSpend":[{"userId":307093031,"overallSpendCents":4578,
          "monthlyLimitDollars":200,"effectivePerUserLimitDollars":200}],
         "subscriptionCycleStart":"1785542400000","nextCycleStart":"1788220800000"}
        """,
        "/api/dashboard/get-aggregated-usage-events": """
        {"aggregations":[],"totalCostCents":4578}
        """,
        "/api/dashboard/get-filtered-usage-events": """
        {"totalUsageEventsCount":1,"usageEventsDisplay":[
          {"timestamp":"1785658176745","model":"composer-2.5-fast","chargedCents":12.5,
           "conversationId":"session-1","isHeadless":false}]}
        """,
    ]
}

/// Holds one request until the test releases it, and lets the test wait for its arrival.
private final class EventGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let (resumeImmediately, notifyStarted) = lock.withLock {
                started = true
                let notifyStarted = startedWaiter
                startedWaiter = nil
                if isOpen { return (true, notifyStarted) }
                waiter = continuation
                return (false, notifyStarted)
            }
            notifyStarted?.resume()
            if resumeImmediately { continuation.resume() }
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if started { return true }
                startedWaiter = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func open() {
        let waiter = lock.withLock {
            isOpen = true
            let waiter = self.waiter
            self.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

/// Answers normally, or hangs indefinitely on demand.
///
/// The hang reproduces the failure that actually took the app down in the field: a
/// socket macOS still believed was open, on a VPN that had roamed underneath it, with
/// nothing ever arriving and so no gap between packets for a request timeout to catch.
private final class SwitchableTransport: Transport, @unchecked Sendable {
    private static let eventsPath = "/api/dashboard/get-filtered-usage-events"

    private let lock = NSLock()
    private var _stalling = false
    private var stallNextEvent = false
    private var nextEventGate: EventGate?
    private var recorded: [URLRequest] = []

    var stalling: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stalling }
        set { lock.lock(); _stalling = newValue; lock.unlock() }
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var eventPageSizes: [Int] {
        requests.compactMap { request in
            guard request.url?.path == Self.eventsPath,
                  let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body),
                  let object = json as? [String: Any]
            else { return nil }
            return object["pageSize"] as? Int
        }
    }

    func stallNextEventRequest() {
        lock.lock()
        stallNextEvent = true
        lock.unlock()
    }

    func gateNextEventRequest() -> EventGate {
        let gate = EventGate()
        lock.withLock { nextEventGate = gate }
        return gate
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let (shouldStall, gate) = lock.withLock {
            recorded.append(request)
            let shouldStall = _stalling || (path == Self.eventsPath && stallNextEvent)
            let gate = path == Self.eventsPath ? nextEventGate : nil
            if path == Self.eventsPath {
                stallNextEvent = false
                nextEventGate = nil
            }
            return (shouldStall, gate)
        }

        if shouldStall {
            // Far longer than any deadline under test. Only cancellation should end this
            // — if the store ever waits it out, the bug is still there.
            try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        }
        await gate?.wait()
        let body = Route.all[path] ?? "{}"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

// MARK: - Tests

@MainActor
final class UsageStoreTests: XCTestCase {
    private func makeStore(transport: Transport, deadline: TimeInterval) -> UsageStore {
        let credentials = StubCredentials()
        return UsageStore(
            credentials: credentials,
            api: CursorAPI(
                credentials: credentials,
                transport: transport,
                naming: StubNaming()
            ),
            activity: StubActivity(),
            deadline: deadline
        )
    }

    /// A reading that never arrives must be abandoned, not waited on forever.
    ///
    /// Without a ceiling that `await` never returns, so the poll loop — which re-arms
    /// itself only once a refresh has completed — is never rescheduled, and the app
    /// freezes permanently on whatever it last read.
    func testAStalledReadingGivesUpAtTheDeadline() async {
        let transport = SwitchableTransport()
        transport.stalling = true
        let store = makeStore(transport: transport, deadline: 0.3)

        let started = Date()
        let succeeded = await store.refresh()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(succeeded)
        XCTAssertLessThan(elapsed, 5, "refresh hung instead of honouring its deadline")
        guard case .failed = store.status else {
            return XCTFail("expected a failed status, got \(store.status)")
        }
    }

    /// The in-flight guard must not latch.
    ///
    /// `refresh()` returns early while another refresh is running. If a stalled refresh
    /// never returns, that guard stays shut forever and every other way into the store —
    /// opening the menu, ⌘R, waking from sleep — silently does nothing.
    func testTheStoreRecoversAfterAStall() async {
        let transport = SwitchableTransport()
        transport.stalling = true
        let store = makeStore(transport: transport, deadline: 0.3)

        let stalled = await store.refresh()
        XCTAssertFalse(stalled, "the stalled reading should have failed")

        transport.stalling = false
        let recovered = await store.refresh()
        XCTAssertTrue(recovered, "the store never recovered from the stall")
        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 4578)
    }

    func testBackgroundAndMenuRefreshesUseTheExpectedDetail() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 1)

        let background = await store.refresh()
        XCTAssertTrue(background)
        XCTAssertTrue(store.snapshot?.events.isEmpty == true)
        XCTAssertEqual(store.snapshot?.sessions, SessionBreakdown.empty)

        store.setMenuOpen(true)
        let opened = await store.refresh()
        XCTAssertTrue(opened)
        XCTAssertEqual(store.snapshot?.events.count, 1)
        XCTAssertEqual(store.snapshot?.sessions.ranked.map(\.id), ["session-1"])

        store.setMenuOpen(false)
        let closed = await store.refresh()
        XCTAssertTrue(closed)
        XCTAssertTrue(store.snapshot?.events.isEmpty == true)
        XCTAssertEqual(store.snapshot?.sessions, SessionBreakdown.empty)

        XCTAssertEqual(transport.eventPageSizes, [1, 500, 1])
    }

    func testOpeningDuringAStalledSummaryUpgradesToFullAfterTimeout() async {
        let transport = SwitchableTransport()
        transport.stallNextEventRequest()
        let store = makeStore(transport: transport, deadline: 0.3)

        async let refreshed = store.refresh()
        await Task.yield()
        store.setMenuOpen(true)

        let succeeded = await refreshed
        XCTAssertTrue(succeeded)
        XCTAssertEqual(transport.eventPageSizes, [1, 500])
        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.snapshot?.events.count, 1)
        XCTAssertEqual(store.snapshot?.sessions.ranked.map(\.id), ["session-1"])
    }

    func testRefreshesRemainFullWhileTheMenuIsOpen() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 1)
        store.setMenuOpen(true)

        let first = await store.refresh()
        let second = await store.refresh()

        XCTAssertTrue(first)
        XCTAssertTrue(second)

        XCTAssertEqual(transport.eventPageSizes, [500, 500])
        XCTAssertEqual(store.snapshot?.events.count, 1)
        XCTAssertEqual(store.snapshot?.sessions.ranked.map(\.id), ["session-1"])
    }

    func testLateSummaryDoesNotReplaceVisibleDetails() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 1)
        store.setMenuOpen(true)
        let initial = await store.refresh()
        XCTAssertTrue(initial)
        let detailedSnapshot = store.snapshot

        store.setMenuOpen(false)
        let summaryGate = transport.gateNextEventRequest()
        async let refreshed = store.refresh()
        await summaryGate.waitUntilStarted()

        store.setMenuOpen(true)
        let fullGate = transport.gateNextEventRequest()
        summaryGate.open()
        await fullGate.waitUntilStarted()

        XCTAssertEqual(store.snapshot, detailedSnapshot)
        XCTAssertEqual(store.snapshot?.events.count, 1)
        XCTAssertEqual(store.snapshot?.sessions.ranked.map(\.id), ["session-1"])

        fullGate.open()
        let succeeded = await refreshed
        XCTAssertTrue(succeeded)
        XCTAssertEqual(transport.eventPageSizes, [500, 1, 500])
        XCTAssertEqual(store.status, .ready)
    }
}
