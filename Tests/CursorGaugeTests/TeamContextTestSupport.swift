import Foundation
import CursorGaugeCore

final class RecordingCredentials: CredentialsProviding {
    func load() throws -> CursorCredentials {
        CursorCredentials(
            accessToken: "TOKEN",
            userSub: "user_TEST",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }

    func invalidate() {}
}

/// Records every request and answers with two teams whose Auto choice differs from
/// the explicitly selectable team. Snapshot fan-out makes thread safety necessary.
final class RecordingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)

        let path = request.url?.path ?? ""
        let body: String
        let status: Int
        switch path {
        case "/api/auth/me":
            body = #"{"id":42,"sub":"user_TEST"}"#
            status = 200
        case "/api/dashboard/teams":
            body = #"{"teams":[{"id":101,"name":"Low"},{"id":202,"name":"Auto"}]}"#
            status = 200
        case "/api/dashboard/get-team-spend":
            let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                as? [String: Any]
            let teamID = object?["teamId"] as? Int ?? -1
            body = TeamContextFixtures.spend(teamID: teamID)
            status = 200
        case "/api/dashboard/get-aggregated-usage-events":
            body = #"{"aggregations":[],"totalCostCents":100}"#
            status = 200
        case "/api/dashboard/get-filtered-usage-events":
            body = #"{"totalUsageEventsCount":0,"usageEventsDisplay":[]}"#
            status = 200
        default:
            body = "{}"
            status = 404
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
    }

    func teamIDs(for path: String) throws -> [Int] {
        try requests
            .filter { $0.url?.path == path }
            .compactMap { request in
                let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                    as? [String: Any]
                return object?["teamId"] as? Int
            }
    }
}

private final class EmptyNaming: SessionNaming {
    func records(for ids: [String]) -> [String: SessionRecord] { [:] }
}

enum TeamContextFixtures {
    static let selectedTeamID = 101
    static let autoTeamID = 202
    static let now = Date(timeIntervalSince1970: 1_785_658_392)

    static let spendPath = "/api/dashboard/get-team-spend"
    static let aggregatePath = "/api/dashboard/get-aggregated-usage-events"
    static let eventsPath = "/api/dashboard/get-filtered-usage-events"

    static func api(
        credentials: RecordingCredentials,
        transport: RecordingTransport
    ) -> CursorAPI {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return CursorAPI(
            credentials: credentials,
            transport: transport,
            calendar: calendar,
            naming: EmptyNaming(),
            clock: { now }
        )
    }

    static func spend(teamID: Int) -> String {
        let cents = teamID == selectedTeamID ? 100 : 900
        return """
        {"teamMemberSpend":[{"userId":42,"overallSpendCents":\(cents),"monthlyLimitDollars":200}],
         "subscriptionCycleStart":"1785542400000","nextCycleStart":"1788220800000"}
        """
    }
}
