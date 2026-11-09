import XCTest
@testable import CursorGaugeCore

// MARK: - Doubles

private final class StubCredentials: CredentialsProviding {
    var invalidateCount = 0
    var error: TokenError?

    func load() throws -> CursorCredentials {
        if let error { throw error }
        return CursorCredentials(
            accessToken: "TOKEN",
            userSub: "user_ABC",
            expiresAt: Date(timeIntervalSince1970: 1_790_839_766)
        )
    }

    func invalidate() { invalidateCount += 1 }
}

/// `fetchSnapshot` issues three requests concurrently, so the recorder has to be
/// thread-safe — without the lock the appends race and the test binary segfaults.
private final class StubTransport: Transport, @unchecked Sendable {
    /// path → (body, status)
    var routes: [String: (String, Int)] = [:]

    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append(request)
        let route = routes[request.url?.path ?? ""]
        lock.unlock()

        let (body, status) = route ?? ("{}", 404)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

// MARK: - Fixtures captured from the live account

private enum Fixture {
    static let authMe = """
    {"email":"someone@example.com","name":"Someone","sub":"user_ABC","id":307093031}
    """

    static let teams = """
    {"teams":[
      {"name":"bugbot","id":28605405,"role":"TEAM_ROLE_MEMBER","isEnterprise":true},
      {"name":"tech-digital","id":27362705,"role":"TEAM_ROLE_MEMBER","isEnterprise":true}
    ]}
    """

    /// The team that actually carries the per-user limit.
    static let spendWithLimit = """
    {"teamMemberSpend":[
      {"userId":111,"name":"Someone Else","email":"else@example.com","role":"TEAM_ROLE_MEMBER","overallSpendCents":900},
      {"userId":307093031,"name":"Someone","email":"someone@example.com","role":"TEAM_ROLE_MEMBER",
       "overallSpendCents":251,"monthlyLimitDollars":200,"effectivePerUserLimitDollars":200}
    ],
     "subscriptionCycleStart":"1785542400000","nextCycleStart":"1788220800000","totalMembers":105}
    """

    /// A team the user belongs to but which publishes no limit for them.
    static let spendWithoutLimit = """
    {"teamMemberSpend":[
      {"userId":307093031,"name":"Someone","email":"someone@example.com","role":"TEAM_ROLE_MEMBER","overallSpendCents":0}
    ],
     "subscriptionCycleStart":"1785542400000","nextCycleStart":"1788220800000","totalMembers":403}
    """

    static let aggregated = """
    {"aggregations":[{"modelIntent":"composer-2.5-fast","inputTokens":"319174","outputTokens":"27985",
      "cacheReadTokens":"3732298","totalCents":308.809726,"tier":1}],
     "totalInputTokens":"319174","totalCostCents":308.809726}
    """

    /// Shape captured live: a planning chat plus two subagents it spawned, and one event
    /// carrying no `conversationId` at all.
    static let events = """
    {"totalUsageEventsCount":4,"usageEventsDisplay":[
      {"timestamp":"1785658176745","model":"claude-sonnet-5-thinking-high","chargedCents":155.216,
       "conversationId":"kid-1","isHeadless":false},
      {"timestamp":"1785658176000","model":"composer-2.5-fast","chargedCents":26.93,
       "conversationId":"kid-2","isHeadless":false},
      {"timestamp":"1785658175000","model":"composer-2.5-fast","chargedCents":96.867,
       "conversationId":"root","isHeadless":false},
      {"timestamp":"1785658174000","model":"composer-2.5-fast","chargedCents":10.0,"isHeadless":false}]}
    """

    /// Cursor serves its dashboard HTML shell for routes that no longer exist.
    static let htmlShell = "<!DOCTYPE html><html lang=\"en\"><head><title>Cursor</title></head></html>"
}

// MARK: - Tests

final class CursorAPITests: XCTestCase {
    private var transport: StubTransport!
    private var credentials: StubCredentials!
    private var api: CursorAPI!
    private let now = Date(timeIntervalSince1970: 1_785_658_392)

