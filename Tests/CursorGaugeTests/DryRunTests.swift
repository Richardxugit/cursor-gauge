import XCTest
@testable import CursorGauge

final class DryRunTests: XCTestCase {
    func testReadAndPrintUsesExplicitTeamForIdentityAndSnapshot() async throws {
        let result = try await recordDryRun(
            preferredTeamID: TeamContextFixtures.selectedTeamID
        )

        XCTAssertTrue(result.lines.contains("  team        Low (101)"))
        let spend = try result.transport.teamIDs(for: TeamContextFixtures.spendPath)
        XCTAssertEqual(spend.last, TeamContextFixtures.selectedTeamID)
        XCTAssertEqual(
            try result.transport.teamIDs(for: TeamContextFixtures.aggregatePath),
            [TeamContextFixtures.selectedTeamID, TeamContextFixtures.selectedTeamID]
        )
        XCTAssertEqual(
            try result.transport.teamIDs(for: TeamContextFixtures.eventsPath),
            [TeamContextFixtures.selectedTeamID]
        )
    }

    func testReadAndPrintWithNilPreferenceUsesAutoTeam() async throws {
        let result = try await recordDryRun(preferredTeamID: nil)

        XCTAssertTrue(result.lines.contains("  team        Auto (202)"))
        let spend = try result.transport.teamIDs(for: TeamContextFixtures.spendPath)
        XCTAssertEqual(spend.last, TeamContextFixtures.autoTeamID)
        XCTAssertEqual(
            try result.transport.teamIDs(for: TeamContextFixtures.aggregatePath),
            [TeamContextFixtures.autoTeamID, TeamContextFixtures.autoTeamID]
        )
        XCTAssertEqual(
            try result.transport.teamIDs(for: TeamContextFixtures.eventsPath),
            [TeamContextFixtures.autoTeamID]
        )
    }

    private func recordDryRun(
        preferredTeamID: Int?
    ) async throws -> (transport: RecordingTransport, lines: [String]) {
        let credentials = RecordingCredentials()
        let transport = RecordingTransport()
        var lines: [String] = []
        try await DryRun.readAndPrint(
            credentials: credentials,
            api: TeamContextFixtures.api(credentials: credentials, transport: transport),
            preferredTeamID: preferredTeamID,
            output: { lines.append($0) }
        )
        XCTAssertEqual(lines.first, "credentials")
        XCTAssertTrue(lines.contains("snapshot"))
        XCTAssertTrue(lines.contains("metrics"))
        return (transport, lines)
    }
}
