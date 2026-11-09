import XCTest
import CursorGaugeCore
@testable import CursorGauge

final class ReportCommandTests: XCTestCase {
    func testWriteUsesExplicitTeamForFinalSnapshotRequests() async throws {
        let transport = try await recordReportRequests(
            preferredTeamID: TeamContextFixtures.selectedTeamID
        )

        let spend = try transport.teamIDs(for: TeamContextFixtures.spendPath)
        XCTAssertEqual(spend.last, TeamContextFixtures.selectedTeamID)
        XCTAssertEqual(
            try transport.teamIDs(for: TeamContextFixtures.aggregatePath),
            [TeamContextFixtures.selectedTeamID, TeamContextFixtures.selectedTeamID]
        )
        XCTAssertEqual(
            try transport.teamIDs(for: TeamContextFixtures.eventsPath),
            [TeamContextFixtures.selectedTeamID]
        )
    }

    func testWriteWithNilPreferenceUsesAutoTeam() async throws {
        let transport = try await recordReportRequests(preferredTeamID: nil)

        let spend = try transport.teamIDs(for: TeamContextFixtures.spendPath)
        XCTAssertEqual(spend.last, TeamContextFixtures.autoTeamID)
        XCTAssertEqual(
            try transport.teamIDs(for: TeamContextFixtures.aggregatePath),
            [TeamContextFixtures.autoTeamID, TeamContextFixtures.autoTeamID]
        )
        XCTAssertEqual(
            try transport.teamIDs(for: TeamContextFixtures.eventsPath),
            [TeamContextFixtures.autoTeamID]
        )
    }

    private func recordReportRequests(
        preferredTeamID: Int?
    ) async throws -> RecordingTransport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let credentials = RecordingCredentials()
        let transport = RecordingTransport()
        let destination = root.appendingPathComponent("report.json")
        _ = try await ReportCommand.write(
            to: destination,
            format: .json(withPromptText: false),
            now: TeamContextFixtures.now,
            preferredTeamID: preferredTeamID,
            api: TeamContextFixtures.api(credentials: credentials, transport: transport),
            activityCatalog: ActivityCatalog(
                databaseURL: root.appendingPathComponent("missing-state.vscdb")
            ),
            cliCatalog: CliCatalog(root: root.appendingPathComponent("missing-chats"))
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        return transport
    }
}