    override func setUp() {
        super.setUp()
        transport = StubTransport()
        credentials = StubCredentials()
        api = CursorAPI(
            credentials: credentials,
            transport: transport,
            calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                return calendar
            }(),
            clock: { self.now }
        )
    }

    private func routeHappyPath() {
        transport.routes = [
            "/api/auth/me": (Fixture.authMe, 200),
            "/api/dashboard/teams": (Fixture.teams, 200),
            "/api/dashboard/get-aggregated-usage-events": (Fixture.aggregated, 200),
            "/api/dashboard/get-filtered-usage-events": (Fixture.events, 200),
        ]
    }

    // MARK: Headers

    func testRequestsCarryCookieAndOriginHeaders() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)
        _ = try await api.discoverIdentity()

        let request = try XCTUnwrap(transport.requests.first { $0.url?.path == "/api/dashboard/get-team-spend" })
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=user_ABC%3A%3ATOKEN")
        // Without Origin, Cursor answers 403 "Invalid origin for state-changing request".
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    // MARK: Identity discovery

    func testPicksTheTeamThatPublishesASpendLimit() async throws {
        routeHappyPath()
        // Both teams answer on the same path; vary by body order using a counter.
        final class OrderedTransport: Transport, @unchecked Sendable {
            var spendBodies: [String] = []
            var other: [String: (String, Int)] = [:]
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let path = request.url?.path ?? ""
                let body: String
                if path == "/api/dashboard/get-team-spend" {
                    body = spendBodies.isEmpty ? "{}" : spendBodies.removeFirst()
                } else {
                    body = other[path]?.0 ?? "{}"
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        }
        let ordered = OrderedTransport()
        ordered.other = transport.routes
        // bugbot is listed first and has no limit; tech-digital must still win.
        ordered.spendBodies = [Fixture.spendWithoutLimit, Fixture.spendWithLimit]

        let api = CursorAPI(credentials: credentials, transport: ordered, clock: { self.now })
        let identity = try await api.discoverIdentity()

        XCTAssertEqual(identity.teamID, 27362705)
        XCTAssertEqual(identity.teamName, "tech-digital")
        XCTAssertEqual(identity.numericUserID, 307093031)
    }

    func testIdentityIsCachedAcrossCalls() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)

        _ = try await api.discoverIdentity()
        let afterFirst = transport.requests.count
        _ = try await api.discoverIdentity()

        XCTAssertEqual(transport.requests.count, afterFirst, "second call should not hit the network")
    }

    func testForgetIdentityForcesRediscovery() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)

        _ = try await api.discoverIdentity()
        let afterFirst = transport.requests.count
        api.forgetIdentity()
        _ = try await api.discoverIdentity()

        XCTAssertGreaterThan(transport.requests.count, afterFirst)
    }

    func testNoMatchingTeamMembershipThrows() async {
        transport.routes = [
            "/api/auth/me": ("{\"id\":999,\"sub\":\"user_ABC\"}", 200),
            "/api/dashboard/teams": (Fixture.teams, 200),
            "/api/dashboard/get-team-spend": (Fixture.spendWithLimit, 200),
        ]
        await XCTAssertThrowsErrorAsync(try await api.discoverIdentity()) { error in
            guard case .noTeamFound? = error as? APIError else {
                return XCTFail("expected .noTeamFound, got \(error)")
            }
        }
    }

    // MARK: Snapshot

    func testSnapshotCombinesSpendLimitAndUsage() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)

        let snapshot = try await api.fetchSnapshot()

        XCTAssertEqual(snapshot.settledSpendCents, 251, accuracy: 0.001)
        XCTAssertEqual(snapshot.liveSpendCents, 308.809726, accuracy: 0.0001)
        XCTAssertEqual(snapshot.limitDollars ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(snapshot.cycleStart, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertEqual(snapshot.cycleEnd, Date(timeIntervalSince1970: 1_788_220_800))
        XCTAssertEqual(snapshot.models.first?.model, "composer-2.5-fast")
        XCTAssertEqual(snapshot.models.first?.inputTokens, 319_174)
        XCTAssertEqual(snapshot.models.first?.cacheReadTokens, 3_732_298)
        XCTAssertEqual(snapshot.lastActivity, Date(timeIntervalSince1970: 1_785_658_176.745))
        XCTAssertEqual(snapshot.events.count, 4)

        let eventsRequest = try XCTUnwrap(
            transport.requests.first { $0.url?.path == "/api/dashboard/get-filtered-usage-events" }
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(eventsRequest.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["page"] as? Int, 1)
        XCTAssertEqual(body["pageSize"] as? Int, 500)
    }

    func testDateRangesAreSentAsMillisecondStrings() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)
        _ = try await api.fetchSnapshot()

        let aggregation = try XCTUnwrap(
            transport.requests.first { $0.url?.path == "/api/dashboard/get-aggregated-usage-events" }
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(aggregation.httpBody)) as? [String: Any]
        )
        // Sent as strings — the API rejects some numeric forms.
        XCTAssertTrue(body["startDate"] is String)
        XCTAssertTrue(body["endDate"] is String)
        let start = try XCTUnwrap(body["startDate"] as? String)
        let end = try XCTUnwrap(body["endDate"] as? String)
        XCTAssertLessThan(Int(start)!, Int(end)!, "endDate must be after startDate or the API 400s")
    }

    func testMissingOwnEntryInSpendListIsReported() async {
        transport.routes = [
            "/api/auth/me": (Fixture.authMe, 200),
            "/api/dashboard/teams": (Fixture.teams, 200),
            "/api/dashboard/get-aggregated-usage-events": (Fixture.aggregated, 200),
            "/api/dashboard/get-filtered-usage-events": (Fixture.events, 200),
        ]
        // Discovery succeeds, then the spend list comes back without us in it.
        var callCount = 0
        final class DisappearingTransport: Transport, @unchecked Sendable {
            let base: StubTransport
            private let lock = NSLock()
            private var callCount = 0
            init(base: StubTransport) { self.base = base }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if request.url?.path == "/api/dashboard/get-team-spend" {
                    lock.lock()
                    callCount += 1
                    let isFirst = callCount == 1
                    lock.unlock()
                    let body = isFirst ? Fixture.spendWithLimit : Fixture.spendWithoutLimitForOtherUser
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(body.utf8), response)
                }
                return try await base.send(request)
            }
        }
        _ = callCount
        let disappearing = DisappearingTransport(base: transport)
        let api = CursorAPI(credentials: credentials, transport: disappearing, clock: { self.now })

        await XCTAssertThrowsErrorAsync(try await api.fetchSnapshot()) { error in
            guard case .shapeChanged? = error as? APIError else {
                return XCTFail("expected .shapeChanged, got \(error)")
            }
        }
    }

    // MARK: Failure handling

    func testHTMLResponseIsReportedAsChangedShapeNotParsed() async {
        transport.routes = [
            "/api/auth/me": (Fixture.htmlShell, 200),
        ]
        await XCTAssertThrowsErrorAsync(try await api.discoverIdentity()) { error in
            guard case .notJSON? = error as? APIError else {
                return XCTFail("expected .notJSON, got \(error)")
            }
        }
    }

    func testUnauthorizedInvalidatesCachedCredentials() async {
        transport.routes = ["/api/auth/me": ("{\"error\":\"nope\"}", 401)]
        await XCTAssertThrowsErrorAsync(try await api.discoverIdentity()) { error in
            XCTAssertTrue((error as? APIError)?.isRecoverableByReauth == true)
        }
        XCTAssertEqual(credentials.invalidateCount, 1)
    }

    func testForbiddenIsAlsoTreatedAsAuthFailure() async {
        // Cursor returns 403 for a missing Origin header as well as a dead session.
        transport.routes = ["/api/auth/me": ("{\"error\":\"Invalid origin\"}", 403)]
        await XCTAssertThrowsErrorAsync(try await api.discoverIdentity()) { error in
            guard case .unauthorized? = error as? APIError else {
                return XCTFail("expected .unauthorized, got \(error)")
            }
        }
    }

    func testServerErrorSurfacesStatusCode() async {
        transport.routes = ["/api/auth/me": ("{}", 500)]
        await XCTAssertThrowsErrorAsync(try await api.discoverIdentity()) { error in
            guard case .http(let status, _)? = error as? APIError else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(status, 500)
        }
    }

    func testTokenFailurePropagates() async {
        credentials.error = .notSignedIn
        await XCTAssertThrowsErrorAsync(try await api.discoverIdentity()) { error in
            XCTAssertEqual(error as? TokenError, .notSignedIn)
        }
    }

    // MARK: Decoding tolerance

    func testAcceptsNumbersWhetherStringOrNumeric() throws {
        let asString = try JSONDecoder().decode(LooseNumber.self, from: Data("\"1785542400000\"".utf8))
        let asNumber = try JSONDecoder().decode(LooseNumber.self, from: Data("1785542400000".utf8))
        XCTAssertEqual(asString.value, asNumber.value)
    }

    func testUnparseableNumberIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(LooseNumber.self, from: Data("\"abc\"".utf8)))
    }

    func testColleagueIdentityIsNotDecoded() throws {
        // The payload carries names and emails for all 105 members. Nothing in our model
        // captures them, so they're dropped at the decode boundary.
        let decoded = try JSONDecoder().decode(TeamSpendResponse.self, from: Data(Fixture.spendWithLimit.utf8))
        let mirror = Mirror(reflecting: decoded.teamMemberSpend[0])
        let fields = mirror.children.compactMap(\.label).sorted()
        XCTAssertEqual(fields, ["effectivePerUserLimitDollars", "monthlyLimitDollars", "overallSpendCents", "userId"])
    }
}

