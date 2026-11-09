import Foundation

// MARK: - Errors

public enum APIError: Error, CustomStringConvertible {
    case unauthorized
    /// The endpoint answered with HTML — almost always a 404 page from a renamed route.
    case notJSON(endpoint: String)
    case http(status: Int, endpoint: String)
    case transport(Error)
    case shapeChanged(String)
    case noTeamFound
    /// The reading outlived its deadline and was abandoned.
    case timedOut

    public var description: String {
        switch self {
        case .unauthorized: return "Cursor rejected the session — open Cursor to sign in again"
        case .notJSON(let endpoint): return "Cursor's API changed shape (\(endpoint))"
        case .http(let status, let endpoint): return "Cursor API error \(status) (\(endpoint))"
        case .transport: return "Can't reach cursor.com"
        case .timedOut: return "cursor.com didn't answer in time"
        case .shapeChanged(let detail): return "Unexpected data from Cursor: \(detail)"
        case .noTeamFound: return "No Cursor team with a spend limit found for this account"
        }
    }

    public var isRecoverableByReauth: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

// MARK: - Transport seam

public protocol Transport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: Transport {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // `timeoutIntervalForRequest` only measures the gap between packets, so it never
        // fires on a connection that is dead but still open — the state a VPN leaves
        // behind when it roams. Without an overall ceiling (the default is seven days)
        // such a request hangs indefinitely. This one bounds the whole load.
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpShouldSetCookies = false      // we set the Cookie header ourselves
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.shapeChanged("non-HTTP response")
            }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }
}

// MARK: - Wire models
//
// Only the fields we actually use are declared. That is deliberate for
// `MemberSpend`: colleagues' names and emails are present in the payload and are
// dropped at decode time so they never reach memory we own, a log, or the UI.

/// Cursor returns epoch-millisecond timestamps and token counts as strings in some
/// places and numbers in others. Accept both rather than breaking on their choice.
struct LooseNumber: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self), let number = Double(string) {
            value = number
        } else {
            throw APIError.shapeChanged("expected a number, got neither number nor numeric string")
        }
    }
}

struct AuthMeResponse: Decodable {
    let id: Int
    let sub: String
}

struct TeamsResponse: Decodable {
    struct Team: Decodable {
        let id: Int
        let name: String
    }
    let teams: [Team]
}

struct TeamSpendResponse: Decodable {
    struct MemberSpend: Decodable {
        let userId: Int
        let overallSpendCents: LooseNumber?
        let monthlyLimitDollars: LooseNumber?
        let effectivePerUserLimitDollars: LooseNumber?
    }
    let teamMemberSpend: [MemberSpend]
    let subscriptionCycleStart: LooseNumber?
    let nextCycleStart: LooseNumber?
}

struct AggregatedUsageResponse: Decodable {
    struct ModelAggregation: Decodable {
        let modelIntent: String
        let inputTokens: LooseNumber?
        let outputTokens: LooseNumber?
        let cacheReadTokens: LooseNumber?
        let totalCents: LooseNumber?
    }
    let aggregations: [ModelAggregation]?
    let totalCostCents: LooseNumber?
}

struct FilteredUsageResponse: Decodable {
    struct Event: Decodable {
        let timestamp: LooseNumber
        let model: String?
        let chargedCents: LooseNumber?
        /// Cursor's composer id — the chat this request belongs to.
        let conversationId: String?
        /// Set when the request ran with no editor attached — a cloud agent.
        let isHeadless: Bool?
        /// Present on cloud agent runs, and used as the `conversationId` too. Captured
        /// live alongside `isHeadless`; either alone is taken as proof, so the row
        /// survives Cursor dropping one of them.
        let cloudAgentId: String?
    }
    let totalUsageEventsCount: Int?
    let usageEventsDisplay: [Event]?
}

// MARK: - Domain models

/// Supplies chat names for the sessions list. A seam so the network path can be tested
/// without a database, and so a missing local store degrades instead of failing.
public protocol SessionNaming: AnyObject {
    func records(for ids: [String]) -> [String: SessionRecord]
}

