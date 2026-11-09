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

    static let twoTeams = """
    {"teams":[
      {"name":"bugbot","id":28605405,"role":"TEAM_ROLE_MEMBER","isEnterprise":true},
      {"name":"tech-digital","id":27362705,"role":"TEAM_ROLE_MEMBER","isEnterprise":true}
    ]}
    """

    static let bugbotSpend = """
    {"teamMemberSpend":[{"userId":307093031,"overallSpendCents":0,
      "monthlyLimitDollars":200,"effectivePerUserLimitDollars":200}],
     "subscriptionCycleStart":"1785542400000","nextCycleStart":"1788220800000"}
    """

    static let techDigitalSpend = """
    {"teamMemberSpend":[{"userId":307093031,"overallSpendCents":4578,
      "monthlyLimitDollars":200,"effectivePerUserLimitDollars":200}],
     "subscriptionCycleStart":"1785542400000","nextCycleStart":"1788220800000"}
    """
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
    private var failNextEvent = false
    private var recorded: [URLRequest] = []
    private var teamsBody: String?
    private var spendBodies: [Int: String] = [:]

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

    func teamIDs(forPath path: String) -> [Int] {
        requests.compactMap { request in
            guard request.url?.path == path,
                  let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body),
                  let object = json as? [String: Any]
            else { return nil }
            return object["teamId"] as? Int
        }
    }

    func useTwoTeams() {
        lock.withLock {
            teamsBody = Route.twoTeams
            spendBodies = [
                28605405: Route.bugbotSpend,
                27362705: Route.techDigitalSpend,
            ]
        }
    }

    func stallNextEventRequest() {
        lock.lock()
        stallNextEvent = true
        lock.unlock()
    }

    func gateNextEventRequest(failing: Bool = false) -> EventGate {
        let gate = EventGate()
        lock.withLock {
            nextEventGate = gate
            if failing { failNextEvent = true }
        }
        return gate
    }

    func failNextEventRequest() {
        lock.withLock { failNextEvent = true }
    }

    func setTeamsBody(_ body: String) {
        lock.withLock { teamsBody = body }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let (shouldStall, gate, shouldFail, teamsBody, spendBodies) = lock.withLock {
            recorded.append(request)
            let shouldStall = _stalling || (path == Self.eventsPath && stallNextEvent)
            let gate = path == Self.eventsPath ? nextEventGate : nil
            let shouldFail = path == Self.eventsPath && failNextEvent
            if path == Self.eventsPath {
                stallNextEvent = false
                nextEventGate = nil
                failNextEvent = false
            }
            return (shouldStall, gate, shouldFail, teamsBody, spendBodies)
        }

        await gate?.wait()
        if shouldStall {
            // Far longer than any deadline under test. Only cancellation should end this
            // — if the store ever waits it out, the bug is still there.
            try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        }
        if shouldFail { throw URLError(.networkConnectionLost) }
        var body = Route.all[path] ?? "{}"
        if path == "/api/dashboard/teams", let teamsBody {
            body = teamsBody
        }
        if path == "/api/dashboard/get-team-spend",
           let data = request.httpBody,
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let teamID = object["teamId"] as? Int,
           let spendBody = spendBodies[teamID] {
            body = spendBody
        }
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

    private func consecutiveFailures(of store: UsageStore) -> Int? {
        Mirror(reflecting: store).children.first {
            $0.label == "consecutiveFailures" || $0.label == "_consecutiveFailures"
        }?.value as? Int
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

    func testAutoRefreshPicksMostUsageAndExposesTeamOptions() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        let store = makeStore(transport: transport, deadline: 1)

        let succeeded = await store.refresh()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 4578)
        XCTAssertEqual(store.snapshot?.limitDollars ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(store.teamOptions, [
            CursorAPI.TeamOption(id: 28605405, name: "bugbot"),
            CursorAPI.TeamOption(id: 27362705, name: "tech-digital"),
        ])
    }

    func testPreferredTeamIsUsedForSnapshotAndUsageRequests() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        let store = makeStore(transport: transport, deadline: 1)
        store.preferredTeamID = 28605405

        let succeeded = await store.refresh()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 0)
        XCTAssertEqual(store.snapshot?.limitDollars ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(
            transport.teamIDs(forPath: "/api/dashboard/get-aggregated-usage-events"),
            [28605405, 28605405]
        )
        XCTAssertEqual(
            transport.teamIDs(forPath: "/api/dashboard/get-filtered-usage-events"),
            [28605405]
        )
    }

    func testSelectTeamClearsReadingWithoutRefreshingThenLoadsBugbot() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        let store = makeStore(transport: transport, deadline: 1)
        let initial = await store.refresh()
        XCTAssertTrue(initial)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 4578)
        XCTAssertNotNil(store.metrics)
        XCTAssertNotNil(store.lastUpdated)
        let requestCount = transport.requests.count

        store.selectTeam(28605405)

        XCTAssertEqual(store.preferredTeamID, 28605405)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.metrics)
        XCTAssertNil(store.lastUpdated)
        XCTAssertEqual(store.status, .loading)
        XCTAssertEqual(transport.requests.count, requestCount, "selectTeam must not refresh itself")

        let succeeded = await store.refresh()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 0)
        XCTAssertEqual(store.snapshot?.limitDollars ?? -1, 200, accuracy: 0.001)
    }

    func testSelectTeamNilThenRefreshReturnsToMostUsage() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        let store = makeStore(transport: transport, deadline: 1)
        store.preferredTeamID = 28605405
        let preferred = await store.refresh()
        XCTAssertTrue(preferred)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 0)

        store.selectTeam(nil)
        let succeeded = await store.refresh()

        XCTAssertTrue(succeeded)
        XCTAssertNil(store.preferredTeamID)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 4578)
        XCTAssertEqual(store.snapshot?.limitDollars ?? -1, 200, accuracy: 0.001)
    }


    func testTeamSwitchDuringRefreshDiscardsOldSnapshotAndLoadsNewTeam() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        let store = makeStore(transport: transport, deadline: 1)
        let originalTeamOptions = store.teamOptions
        let oldTeamGate = transport.gateNextEventRequest()
        async let refreshed = store.refresh()
        await oldTeamGate.waitUntilStarted()

        store.selectTeam(28605405)
        let newTeamGate = transport.gateNextEventRequest()
        oldTeamGate.open()
        await newTeamGate.waitUntilStarted()

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.status, .loading)
        XCTAssertEqual(store.teamOptions, originalTeamOptions)
        XCTAssertTrue(store.isRefreshing)

        newTeamGate.open()
        let succeeded = await refreshed

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 0)
        XCTAssertEqual(store.snapshot?.limitDollars ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(
            transport.teamIDs(forPath: "/api/dashboard/get-aggregated-usage-events").last,
            28605405
        )
        XCTAssertEqual(
            transport.teamIDs(forPath: "/api/dashboard/get-filtered-usage-events").last,
            28605405
        )
    }

    func testTeamSwitchDuringRefreshDiscardsOldFailureAndLoadsNewTeam() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        let store = makeStore(transport: transport, deadline: 1)
        let originalTeamOptions = store.teamOptions
        let oldTeamGate = transport.gateNextEventRequest(failing: true)
        async let refreshed = store.refresh()
        await oldTeamGate.waitUntilStarted()

        store.selectTeam(28605405)
        let newTeamGate = transport.gateNextEventRequest()
        oldTeamGate.open()
        await newTeamGate.waitUntilStarted()

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.status, .loading)
        XCTAssertEqual(store.teamOptions, originalTeamOptions)
        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(consecutiveFailures(of: store), 0)

        newTeamGate.open()
        let succeeded = await refreshed

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 0)
        XCTAssertEqual(store.snapshot?.limitDollars ?? -1, 200, accuracy: 0.001)
    }

    func testDirectTeamPreferenceWriteDuringRefreshDiscardsOldSnapshotAndLoadsNewTeam() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        let store = makeStore(transport: transport, deadline: 1)
        let oldTeamGate = transport.gateNextEventRequest()
        async let refreshed = store.refresh()
        await oldTeamGate.waitUntilStarted()

        store.preferredTeamID = 28605405
        oldTeamGate.open()
        let succeeded = await refreshed

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 0)
        XCTAssertEqual(store.snapshot?.limitDollars ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(
            transport.teamIDs(forPath: "/api/dashboard/get-aggregated-usage-events").last,
            28605405
        )
        XCTAssertEqual(
            transport.teamIDs(forPath: "/api/dashboard/get-filtered-usage-events").last,
            28605405
        )
    }

    func testSupersededTimeoutDoesNotFailNewTeamRefresh() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        transport.stallNextEventRequest()
        let store = makeStore(transport: transport, deadline: 1)
        let originalTeamOptions = store.teamOptions
        let oldTeamGate = transport.gateNextEventRequest()
        async let refreshed = store.refresh()
        await oldTeamGate.waitUntilStarted()

        store.selectTeam(28605405)
        let newTeamGate = transport.gateNextEventRequest()
        oldTeamGate.open()
        await newTeamGate.waitUntilStarted()

        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.status, .loading)
        XCTAssertEqual(store.teamOptions, originalTeamOptions)
        XCTAssertTrue(store.isRefreshing)

        newTeamGate.open()
        let succeeded = await refreshed

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 0)
        XCTAssertEqual(consecutiveFailures(of: store), 0)
    }

    func testRapidDoubleTeamSwitchPublishesOnlyFinalSelection() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        let store = makeStore(transport: transport, deadline: 1)
        let originalTeamOptions = store.teamOptions
        let oldTeamGate = transport.gateNextEventRequest()
        async let refreshed = store.refresh()
        await oldTeamGate.waitUntilStarted()

        store.selectTeam(28605405)
        store.selectTeam(nil)
        let finalSelectionGate = transport.gateNextEventRequest()
        oldTeamGate.open()
        await finalSelectionGate.waitUntilStarted()

        XCTAssertNil(store.preferredTeamID)
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.status, .loading)
        XCTAssertEqual(store.teamOptions, originalTeamOptions)
        XCTAssertTrue(store.isRefreshing)

        finalSelectionGate.open()
        let succeeded = await refreshed

        XCTAssertTrue(succeeded)
        XCTAssertNil(store.preferredTeamID)
        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.snapshot?.settledSpendCents, 4578)
        XCTAssertEqual(store.snapshot?.limitDollars ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(
            transport.teamIDs(forPath: "/api/dashboard/get-filtered-usage-events"),
            [27362705, 27362705]
        )
    }

    func testTeamOptionsAreMainActorSnapshotsOfSuccessfulRefreshes() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        let store = makeStore(transport: transport, deadline: 1)
        XCTAssertTrue(store.teamOptions.isEmpty)

        let initial = await store.refresh()

        XCTAssertTrue(initial)
        XCTAssertEqual(store.teamOptions, [
            CursorAPI.TeamOption(id: 28605405, name: "bugbot"),
            CursorAPI.TeamOption(id: 27362705, name: "tech-digital"),
        ])

        transport.setTeamsBody("""
        {"teams":[
          {"name":"tech-digital-latest","id":27362705,"role":"TEAM_ROLE_MEMBER","isEnterprise":true},
          {"name":"bugbot-latest","id":28605405,"role":"TEAM_ROLE_MEMBER","isEnterprise":true}
        ]}
        """)
        store.selectTeam(28605405)
        let latest = await store.refresh()
        let latestOptions = [
            CursorAPI.TeamOption(id: 27362705, name: "tech-digital-latest"),
            CursorAPI.TeamOption(id: 28605405, name: "bugbot-latest"),
        ]

        XCTAssertTrue(latest)
        XCTAssertEqual(store.teamOptions, latestOptions)

        transport.setTeamsBody("""
        {"teams":[
          {"name":"unpublished","id":27362705,"role":"TEAM_ROLE_MEMBER","isEnterprise":true}
        ]}
        """)
        transport.failNextEventRequest()
        store.selectTeam(27362705)
        let failed = await store.refresh()

        XCTAssertFalse(failed)
        XCTAssertEqual(store.teamOptions, latestOptions)
    }

}
