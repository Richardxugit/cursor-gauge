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

    static let eventOne = """
    {"totalUsageEventsCount":1,"usageEventsDisplay":[
      {"timestamp":"1785658176745","model":"composer-2.5-fast","chargedCents":12.5,
       "conversationId":"session-1","isHeadless":false}]}
    """

    /// One event overlapping the previous window with a changed cost, plus a new one.
    static let updatedPlusNew = """
    {"totalUsageEventsCount":2,"usageEventsDisplay":[
      {"timestamp":"1785658176745","model":"composer-2.5-fast","chargedCents":99.9,
       "conversationId":"session-1","isHeadless":false},
      {"timestamp":"1785658476745","model":"composer-2.5-fast","chargedCents":5.0,
       "conversationId":"session-2","isHeadless":false}]}
    """

    static let eventTwo = """
    {"totalUsageEventsCount":1,"usageEventsDisplay":[
      {"timestamp":"1785658476745","model":"composer-2.5-fast","chargedCents":5.0,
       "conversationId":"session-2","isHeadless":false}]}
    """

    static let techDigitalNewCycleSpend = """
    {"teamMemberSpend":[{"userId":307093031,"overallSpendCents":5000,
      "monthlyLimitDollars":200,"effectivePerUserLimitDollars":200}],
     "subscriptionCycleStart":"1788220800000","nextCycleStart":"1790899200000"}
    """

    /// A dense feed: `count` rows with `total` reported, to exercise the page cap.
    static func eventsBody(count: Int, total: Int, baseTimestamp: Int64) -> String {
        let rows = (0..<count).map { index in
            """
            {"timestamp":"\(baseTimestamp + Int64(index))","model":"composer-2.5-fast","chargedCents":1.0,\
            "conversationId":"bulk-\(index % 7)","isHeadless":false}
            """
        }.joined(separator: ",")
        return "{\"totalUsageEventsCount\":\(total),\"usageEventsDisplay\":[\(rows)]}"
    }
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
    private var eventBodies: [String] = []

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

    /// The `startDate` of every recorded events request, in epoch milliseconds.
    var eventStartDates: [Int64] {
        requests.compactMap { request in
            guard request.url?.path == Self.eventsPath,
                  let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body),
                  let object = json as? [String: Any],
                  let start = object["startDate"] as? String
            else { return nil }
            return Int64(start)
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

    /// Serves the given bodies in order on the next events requests; defaults when empty.
    func setEventBodies(_ bodies: [String]) {
        lock.withLock { eventBodies = bodies }
    }

    func setSpendBody(_ teamID: Int, _ body: String) {
        lock.withLock { spendBodies[teamID] = body }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let (shouldStall, gate, shouldFail, teamsBody, spendBodies, eventBody) = lock.withLock {
            recorded.append(request)
            let shouldStall = _stalling || (path == Self.eventsPath && stallNextEvent)
            let gate = path == Self.eventsPath ? nextEventGate : nil
            let shouldFail = path == Self.eventsPath && failNextEvent
            var eventBody: String?
            if path == Self.eventsPath {
                stallNextEvent = false
                nextEventGate = nil
                failNextEvent = false
                eventBody = eventBodies.isEmpty ? nil : eventBodies.removeFirst()
            }
            return (shouldStall, gate, shouldFail, teamsBody, spendBodies, eventBody)
        }

        await gate?.wait()
        if shouldStall {
            // Far longer than any deadline under test. Only cancellation should end this
            // — if the store ever waits it out, the bug is still there.
            try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        }
        if shouldFail { throw URLError(.networkConnectionLost) }
        var body = Route.all[path] ?? "{}"
        if path == Self.eventsPath, let eventBody {
            body = eventBody
        }
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
    private func makeStore(
        transport: Transport,
        deadline: TimeInterval,
        activity: CursorActivityObserving = StubActivity(),
        clock: @escaping () -> Date = Date.init
    ) -> UsageStore {
        let credentials = StubCredentials()
        return UsageStore(
            credentials: credentials,
            api: CursorAPI(
                credentials: credentials,
                transport: transport,
                naming: StubNaming()
            ),
            activity: activity,
            deadline: deadline,
            clock: clock
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

    // MARK: - Incremental event feed

    func testFirstFullRefreshFetchesTheWholeWindowAndStoresItsEvents() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 5)

        store.setMenuOpen(true)
        let succeeded = await store.refresh()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(transport.eventStartDates, [1_785_542_400_000])
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-1"])
        XCTAssertEqual(store.snapshot?.events.first?.cents, 12.5)
    }

    func testTopUpFetchesTheOverlapWindowAndMergesUpdatesAndNewEvents() async {
        let transport = SwitchableTransport()
        transport.setEventBodies([Route.eventOne, Route.updatedPlusNew])
        let store = makeStore(transport: transport, deadline: 5)

        store.setMenuOpen(true)
        await store.refresh()
        await store.refresh()

        // Full window first, then the overlap window from the newest known event.
        XCTAssertEqual(transport.eventStartDates, [1_785_542_400_000, 1_785_657_576_745])
        let events = store.snapshot?.events ?? []
        XCTAssertEqual(events.count, 2)
        // The overlapping event's fresh row wins.
        XCTAssertEqual(events.first { $0.conversationID == "session-1" }?.cents, 99.9)
        XCTAssertEqual(events.first { $0.conversationID == "session-2" }?.cents, 5.0)
        XCTAssertEqual(store.snapshot?.lastActivity?.timeIntervalSince1970, 1_785_658_476.745)
    }

    func testSelectTeamClearsMergedEventsAndTheNextFetchIsAWholeWindow() async {
        let transport = SwitchableTransport()
        transport.useTwoTeams()
        let store = makeStore(transport: transport, deadline: 5)

        store.setMenuOpen(true)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-1"])

        transport.setEventBodies([Route.eventTwo])
        store.selectTeam(28605405)
        XCTAssertNil(store.snapshot)

        await store.refresh()

        // The bugbot reading must be a whole-window fetch and show only bugbot's events.
        XCTAssertEqual(transport.eventStartDates.last, 1_785_542_400_000)
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-2"])
        XCTAssertEqual(transport.teamIDs(forPath: "/api/dashboard/get-filtered-usage-events"), [27_362_705, 28_605_405])
    }

    func testSummaryPollsNeverMergeEventsAndTheNextFullReadIsWholeWindow() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 5)

        await store.refresh()

        XCTAssertEqual(transport.eventPageSizes, [1])
        XCTAssertEqual(store.snapshot?.events, [])

        store.setMenuOpen(true)
        await store.refresh()

        // A summary never established a merge base, so the full read starts from the cycle.
        // Two requests total: the summary poll, then the full read — both whole-window.
        XCTAssertEqual(transport.eventStartDates, [1_785_542_400_000, 1_785_542_400_000])
    }

    func testEveryTenthFullPublishReconcilesFromScratch() async {
        let transport = SwitchableTransport()
        transport.setEventBodies(Array(repeating: Route.eventOne, count: 9) + [Route.eventTwo])
        let store = makeStore(transport: transport, deadline: 5)

        store.setMenuOpen(true)
        for _ in 0..<9 { await store.refresh() }
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-1"])

        await store.refresh()

        // Eight top-ups, then the 10th publish re-reads the whole window and replaces.
        XCTAssertEqual(transport.eventStartDates.last, 1_785_542_400_000)
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-2"])
    }

    func testCycleRolloverReplacesTheMergedFeed() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 5)

        store.setMenuOpen(true)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-1"])

        transport.setSpendBody(27_362_705, Route.techDigitalNewCycleSpend)
        transport.setEventBodies([Route.eventTwo])
        await store.refresh()

        // The new cycle's start bounds the top-up window, and the merge is replaced.
        XCTAssertEqual(transport.eventStartDates.last, 1_788_220_800_000)
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-2"])
    }

    func testTruncatedFeedReplacesTheMergeAndForcesAWholeWindowNext() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 5)

        store.setMenuOpen(true)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-1"])

        // Three full pages of 500 with 1600 reported: the page cap bites.
        transport.setEventBodies(
            Array(repeating: Route.eventsBody(count: 500, total: 1_600, baseTimestamp: 1_785_658_000_000), count: 3)
        )
        await store.refresh()

        XCTAssertTrue(store.snapshot?.sessionsTruncated ?? false)
        XCTAssertEqual(store.snapshot?.events.count, 1_500)

        transport.setEventBodies([Route.eventOne])
        await store.refresh()

        // Truncation forced the next fetch back to the whole window.
        XCTAssertEqual(transport.eventStartDates.last, 1_785_542_400_000)
        XCTAssertFalse(store.snapshot?.sessionsTruncated ?? true)
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-1"])
    }

    func testFailedRefreshDoesNotAdvanceTheReconciliationCounter() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 5)

        store.setMenuOpen(true)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-1"])

        transport.failNextEventRequest()
        let failed = await store.refresh()
        XCTAssertFalse(failed)

        await store.refresh()

        // Only one publish happened, so the retry is still a top-up, not a reconciliation.
        XCTAssertEqual(transport.eventStartDates, [
            1_785_542_400_000, 1_785_657_576_745, 1_785_657_576_745,
        ])
        XCTAssertEqual(store.snapshot?.events.map(\.conversationID), ["session-1"])
    }

    // MARK: - Quiet backoff (P3)

    /// Unchanged readings in the background must stretch the poll interval:
    /// the first repeat is free, then x2, x4, x8.
    func testQuietPollsBackOffExponentially() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 5)

        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 60, "first publish sets the signature")
        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 60, "one unchanged poll is still free")
        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 120)
        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 240)
        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 480)
        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 480, "exponent is capped at x8")
    }

    /// The idle cadence would overshoot 30 minutes at x8; clamp it there.
    func testQuietBackoffIsCappedAtThirtyMinutes() async {
        let transport = SwitchableTransport()
        let store = makeStore(
            transport: transport, deadline: 5,
            activity: StubActivity(isCursorRunning: true, secondsSinceCursorFrontmost: 400)
        )
        for _ in 0..<4 { await store.refresh() }
        XCTAssertEqual(store.currentInterval(), 1_200)
        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 1_800)
    }

    /// Cursor not running already polls at the slowest cadence; leave it alone.
    func testDormantCadenceIsNotMultiplied() async {
        let store = makeStore(
            transport: SwitchableTransport(), deadline: 5,
            activity: StubActivity(isCursorRunning: false, secondsSinceCursorFrontmost: nil)
        )
        for _ in 0..<6 { await store.refresh() }
        XCTAssertEqual(store.currentInterval(), 1_800)
    }

    /// Any real change returns the next poll to the base cadence immediately.
    func testChangedActivityResetsTheBackoff() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 5)
        for _ in 0..<3 { await store.refresh() }
        XCTAssertEqual(store.currentInterval(), 120)

        transport.setSpendBody(27_362_705, Route.techDigitalNewCycleSpend)
        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 60)
    }

    /// An open menu always polls at the base cadence, and opening it resets
    /// the streak so closing it again starts fresh.
    func testMenuOpenIgnoresAndResetsQuietBackoff() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 5)
        for _ in 0..<3 { await store.refresh() }
        XCTAssertEqual(store.currentInterval(), 120)

        store.setMenuOpen(true)
        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 60, "open menu keeps the base cadence")

        store.setMenuOpen(false)
        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 60, "opening the menu reset the streak")
    }

    /// Failure backoff and quiet backoff must never compound.
    func testFailureBackoffDoesNotCompoundWithQuietBackoff() async {
        let transport = SwitchableTransport()
        let store = makeStore(transport: transport, deadline: 5)
        for _ in 0..<4 { await store.refresh() }
        XCTAssertEqual(store.currentInterval(), 240)

        transport.failNextEventRequest()
        await store.refresh()
        XCTAssertEqual(store.currentInterval(), 120, "failure backoff only: 60 x 2")
    }

    /// A reading published under a backed-off interval must not be flagged
    /// stale between polls just because it is older than the base cadence.
    func testStalenessFollowsTheEffectiveInterval() async {
        let transport = SwitchableTransport()
        var now = Date()
        let store = makeStore(transport: transport, deadline: 5, clock: { now })
        for _ in 0..<4 { await store.refresh() }
        XCTAssertEqual(store.currentInterval(), 240)

        now = now.addingTimeInterval(200) // older than 60 x 2.5, younger than 240 x 2.5
        XCTAssertFalse(store.isStale)
        now = now.addingTimeInterval(1_000)
        XCTAssertTrue(store.isStale)
    }

}
