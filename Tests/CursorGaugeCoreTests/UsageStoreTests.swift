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
    func records(for ids: [String]) -> [String: SessionRecord] { [:] }
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
        {"totalUsageEventsCount":0,"usageEventsDisplay":[]}
        """,
    ]
}

/// Answers normally, or hangs indefinitely on demand.
///
/// The hang reproduces the failure that actually took the app down in the field: a
/// socket macOS still believed was open, on a VPN that had roamed underneath it, with
/// nothing ever arriving and so no gap between packets for a request timeout to catch.
private final class SwitchableTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var _stalling = false

    var stalling: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stalling }
        set { lock.lock(); _stalling = newValue; lock.unlock() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if stalling {
            // Far longer than any deadline under test. Only cancellation should end this
            // — if the store ever waits it out, the bug is still there.
            try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        }
        let body = Route.all[request.url?.path ?? ""] ?? "{}"
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
}
