import Foundation

public enum GaugeLevel: String, Equatable {
    case normal, warning, critical
}

public struct GaugeThresholds: Equatable {
    public var warning: Double
    public var critical: Double
    /// Tint on pace even when the absolute percentage is low. On a $200 limit a healthy
    /// month barely moves the ring, so pace is the signal that actually fires.
    public var paceModeEnabled: Bool
    /// How far ahead of the calendar spending may run before pace trips. 1.25 = 25% over.
    public var paceTolerance: Double

    public static let `default` = GaugeThresholds(
        warning: 0.60, critical: 0.85, paceModeEnabled: true, paceTolerance: 1.25
    )

    public init(warning: Double, critical: Double, paceModeEnabled: Bool, paceTolerance: Double) {
        self.warning = warning
        self.critical = critical
        self.paceModeEnabled = paceModeEnabled
        self.paceTolerance = paceTolerance
    }
}

/// Everything the UI needs, derived from a snapshot. Pure — no I/O, no clock of its own.
public struct UsageMetrics: Equatable {
    /// Spend ÷ limit, clamped to 0...1 for drawing. `nil` when no limit is published.
    public let fraction: Double?
    /// Uncapped ratio, so "112% of limit" can still be stated truthfully.
    public let rawFraction: Double?
    public let cycleElapsedFraction: Double
    public let spentCents: Double
    public let limitDollars: Double?
    public let burnRateCentsPerDay: Double
    /// End-of-cycle extrapolation. `nil` for the first day, where it's pure noise.
    public let projectedCents: Double?
    public let isAheadOfPace: Bool
    public let level: GaugeLevel

    public init(snapshot: UsageSnapshot, thresholds: GaugeThresholds = .default, now: Date) {
        // The billed figure lags the live aggregation by minutes; the live one can lag
        // if events land against another team. Taking the larger keeps the headline
        // honest in both directions.
        let spent = max(snapshot.settledSpendCents, snapshot.liveSpendCents)
        spentCents = spent
        limitDollars = snapshot.limitDollars

        let cycleLength = snapshot.cycleEnd.timeIntervalSince(snapshot.cycleStart)
        let elapsed = now.timeIntervalSince(snapshot.cycleStart)
        cycleElapsedFraction = cycleLength > 0 ? min(max(elapsed / cycleLength, 0), 1) : 0

        if let limit = snapshot.limitDollars, limit > 0 {
            let ratio = (spent / 100) / limit
            rawFraction = ratio
            fraction = min(max(ratio, 0), 1)
        } else {
            rawFraction = nil
            fraction = nil
        }

        let elapsedDays = max(elapsed / 86_400, 0)
        burnRateCentsPerDay = elapsedDays > 0 ? spent / elapsedDays : 0

        // Extrapolating from a few hours of a month-long cycle produces wild numbers,
        // so stay silent until a full day of data exists.
        if elapsedDays >= 1, cycleElapsedFraction > 0 {
            projectedCents = spent / cycleElapsedFraction
        } else {
            projectedCents = nil
        }

        if let ratio = rawFraction, cycleElapsedFraction > 0 {
            isAheadOfPace = ratio > cycleElapsedFraction * thresholds.paceTolerance
        } else {
            isAheadOfPace = false
        }

        if let ratio = rawFraction {
            if ratio >= thresholds.critical {
                level = .critical
            } else if ratio >= thresholds.warning {
                level = .warning
            } else if thresholds.paceModeEnabled && isAheadOfPace && elapsedDays >= 1 {
                level = .warning
            } else {
                level = .normal
            }
        } else {
            level = .normal
        }
    }
}

// MARK: - Formatting

public enum Format {
    public static func money(cents: Double) -> String {
        let dollars = cents / 100
        if dollars >= 100 { return String(format: "$%.0f", dollars) }
        return String(format: "$%.2f", dollars)
    }

    public static func money(dollars: Double) -> String {
        dollars >= 100 ? String(format: "$%.0f", dollars) : String(format: "$%.2f", dollars)
    }

    public static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        return value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    public static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(count) / 1_000)
        default: return "\(count)"
        }
    }

    public static func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(Int(seconds))s ago"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }

    public static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
