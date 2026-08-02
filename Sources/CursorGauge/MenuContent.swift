import AppKit
import SwiftUI
import CursorGaugeCore

struct MenuContent: View {
    @Bindable var store: UsageStore
    @Bindable var preferences: Preferences

    /// The `showSettingsWindow:` selector that used to work is a no-op here; this is
    /// the supported route on macOS 14+.
    @Environment(\.openSettings) private var openSettingsWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let metrics = store.metrics, let snapshot = store.snapshot {
                Divider().padding(.vertical, 8)
                figures(metrics)
                if !snapshot.models.isEmpty {
                    Divider().padding(.vertical, 8)
                    models(snapshot)
                }
                Divider().padding(.vertical, 8)
                freshness(snapshot)
            }
            if case .failed(let message) = store.status {
                Divider().padding(.vertical, 8)
                problem(message)
            }
            Divider().padding(.vertical, 8)
            actions
        }
        .padding(12)
        .frame(width: 268)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if let metrics = store.metrics {
                Text(Format.money(cents: metrics.spentCents))
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .monospacedDigit()
                if let limit = metrics.limitDollars {
                    Text("of \(Format.money(dollars: limit))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let raw = metrics.rawFraction {
                    Text(Format.percent(raw))
                        .foregroundStyle(colour(for: metrics.level))
                        .monospacedDigit()
                }
            } else if case .failed = store.status {
                Text("Unavailable").font(.system(size: 18, weight: .medium))
                Spacer()
            } else {
                Text("Loading…").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { progressBar }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let metrics = store.metrics, let fraction = metrics.fraction {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(colour(for: metrics.level))
                        .frame(width: max(2, geometry.size.width * fraction))
                    // Where the calendar says you should be — the reference the pace
                    // warning is measured against.
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 1)
                        .offset(x: geometry.size.width * metrics.cycleElapsedFraction)
                        .opacity(0.7)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - Sections

    private func figures(_ metrics: UsageMetrics) -> some View {
        VStack(spacing: 5) {
            if let snapshot = store.snapshot {
                row("Today", Format.money(cents: snapshot.todayCents))
            }
            if let projected = metrics.projectedCents, let snapshot = store.snapshot {
                row(
                    "Projected",
                    "\(Format.money(cents: projected)) by \(Format.day(snapshot.cycleEnd))",
                    emphasis: metrics.isAheadOfPace ? colour(for: .warning) : nil
                )
            } else {
                row("Projected", "—", emphasis: nil)
            }
            row("Burn rate", "\(Format.money(cents: metrics.burnRateCentsPerDay)) / day")
            if metrics.isAheadOfPace {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right")
                    Text("Ahead of pace for this cycle")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(colour(for: .warning))
                .padding(.top, 2)
            }
        }
    }

    private func models(_ snapshot: UsageSnapshot) -> some View {
        VStack(spacing: 5) {
            ForEach(snapshot.models.prefix(3), id: \.model) { model in
                row(model.model, Format.money(cents: model.cents))
                Text("\(Format.tokens(model.inputTokens)) in · \(Format.tokens(model.outputTokens)) out · \(Format.tokens(model.cacheReadTokens)) cached")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func freshness(_ snapshot: UsageSnapshot) -> some View {
        VStack(spacing: 5) {
            row(
                "Last request",
                snapshot.lastActivity.map { Format.relative($0, now: Date()) } ?? "none today"
            )
            row(
                "Updated",
                store.lastUpdated.map { Format.relative($0, now: Date()) } ?? "never",
                emphasis: store.isStale ? colour(for: .warning) : nil
            )
            row("Checking", store.cadence.label)
        }
    }

    private func problem(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(colour(for: .warning))
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        VStack(spacing: 2) {
            MenuButton(title: "Refresh Now", key: "r", disabled: store.isRefreshing) {
                Task { await store.refresh() }
            }
            MenuButton(title: "Settings…", key: ",") {
                openSettings()
            }
            MenuButton(title: "Quit CursorGauge", key: "q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, -6)
    }

    // MARK: - Helpers

    private func row(_ label: String, _ value: String, emphasis: Color? = nil) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(emphasis ?? .primary)
                .monospacedDigit()
        }
        .font(.system(size: 12))
    }

    private func colour(for level: GaugeLevel) -> Color {
        switch level {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func openSettings() {
        // A menu-bar-only app is an accessory, so it has to activate itself or the
        // settings window opens behind whatever is in front.
        NSApp.activate(ignoringOtherApps: true)
        openSettingsWindow()
    }
}

/// `keyboardShortcut` has no optional overload, so applying it conditionally needs a
/// modifier wrapper rather than an `if` inside the view body.
private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}

/// A row that looks and behaves like a menu item inside a window-style menu bar extra,
/// which otherwise gives plain SwiftUI buttons with no hover feedback.
private struct MenuButton: View {
    let title: String
    /// The command-key equivalent. The displayed shortcut is derived from this, so the
    /// label can't drift out of sync with what the key actually does.
    var key: KeyEquivalent? = nil
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    private var shortcutLabel: String? {
        key.map { "⌘\($0.character.uppercased())" }
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcutLabel {
                    Text(shortcutLabel).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering && !disabled ? Color.accentColor.opacity(0.85) : .clear)
            )
            .foregroundStyle(isHovering && !disabled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { isHovering = $0 }
        .modifier(OptionalShortcut(key: key))
    }
}