private extension Fixture {
    /// A spend list that omits our own user id entirely.
    static let spendWithoutLimitForOtherUser = """
    {"teamMemberSpend":[{"userId":555,"overallSpendCents":10}],
     "subscriptionCycleStart":"1785542400000","nextCycleStart":"1788220800000"}
    """
}

// MARK: - Sessions

/// Names come from Cursor's local store in production; here they come from a dictionary,
/// so the network path is testable with no database.
private final class StubNaming: SessionNaming {
    var records: [String: SessionRecord]
    private(set) var askedFor: [String] = []

    init(_ records: [String: SessionRecord]) { self.records = records }

    func records(for ids: [String]) -> [String: SessionRecord] {
        askedFor += ids
        var found: [String: SessionRecord] = [:]
        var pending = ids
        while let id = pending.popLast() {
            guard found[id] == nil, let record = records[id] else { continue }
            found[id] = record
            if let parent = record.parentID { pending.append(parent) }
        }
        return found
    }
}

extension CursorAPITests {
    private func sessionAPI(_ naming: StubNaming) -> CursorAPI {
        CursorAPI(
            credentials: credentials, transport: transport,
            calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                return calendar
            }(),
            naming: naming, clock: { self.now }
        )
    }

    func testSummarySnapshotReadsOnlyTheLatestEvent() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)
        let naming = StubNaming([:])

        let snapshot = try await sessionAPI(naming).fetchSnapshot(detail: .summary)

        let calls = transport.requests.filter { $0.url?.path == "/api/dashboard/get-filtered-usage-events" }
        XCTAssertEqual(calls.count, 1)
        let request = try XCTUnwrap(calls.first)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["page"] as? Int, 1)
        XCTAssertEqual(body["pageSize"] as? Int, 1)
        XCTAssertEqual(snapshot.lastActivity, Date(timeIntervalSince1970: 1_785_658_176.745))
        XCTAssertEqual(snapshot.sessions, SessionBreakdown.empty)
        XCTAssertFalse(snapshot.sessionsTruncated)
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertTrue(naming.askedFor.isEmpty)
        XCTAssertEqual(snapshot.settledSpendCents, 251, accuracy: 0.001)
        XCTAssertEqual(snapshot.liveSpendCents, 308.809726, accuracy: 0.0001)
        XCTAssertEqual(snapshot.todayCents, 308.809726, accuracy: 0.0001)
        XCTAssertEqual(snapshot.limitDollars ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(snapshot.cycleStart, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertEqual(snapshot.cycleEnd, Date(timeIntervalSince1970: 1_788_220_800))
        XCTAssertEqual(snapshot.models.first?.model, "composer-2.5-fast")
        XCTAssertEqual(snapshot.models.first?.inputTokens, 319_174)
        XCTAssertEqual(snapshot.capturedAt, now)
    }

    func testDecodesConversationIDAndNestsSubagents() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)
        let naming = StubNaming([
            "root": SessionRecord(name: "OXP-54 feature discussion", parentID: nil),
            "kid-1": SessionRecord(name: "Implement Task 7", parentID: "root"),
            "kid-2": SessionRecord(name: "Review Task 6", parentID: "root"),
        ])

        let snapshot = try await sessionAPI(naming).fetchSnapshot()

        XCTAssertEqual(snapshot.sessions.ranked.map(\.id), ["root"])
        let root = try XCTUnwrap(snapshot.sessions.ranked.first)
        XCTAssertEqual(root.children.map(\.id), ["kid-1", "kid-2"])
        XCTAssertEqual(root.rolledCents, 155.216 + 26.93 + 96.867, accuracy: 0.001)
    }

    /// Captured live from a real cloud agent run: Cursor sets both `isHeadless` and a
    /// `cloudAgentId`, and uses that id as the `conversationId`. Either alone is taken as
    /// proof, so the row survives Cursor dropping one of them.
    func testCloudAgentEventsAreRecognisedFromEitherSignal() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)
        transport.routes["/api/dashboard/get-filtered-usage-events"] = ("""
        {"totalUsageEventsCount":3,"usageEventsDisplay":[
          {"timestamp":"1786590855593","model":"cursor-grok-4.6-high-fast","chargedCents":53.68,
           "conversationId":"bc-41003f3d","isHeadless":true,"cloudAgentId":"bc-41003f3d"},
          {"timestamp":"1786590855000","model":"composer-2.5-fast","chargedCents":10.0,
           "conversationId":"bc-other","cloudAgentId":"bc-other"},
          {"timestamp":"1786590854000","model":"composer-2.5-fast","chargedCents":5.0,
           "conversationId":"local-chat","isHeadless":false}]}
        """, 200)

        let sessions = try await sessionAPI(StubNaming([:])).fetchSnapshot().sessions

        XCTAssertEqual(sessions.cloudCount, 2, "isHeadless and cloudAgentId each suffice")
        XCTAssertEqual(sessions.cloudCents, 63.68, accuracy: 0.001)
        XCTAssertEqual(sessions.unnamedCents, 5.0, accuracy: 0.001, "the local chat is not cloud")
    }

    func testEventWithoutConversationIDStillCountsTowardTheTotal() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)
        let snapshot = try await sessionAPI(StubNaming([:])).fetchSnapshot()

        // All four events, including the one carrying no conversation id.
        XCTAssertEqual(snapshot.sessions.totalCents, 155.216 + 26.93 + 96.867 + 10, accuracy: 0.001)
        XCTAssertTrue(snapshot.sessions.ranked.isEmpty, "no names available, so nothing is listed")
        XCTAssertEqual(snapshot.sessions.unnamedCents, snapshot.sessions.totalCents, accuracy: 0.001)
    }

    func testLastActivityComesFromTheNewestEvent() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)
        let snapshot = try await sessionAPI(StubNaming([:])).fetchSnapshot()
        XCTAssertEqual(snapshot.lastActivity, Date(timeIntervalSince1970: 1_785_658_176.745))
    }

    /// Before sessions existed this call ran with `pageSize: 1` purely for the timestamp,
    /// so widening it must not have added a request to the poll.
    func testOneEventsRequestPerSnapshotOnANormalCycle() async throws {
        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)
        _ = try await sessionAPI(StubNaming([:])).fetchSnapshot()

        let calls = transport.requests.filter { $0.url?.path == "/api/dashboard/get-filtered-usage-events" }
        XCTAssertEqual(calls.count, 1, "a short page must end paging immediately")
    }

    func testPagesUntilTheReportedTotalIsCovered() async throws {
        // 500 events on page one, 20 on page two: paging must continue then stop.
        final class PagingTransport: Transport, @unchecked Sendable {
            let base: StubTransport
            private let lock = NSLock()
            private(set) var pages: [Int] = []
            init(base: StubTransport) { self.base = base }

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                guard request.url?.path == "/api/dashboard/get-filtered-usage-events" else {
                    return try await base.send(request)
                }
                let body = try JSONSerialization.jsonObject(
                    with: request.httpBody ?? Data()) as? [String: Any]
                let page = body?["page"] as? Int ?? 1
                lock.lock(); pages.append(page); lock.unlock()

                let count = page == 1 ? 500 : 20
                let rows = (0..<count).map {
                    "{\"timestamp\":\"1785658176745\",\"chargedCents\":1,\"conversationId\":\"c\($0)\"}"
                }.joined(separator: ",")
                let json = "{\"totalUsageEventsCount\":520,\"usageEventsDisplay\":[\(rows)]}"
                return (Data(json.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)
        let paging = PagingTransport(base: transport)
        let api = CursorAPI(
            credentials: credentials, transport: paging,
            naming: StubNaming([:]), clock: { self.now }
        )

        let snapshot = try await api.fetchSnapshot()
        XCTAssertEqual(paging.pages, [1, 2])
        XCTAssertEqual(snapshot.sessions.totalCents, 520, accuracy: 0.001)
        XCTAssertFalse(snapshot.sessionsTruncated)
    }

    func testStopsAtThePageCapAndFlagsTruncation() async throws {
        // A cycle larger than 3 × 500: paging must bound itself and say the list is partial.
        final class EndlessTransport: Transport, @unchecked Sendable {
            let base: StubTransport
            private let lock = NSLock()
            private(set) var calls = 0
            init(base: StubTransport) { self.base = base }

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                guard request.url?.path == "/api/dashboard/get-filtered-usage-events" else {
                    return try await base.send(request)
                }
                lock.lock(); calls += 1; lock.unlock()
                let rows = (0..<500).map {
                    "{\"timestamp\":\"1785658176745\",\"chargedCents\":1,\"conversationId\":\"c\($0)\"}"
                }.joined(separator: ",")
                let json = "{\"totalUsageEventsCount\":99999,\"usageEventsDisplay\":[\(rows)]}"
                return (Data(json.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        routeHappyPath()
        transport.routes["/api/dashboard/get-team-spend"] = (Fixture.spendWithLimit, 200)
        let endless = EndlessTransport(base: transport)
        let api = CursorAPI(
            credentials: credentials, transport: endless,
            naming: StubNaming([:]), clock: { self.now }
        )

        let snapshot = try await api.fetchSnapshot()
        XCTAssertEqual(endless.calls, 3, "must stop at the cap rather than page forever")
        XCTAssertTrue(snapshot.sessionsTruncated)
    }
}

// MARK: - Async throwing helper

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        handler(error)
    }
}
