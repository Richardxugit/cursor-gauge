import Foundation
import CursorGaugeCore

/// `CursorGauge --dry-run` prints the exact reading the menu bar would show, so the
/// numbers can be diffed against cursor.com/dashboard without launching the UI.
enum DryRun {
    static func run() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            let credentials = TokenStore()
            do {
                let loaded = try credentials.load()
                print("credentials")
                print("  user sub    \(loaded.userSub)")
                print("  expires     \(loaded.expiresAt)  (\(daysUntil(loaded.expiresAt)) days)")

                let api = CursorAPI(credentials: credentials)
                let identity = try await api.discoverIdentity()
                print("identity")
                print("  numeric id  \(identity.numericUserID)")
                print("  team        \(identity.teamName) (\(identity.teamID))")

                let snapshot = try await api.fetchSnapshot()
                let metrics = UsageMetrics(snapshot: snapshot, now: Date())

                print("snapshot")
                print("  settled     \(Format.money(cents: snapshot.settledSpendCents))")
                print("  live        \(Format.money(cents: snapshot.liveSpendCents))")
                print("  limit       \(snapshot.limitDollars.map { Format.money(dollars: $0) } ?? "none")")
                print("  cycle       \(snapshot.cycleStart) → \(snapshot.cycleEnd)")
                print("  today       \(Format.money(cents: snapshot.todayCents))")
                print("  last event  \(snapshot.lastActivity.map { "\($0)" } ?? "none today")")
                for model in snapshot.models {
                    print("  · \(model.model)  \(Format.money(cents: model.cents))"
                          + "  in \(Format.tokens(model.inputTokens))"
                          + " out \(Format.tokens(model.outputTokens))"
                          + " cached \(Format.tokens(model.cacheReadTokens))")
                }

                print("metrics")
                print("  headline    \(Format.money(cents: metrics.spentCents))")
                print("  of limit    \(metrics.rawFraction.map(Format.percent) ?? "n/a")")
                print("  cycle done  \(Format.percent(metrics.cycleElapsedFraction))")
                print("  burn/day    \(Format.money(cents: metrics.burnRateCentsPerDay))")
                print("  projected   \(metrics.projectedCents.map { Format.money(cents: $0) } ?? "too early")")
                print("  ahead pace  \(metrics.isAheadOfPace)")
                print("  level       \(metrics.level.rawValue)")

                print("menu bar    \(GaugeIcon.accessibilityDescription(fraction: metrics.fraction, level: metrics.level))")
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

    private static func daysUntil(_ date: Date) -> Int {
        Int(date.timeIntervalSinceNow / 86_400)
    }
}
