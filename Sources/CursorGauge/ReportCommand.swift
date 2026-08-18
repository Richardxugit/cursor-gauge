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
    static func defaultDestination(extension ext: String = "html", now: Date = Date()) -> URL {
        let stamp = DateFormatter.fileStamp.string(from: now)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-usage-\(stamp).\(ext)")
    }

    /// What the report should be written as.
    enum Format {
        case html
        /// JSON for feeding to something else. `withPromptText` reads the prompts
        /// themselves, which nothing else in the app ever does.
        case json(withPromptText: Bool)

        var fileExtension: String {
            switch self {
            case .html: "html"
            case .json: "json"
            }
        }
    }

    /// Gathers both halves and writes the report.
    ///
    /// The local half is best-effort by design: `ActivityCatalog` yields an empty digest
    /// rather than failing, and the report says so on its own face. Only the billing half
    /// can make this throw.
    static func write(
        to destination: URL, format: Format = .html, now: Date = Date()
    ) async throws -> URL {
        let credentials = TokenStore()
        let api = CursorAPI(credentials: credentials)
        let snapshot = try await api.fetchSnapshot()

        // The activity window is the billing cycle, so both halves of every figure describe
        // the same period.
        // Two front ends, two stores. The editor's chats live in `state.vscdb`; the CLI keeps
        // its own under `~/.cursor/chats`, which nothing in the editor's store references —
        // which is exactly why CLI spend used to arrive with no name attached.
        let catalog = ActivityCatalog()
        let activity = catalog.digest(since: snapshot.cycleStart)
            .merging(CliCatalog().digest(since: snapshot.cycleStart))
        let report = UsageReport.build(
            snapshot: snapshot,
            metrics: UsageMetrics(snapshot: snapshot, now: now),
            activity: activity,
            now: now
        )

        let contents: String
        switch format {
        case .html:
            contents = ReportRenderer.html(report)
        case .json(let withPromptText):
            contents = try ReportExport.build(
                report: report,
                activity: activity,
                // Read only on an explicit opt-in, so the default path cannot leak text by
                // omission.
                promptText: withPromptText ? catalog.promptText(since: snapshot.cycleStart) : nil
            ).json()
        }

        try contents.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    /// `CursorGauge --report [path] [--json] [--with-prompts]`.
    static func run(path: String?, format: Format) -> Never {
        let destination = path.map { URL(fileURLWithPath: $0) }
            ?? defaultDestination(extension: format.fileExtension)
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                let written = try await write(to: destination, format: format)
                print("report written to \(written.path)")
                // Opening a JSON file would hand it to whatever claims the extension, which
                // is rarely what was wanted; the path on stdout is more useful.
                if case .html = format { NSWorkspace.shared.open(written) }
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
