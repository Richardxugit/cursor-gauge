import SwiftUI
import CursorGaugeCore

struct SettingsView: View {
    @Bindable var store: UsageStore
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $preferences.displayMode) {
                    ForEach(Preferences.DisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section("Warnings") {
                LabeledContent("Amber above") {
                    Stepper(
                        "\(Int(preferences.warningPercent))% of limit",
                        value: $preferences.warningPercent,
                        in: 5...100, step: 5
                    )
                }
                LabeledContent("Red above") {
                    Stepper(
                        "\(Int(preferences.criticalPercent))% of limit",
                        value: $preferences.criticalPercent,
                        in: 5...100, step: 5
                    )
                }
                Toggle("Warn when spending outpaces the calendar", isOn: $preferences.paceModeEnabled)
                Text("On a large limit the ring barely moves, so pace is usually the first useful signal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if preferences.canManageLoginItem {
                Section("Startup") {
                    Toggle("Open at login", isOn: Binding(
                        get: { preferences.launchAtLogin },
                        set: { preferences.launchAtLogin = $0 }
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: preferences.warningPercent) { syncThresholds() }
        .onChange(of: preferences.criticalPercent) { syncThresholds() }
        .onChange(of: preferences.paceModeEnabled) { syncThresholds() }
    }

    /// Threshold edits must recolour the existing reading immediately — waiting for the
    /// next poll makes the control feel broken.
    private func syncThresholds() {
        store.thresholds = preferences.thresholds
    }
}
