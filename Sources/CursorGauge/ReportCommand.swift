import AppKit
import Foundation
import CursorGaugeCore

/// Builds the usage report and writes it as a single HTML file.
///
/// Shared by `--report` and the menu's **Report…** item, so the two can never drift apart.
enum ReportCommand {
    /// Where a report goes when the caller does not say.
    ///
    /// The temporary directory, deliberately: the report is a view of data that lives
    /// elsewhere, regenerated whenever it is wanted, and it names chats and repositories —
    /// so it should not quietly accumulate in Documents.
    static func defaultDestination(now: Date = Date()) -> URL {
        let stamp = DateFormatter.fileStamp.string(from: now)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-usage-\(stamp).html")
    }

    /// Gathers both halves and writes the page.
    ///
    /// The local half is best-effort by design: `ActivityCatalog` yields an empty digest
    /// rather than failing, and the report says so on its own face. Only the billing half
    /// can make this throw.
    static func write(to destination: URL, now: Date = Date()) async throws -> URL {
        let credentials = TokenStore()
        let api = CursorAPI(credentials: credentials)
        let snapshot = try await api.fetchSnapshot()

        // The activity window is the billing cycle, so both halves of every figure on the
        // page describe the same period.
        let activity = ActivityCatalog().digest(since: snapshot.cycleStart)
        let report = UsageReport.build(
            snapshot: snapshot,
            metrics: UsageMetrics(snapshot: snapshot, now: now),
            activity: activity,
            now: now
        )

        try ReportRenderer.html(report).write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    /// `CursorGauge --report [path]`.
    static func run(path: String?) -> Never {
        let destination = path.map { URL(fileURLWithPath: $0) } ?? defaultDestination()
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                let written = try await write(to: destination)
                print("report written to \(written.path)")
                NSWorkspace.shared.open(written)
            } catch {
                let message = (error as? TokenError)?.description
                    ?? (error as? APIError)?.description
                    ?? error.localizedDescription
                FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
                exitCode = 1
            }
            semaphore.signal()
        }

        semaphore.wait()
        exit(exitCode)
    }
}

private extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}
