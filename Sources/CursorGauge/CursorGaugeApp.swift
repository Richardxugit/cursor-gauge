import AppKit
import SwiftUI
import CursorGaugeCore

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--dry-run") {
            DryRun.run()
        }
        if let index = arguments.firstIndex(of: "--report") {
            // The path is optional, and a following flag is not one.
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            ReportCommand.run(path: next?.hasPrefix("-") == false ? next : nil)
        }
        if let index = arguments.firstIndex(of: "--emit-iconset"), index + 1 < arguments.count {
            IconGenerator.run(directory: arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "--emit-preview"), index + 1 < arguments.count {
            PreviewRenderer.run(path: arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "--design-lab"), index + 1 < arguments.count {
            DesignLab.run(path: arguments[index + 1])
        }
        CursorGaugeApp.main()
    }
}

struct CursorGaugeApp: App {
    @State private var store: UsageStore
    @State private var preferences: Preferences

    init() {
        let preferences = Preferences()
        let credentials = TokenStore()
        let store = UsageStore(credentials: credentials, thresholds: preferences.thresholds)
        _preferences = State(initialValue: preferences)
        _store = State(initialValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store, preferences: preferences)
        } label: {
            Image(nsImage: labelImage)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store, preferences: preferences)
        }
    }

    private var labelImage: NSImage {
        guard let metrics = store.metrics else { return GaugeIcon.problemImage() }
        let text: String?
        switch preferences.displayMode {
        case .money: text = Format.money(cents: metrics.spentCents)
        case .percent: text = metrics.rawFraction.map(Format.percent)
        case .iconOnly: text = nil
        }
        return GaugeIcon.menuBarImage(
            fraction: metrics.fraction,
            level: metrics.level,
            text: text,
            dimmed: store.isStale
        )
    }
}
