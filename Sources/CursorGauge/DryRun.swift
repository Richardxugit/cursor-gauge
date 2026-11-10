import Foundation
import CursorGaugeCore

/// `CursorGauge --dry-run` prints the exact reading the menu bar would show, so the
/// numbers can be diffed against cursor.com/dashboard without launching the UI.
enum DryRun {
    static func run() -> Never {
        let preferredTeamID = Preferences().selectedTeamID
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            let credentials = TokenStore()
            do {
                let api = CursorAPI(credentials: credentials)
                try await readAndPrint(
                    credentials: credentials,
                    api: api,
                    preferredTeamID: preferredTeamID,
                    output: { print($0) }
                )
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

    static func readAndPrint(
        credentials: CredentialsProviding,
        api: CursorAPI,
        preferredTeamID: Int?,
        output: (String) -> Void
    ) async throws {
        let loaded = try credentials.load()
        output("credentials")
        output("  user sub    \(loaded.userSub)")
        output("  expires     \(loaded.expiresAt)  (\(daysUntil(loaded.expiresAt)) days)")

        let identity = try await api.discoverIdentity(preferredTeamID: preferredTeamID)
        output("identity")
        output("  numeric id  \(identity.numericUserID)")
        output("  team        \(identity.teamName) (\(identity.teamID))")

        let snapshot = try await api.fetchSnapshot(preferredTeamID: preferredTeamID)
        let metrics = UsageMetrics(snapshot: snapshot, now: Date())

        output("snapshot")
        output("  settled     \(Format.money(cents: snapshot.settledSpendCents))")
        output("  live        \(Format.money(cents: snapshot.liveSpendCents))")
        output("  limit       \(snapshot.limitDollars.map { Format.money(dollars: $0) } ?? "none")")
        output("  cycle       \(snapshot.cycleStart) → \(snapshot.cycleEnd)")
        output("  today       \(Format.money(cents: snapshot.todayCents))")
        output("  last event  \(snapshot.lastActivity.map { "\($0)" } ?? "none today")")
        for model in snapshot.models {
            output("  · \(model.model)  \(Format.money(cents: model.cents))"
                   + "  in \(Format.tokens(model.inputTokens))"
                   + " out \(Format.tokens(model.outputTokens))"
                   + " cached \(Format.tokens(model.cacheReadTokens))")
        }

        let sessions = snapshot.sessions
        // The menu's MODELS section reads the events, not the aggregate above:
        // the events name models the aggregate only reports an intent for. Print
        // both, or --dry-run can agree with the dashboard while the menu differs.
        output("models (as the menu shows them)")
        for spend in sessions.models {
            output("  \(Format.money(cents: spend.cents).padded(8)) \(spend.model)")
        }

        let display = sessions.display(limit: 5)
        output("sessions\(snapshot.sessionsTruncated ? "  (PARTIAL — feed incomplete)" : "")")
        for node in display.rows {
            output("  \(Format.money(cents: node.rolledCents).padded(8)) \(node.name ?? "?")")
            for child in node.children {
                output("      \(Format.money(cents: child.rolledCents).padded(8)) \(child.name ?? "?")")
            }
        }
        if sessions.cloudCount > 0 {
            output("  \(Format.money(cents: sessions.cloudCents).padded(8)) ☁ cloud agents (\(sessions.cloudCount))")
        }
        if display.hasMore {
            output("  \(Format.money(cents: display.hiddenCents).padded(8)) + \(display.hiddenCount) more")
        }
        // The check that proves nothing was dropped or double-counted: what the
        // menu draws must add up to the cycle it claims to describe.
        let shown = display.rows.reduce(0) { $0 + Format.displayedCents($1.rolledCents) }
            + Format.displayedCents(sessions.cloudCents)
            + display.hiddenCents
        let expected = Format.displayedCents(sessions.totalCents)
        output("  ── reconcile: rows \(Format.money(cents: shown))"
               + " vs cycle \(Format.money(cents: expected))"
               + "  \(shown == expected ? "OK" : "MISMATCH")")

        output("metrics")
        output("  headline    \(Format.money(cents: metrics.spentCents))")
        output("  of limit    \(metrics.rawFraction.map(Format.percent) ?? "n/a")")
        output("  cycle done  \(Format.percent(metrics.cycleElapsedFraction))")
        output("  burn/day    \(Format.money(cents: metrics.burnRateCentsPerDay))")
        output("  projected   \(metrics.projectedCents.map { Format.money(cents: $0) } ?? "too early")")
        output("  ahead pace  \(metrics.isAheadOfPace)")
        output("  level       \(metrics.level.rawValue)")

        output("menu bar    \(GaugeIcon.accessibilityDescription(fraction: metrics.fraction, level: metrics.level))")
    }

    private static func daysUntil(_ date: Date) -> Int {
        Int(date.timeIntervalSinceNow / 86_400)
    }
}

private extension String {
    /// Right-aligns money so the reconciliation column is readable in a terminal.
    func padded(_ width: Int) -> String {
        String(repeating: " ", count: max(0, width - count)) + self
    }
}