extension SessionCatalog: SessionNaming {}

/// Who we are, as far as Cursor's billing is concerned. Discovered at startup so the
/// same build works for any signed-in user without configuration.
public struct AccountIdentity: Equatable {
    public let numericUserID: Int
    public let teamID: Int
    public let teamName: String
}

public struct ModelUsage: Equatable {
    public let model: String
    public let cents: Double
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
}

/// One complete reading of the account's billing position.
public struct UsageSnapshot: Equatable {
    /// The figure Cursor bills against the limit. Lags the live number by minutes.
    public let settledSpendCents: Double
    /// Live cycle-to-date total from the usage-event aggregation.
    public let liveSpendCents: Double
    public let limitDollars: Double?
    public let cycleStart: Date
    public let cycleEnd: Date
    public let todayCents: Double
    public let models: [ModelUsage]
    public let lastActivity: Date?
    public let capturedAt: Date
    /// Per-chat costs for this cycle, subagents rolled into the chat that spawned them.
    public let sessions: SessionBreakdown
    /// The page cap was reached, so the sessions list covers only part of the cycle.
    public let sessionsTruncated: Bool
    /// The individual billed requests behind `sessions`.
    ///
    /// The menu never reads these — it wants the rolled-up tree. The report does: joining
    /// spend to a repo needs the cost of every conversation, and `sessions` deliberately
    /// folds the ones it could not name into a single total, losing their ids.
    public let events: [SessionEvent]

    public init(
        settledSpendCents: Double, liveSpendCents: Double, limitDollars: Double?,
        cycleStart: Date, cycleEnd: Date, todayCents: Double,
        models: [ModelUsage], lastActivity: Date?, capturedAt: Date,
        sessions: SessionBreakdown = .empty, sessionsTruncated: Bool = false,
        events: [SessionEvent] = []
    ) {
        self.sessions = sessions
        self.sessionsTruncated = sessionsTruncated
        self.events = events
        self.settledSpendCents = settledSpendCents
        self.liveSpendCents = liveSpendCents
        self.limitDollars = limitDollars
        self.cycleStart = cycleStart
        self.cycleEnd = cycleEnd
        self.todayCents = todayCents
        self.models = models
        self.lastActivity = lastActivity
        self.capturedAt = capturedAt
    }
}

// MARK: - Client

public final class CursorAPI {
    public enum SnapshotDetail {
        case summary
        case full
    }

    /// One entry in the Settings team picker. Captured from the teams endpoint in API
    /// order every time identity discovery runs.
    public struct TeamOption: Equatable {
        public let id: Int
        public let name: String

        public init(id: Int, name: String) {
            self.id = id
            self.name = name
        }
    }

    private let transport: Transport
    private let credentials: CredentialsProviding
    private let clock: () -> Date
    private let calendar: Calendar
    private let naming: SessionNaming
    private var identity: AccountIdentity?
    /// The preference the cached `identity` was discovered with. A different value —
    /// including nil versus non-nil — means the cache does not apply.
    private var cachedPreferredTeamID: Int?

    public private(set) var teamOptions: [TeamOption] = []

    private static let base = "https://cursor.com"
    /// One page covers a normal cycle (84 events over the first six days of a heavy
    /// month); three bounds the work if someone's usage is an order of magnitude higher.
    private static let eventPageSize = 500
    private static let maxEventPages = 3

    /// A top-up reaches this far back from `eventsSince` to admit late-arriving billing
    /// events whose server record carries an earlier timestamp than the moment they
    /// appeared.
    private static let eventFeedOverlap: TimeInterval = 600

    public init(
        credentials: CredentialsProviding,
        transport: Transport = URLSessionTransport(),
        calendar: Calendar = .current,
        // Both front ends, so a terminal agent's chat is named as readily as an editor's.
        naming: SessionNaming = CombinedNaming([SessionCatalog(), CliCatalog()]),
        clock: @escaping () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.transport = transport
        self.calendar = calendar
        self.naming = naming
        self.clock = clock
    }

