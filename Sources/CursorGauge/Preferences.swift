import Foundation
import Observation
import ServiceManagement
import CursorGaugeCore

@Observable
final class Preferences {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case money, percent, iconOnly

        var id: String { rawValue }
        /// No worked example in the label — a baked-in figure goes stale the moment
        /// spend moves and reads like a bug.
        var label: String {
            switch self {
            case .money: return "Amount spent"
            case .percent: return "Percent of limit"
            case .iconOnly: return "Ring only"
            }
        }
    }

    var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) }
    }
    var paceModeEnabled: Bool {
        didSet { defaults.set(paceModeEnabled, forKey: Key.paceMode) }
    }
    /// Stored as percentages (0–100) because that's how they're edited.
    var warningPercent: Double {
        didSet { defaults.set(warningPercent, forKey: Key.warningPercent) }
    }
    var criticalPercent: Double {
        didSet { defaults.set(criticalPercent, forKey: Key.criticalPercent) }
    }

    private let defaults: UserDefaults

    private enum Key {
        static let displayMode = "displayMode"
        static let paceMode = "paceModeEnabled"
        static let warningPercent = "warningPercent"
        static let criticalPercent = "criticalPercent"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Key.displayMode) ?? "") ?? .money
        paceModeEnabled = defaults.object(forKey: Key.paceMode) as? Bool ?? true
        warningPercent = defaults.object(forKey: Key.warningPercent) as? Double ?? 60
        criticalPercent = defaults.object(forKey: Key.criticalPercent) as? Double ?? 85
    }

    var thresholds: GaugeThresholds {
        GaugeThresholds(
            warning: warningPercent / 100,
            critical: criticalPercent / 100,
            paceModeEnabled: paceModeEnabled,
            paceTolerance: GaugeThresholds.default.paceTolerance
        )
    }

    // MARK: - Launch at login
    //
    // Deliberately defaults to off: the app is installed to /Applications and launched
    // by hand, and silently adding a login item would be a surprise.

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("CursorGauge: couldn't change login item: \(error.localizedDescription)")
            }
        }
    }

    /// `SMAppService` only works from a real bundle in a real location, not from a
    /// `swift run` binary — hide the toggle rather than offer a control that silently fails.
    var canManageLoginItem: Bool {
        Bundle.main.bundleIdentifier != nil
    }
}