    public func forgetIdentity() {
        identity = nil
        cachedPreferredTeamID = nil
    }

    // MARK: Requests

    private func request(path: String, method: String, body: [String: Any]?) throws -> URLRequest {
        guard let url = URL(string: Self.base + path) else {
            throw APIError.shapeChanged("bad URL \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(try credentials.load().cookieHeader, forHTTPHeaderField: "Cookie")
        // Cursor rejects state-changing requests without a matching Origin:
        // 403 {"error":"Invalid origin for state-changing request"}
        request.setValue(Self.base, forHTTPHeaderField: "Origin")
        request.setValue(Self.base + "/dashboard", forHTTPHeaderField: "Referer")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func call<T: Decodable>(
        _ type: T.Type, path: String, method: String = "POST", body: [String: Any]? = [:]
    ) async throws -> T {
        let (data, response) = try await transport.send(try request(path: path, method: method, body: body))

        if response.statusCode == 401 || response.statusCode == 403 {
            // A stale token and a missing Origin header both land here; re-reading the
            // token is cheap and fixes the case we can actually fix.
            credentials.invalidate()
            throw APIError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode, endpoint: path)
        }
        // Removed routes return the dashboard's HTML shell with a 200.
        if let first = data.first, first == UInt8(ascii: "<") {
            throw APIError.notJSON(endpoint: path)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.shapeChanged("\(path): \(error)")
        }
    }

    // MARK: Identity discovery

    /// Works out which numeric user id and which team this Mac's signed-in user maps to.
    ///
    /// A user can belong to several teams (e.g. an org team plus a shared bugbot team).
    /// Selection order: an explicit `preferredTeamID` when that team still lists the
    /// user, otherwise the team with the most usage (ties: one publishing a limit, then
    /// API order). The cached result is scoped to the preference it was discovered
    /// with, so a different preference triggers rediscovery.
    public func discoverIdentity(preferredTeamID: Int? = nil) async throws -> AccountIdentity {
        if let identity, cachedPreferredTeamID == preferredTeamID { return identity }

        let me = try await call(AuthMeResponse.self, path: "/api/auth/me", method: "GET", body: nil)
        let teams = try await call(TeamsResponse.self, path: "/api/dashboard/teams")
        teamOptions = teams.teams.map { TeamOption(id: $0.id, name: $0.name) }

        struct Candidate {
            let identity: AccountIdentity
            let spendCents: Double
            let hasLimit: Bool
            let order: Int
        }

        var candidates: [Candidate] = []
        for (order, team) in teams.teams.enumerated() {
            let spend = try await call(
                TeamSpendResponse.self,
                path: "/api/dashboard/get-team-spend",
                body: ["teamId": team.id]
            )
            guard let mine = spend.teamMemberSpend.first(where: { $0.userId == me.id }) else { continue }
            candidates.append(Candidate(
                identity: AccountIdentity(numericUserID: me.id, teamID: team.id, teamName: team.name),
                spendCents: mine.overallSpendCents?.value ?? 0,
                hasLimit: mine.monthlyLimitDollars != nil || mine.effectivePerUserLimitDollars != nil,
                order: order
            ))
        }

        // 1. The user's explicit choice wins when it is still a team they belong to.
        if let preferredTeamID,
           let preferred = candidates.first(where: { $0.identity.teamID == preferredTeamID }) {
            identity = preferred.identity
            cachedPreferredTeamID = preferredTeamID
            return preferred.identity
        }

        // 2. Otherwise the most-used team: highest overallSpendCents; ties prefer a
        //    team publishing a limit, then the earliest in API order.
        let chosen = candidates.max { lhs, rhs in
            if lhs.spendCents != rhs.spendCents { return lhs.spendCents < rhs.spendCents }
            if lhs.hasLimit != rhs.hasLimit { return !lhs.hasLimit }
            return lhs.order > rhs.order
        }

        // 3. No team carries a spend row for this account.
        guard let chosen else { throw APIError.noTeamFound }

        identity = chosen.identity
        cachedPreferredTeamID = preferredTeamID
        return chosen.identity
    }

    // MARK: Snapshot

    /// - Parameter eventsSince: When non-nil and `detail` is `.full`, the event feed
    ///   window starts at `max(cycleStart, eventsSince - 10 minutes)` instead of covering
    ///   the whole cycle, so a top-up only re-downloads what is new. The overlap admits
    ///   late-arriving billing events whose server record carries an earlier timestamp
    ///   than the moment they appeared. Summary polls ignore this parameter.
    public func fetchSnapshot(
        detail: SnapshotDetail = .full,
        preferredTeamID: Int? = nil,
        eventsSince: Date? = nil
    ) async throws -> UsageSnapshot {
        let identity = try await discoverIdentity(preferredTeamID: preferredTeamID)
        let now = clock()

        let spend = try await call(
            TeamSpendResponse.self,
            path: "/api/dashboard/get-team-spend",
            body: ["teamId": identity.teamID]
        )
        guard let mine = spend.teamMemberSpend.first(where: { $0.userId == identity.numericUserID }) else {
            throw APIError.shapeChanged("this account is absent from its own team's spend list")
        }

        let cycleStart = spend.subscriptionCycleStart.map { Date(timeIntervalSince1970: $0.value / 1000) }
            ?? calendar.startOfMonth(for: now)
        let cycleEnd = spend.nextCycleStart.map { Date(timeIntervalSince1970: $0.value / 1000) }
            ?? calendar.startOfMonth(for: calendar.date(byAdding: .month, value: 1, to: now) ?? now)

        // A top-up only re-downloads what is new, reaching one overlap back to admit
        // late-arriving billing events. The summary path keeps the whole cycle: its
        // pageSize-1 read only fetches the newest row anyway.
        let eventFeedStart: Date
        if detail == .full, let eventsSince {
            eventFeedStart = max(cycleStart, eventsSince.addingTimeInterval(-Self.eventFeedOverlap))
        } else {
            eventFeedStart = cycleStart
        }

        let eventPageSize: Int
        let maxEventPages: Int
        switch detail {
        case .summary:
            eventPageSize = 1
            maxEventPages = 1
        case .full:
            eventPageSize = Self.eventPageSize
            maxEventPages = Self.maxEventPages
        }

        async let cycleUsage = aggregate(identity: identity, from: cycleStart, to: now)
        async let todayUsage = aggregate(identity: identity, from: calendar.startOfDay(for: now), to: now)
        async let cycleEvents = events(
            identity: identity, from: eventFeedStart, to: now,
            pageSize: eventPageSize, maxPages: maxEventPages
        )

        let (cycle, today, feed) = try await (cycleUsage, todayUsage, cycleEvents)
        let sessions: SessionBreakdown
        let sessionsTruncated: Bool
        let snapshotEvents: [SessionEvent]
        switch detail {
        case .summary:
            sessions = .empty
            sessionsTruncated = false
            snapshotEvents = []
        case .full:
            sessions = SessionBreakdown.build(
                events: feed.events,
                catalog: naming.records(for: Array(Set(feed.events.compactMap(\.conversationID))))
            )
            sessionsTruncated = feed.truncated
            snapshotEvents = feed.events
        }

        return UsageSnapshot(
            settledSpendCents: mine.overallSpendCents?.value ?? 0,
            liveSpendCents: cycle.totalCostCents?.value ?? 0,
            limitDollars: (mine.effectivePerUserLimitDollars ?? mine.monthlyLimitDollars)?.value,
            cycleStart: cycleStart,
            cycleEnd: cycleEnd,
            todayCents: today.totalCostCents?.value ?? 0,
            // The aggregate reports `default` and `auto-smart` as separate intents even
            // though both mean Auto, so they are relabelled and then summed — otherwise
            // the same setting would appear as two rows under one name.
            models: (cycle.aggregations ?? []).reduce(into: [String: ModelUsage]()) { totals, a in
                let name = ModelName.display(a.modelIntent)
                let existing = totals[name]
                totals[name] = ModelUsage(
                    model: name,
                    cents: (existing?.cents ?? 0) + (a.totalCents?.value ?? 0),
                    inputTokens: (existing?.inputTokens ?? 0) + Int(a.inputTokens?.value ?? 0),
                    outputTokens: (existing?.outputTokens ?? 0) + Int(a.outputTokens?.value ?? 0),
                    cacheReadTokens: (existing?.cacheReadTokens ?? 0) + Int(a.cacheReadTokens?.value ?? 0)
                )
            }.values.sorted { ($0.cents, $1.model) > ($1.cents, $0.model) },
            lastActivity: feed.events.map(\.timestamp).max(),
            capturedAt: now,
            sessions: sessions,
            sessionsTruncated: sessionsTruncated,
            events: snapshotEvents
        )
    }

    /// Names (and subagent parents) for conversation ids, from the same local catalogs a
    /// snapshot fetch uses. Exposed so the store can rebuild session trees from a merged
    /// event set without reaching into the API's private naming.
    public func sessionRecords(for ids: [String]) -> [String: SessionRecord] {
        naming.records(for: ids)
    }

    private func aggregate(
        identity: AccountIdentity, from start: Date, to end: Date
    ) async throws -> AggregatedUsageResponse {
        // The API rejects a window that isn't strictly forward-going.
        guard end > start else { return AggregatedUsageResponse(aggregations: [], totalCostCents: nil) }
        return try await call(
            AggregatedUsageResponse.self,
            path: "/api/dashboard/get-aggregated-usage-events",
            body: [
                "teamId": identity.teamID,
                "userId": identity.numericUserID,
                "startDate": String(Int(start.timeIntervalSince1970 * 1000)),
                "endDate": String(Int(end.timeIntervalSince1970 * 1000)),
            ]
        )
    }

    struct EventFeed {
        let events: [SessionEvent]
        /// The page cap stopped us before the cycle was exhausted.
        let truncated: Bool
    }

    /// Every billed request in the window.
    ///
    /// This one call serves both the sessions list and "Last request"; before sessions
    /// existed it ran with `pageSize: 1` for the timestamp alone, so widening it adds no
    /// request to a poll.
    private func events(
        identity: AccountIdentity, from start: Date, to end: Date,
        pageSize: Int = CursorAPI.eventPageSize, maxPages: Int = CursorAPI.maxEventPages
    ) async throws -> EventFeed {
        guard end > start else { return EventFeed(events: [], truncated: false) }

        var collected: [FilteredUsageResponse.Event] = []
        var reported: Int?
        var exhaustedPages = true

        for page in 1...maxPages {
            let response = try await call(
                FilteredUsageResponse.self,
                path: "/api/dashboard/get-filtered-usage-events",
                body: [
                    "teamId": identity.teamID,
                    "userId": identity.numericUserID,
                    "page": page,
                    "pageSize": pageSize,
                    "startDate": String(Int(start.timeIntervalSince1970 * 1000)),
                    "endDate": String(Int(end.timeIntervalSince1970 * 1000)),
                ]
            )
            let batch = response.usageEventsDisplay ?? []
            collected += batch
            reported = response.totalUsageEventsCount ?? reported

            // Stop on a short page too: a server that ignores `page` would otherwise have
            // us request the same rows until the cap.
            if batch.count < pageSize || (reported.map { collected.count >= $0 } ?? false) {
                exhaustedPages = false
                break
            }
        }

        return EventFeed(
            events: collected.map {
                SessionEvent(
                    conversationID: $0.conversationId,
                    model: $0.model,
                    cents: $0.chargedCents?.value ?? 0,
                    timestamp: Date(timeIntervalSince1970: $0.timestamp.value / 1000),
                    isCloud: ($0.isHeadless ?? false) || $0.cloudAgentId != nil
                )
            },
            // Only a genuine cap hit counts as truncation. A server that simply reports a
            // larger total than it serves is not us losing data.
            truncated: exhaustedPages && (reported.map { collected.count < $0 } ?? false)
        )
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? date
    }
}
