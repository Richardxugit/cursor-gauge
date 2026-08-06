import AppKit
import SwiftUI
import CursorGaugeCore

struct MenuContent: View {
    @Bindable var store: UsageStore
    @Bindable var preferences: Preferences

    /// The `showSettingsWindow:` selector that used to work is a no-op here; this is
    /// the supported route on macOS 14+.
    @Environment(\.openSettings) private var openSettingsWindow

    /// Expansion is view state, not model state: it resets when the menu closes, which is
    /// what you want from a menu.
    @State private var expandedSessions: Set<String> = []
    /// Sessions whose full subagent list is showing.
    @State private var expandedChildren: Set<String> = []
    @State private var showingAllSessions = false
    @State private var showingModels = false

    /// Five keeps the menu a fixed height on a normal cycle; the rest is one click away.
    private static let sessionRowLimit = 5
    /// Three inside an already-nested list, where every row is indented and secondary.
    private static let subagentRowLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let metrics = store.metrics, let snapshot = store.snapshot {
                Divider().padding(.vertical, 8)
                figures(metrics)
                if !snapshot.sessions.ranked.isEmpty || snapshot.sessions.unnamedCents > 0 {
                    Divider().padding(.vertical, 8)
                    sessions(snapshot)
                }
                if !snapshot.sessions.models.isEmpty {
                    Divider().padding(.vertical, 8)
                    modelTotals(snapshot.sessions.models)
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
            // "Estimated total", not "Projected": this is a forecast of the end-of-cycle
            // total including what's already spent, and "projected" reads as the balance
            // remaining — which is the opposite number.
            if let projected = metrics.projectedCents, let snapshot = store.snapshot {
                row(
                    "Estimated total",
                    "\(Format.money(cents: projected)) by \(Format.day(snapshot.cycleEnd))",
                    emphasis: metrics.isAheadOfPace ? colour(for: .warning) : nil
                )
            } else {
                row("Estimated total", "—", emphasis: nil)
            }
            // No burn-rate row: it is this figure divided by the cycle length, so the two
            // carried one fact between them.
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

    // MARK: - Sessions

    /// Where the money went, by chat, with subagent runs rolled into the chat that
    /// spawned them.
    private func sessions(_ snapshot: UsageSnapshot) -> some View {
        let breakdown = snapshot.sessions
        let display = breakdown.display(limit: showingAllSessions ? .max : Self.sessionRowLimit)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("TOP SESSIONS THIS CYCLE")
                if snapshot.sessionsTruncated {
                    // Say so rather than quietly under-report a very heavy cycle.
                    Text("· partial").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.4)

            ForEach(display.rows) { node in
                sessionRow(node)
                if expandedSessions.contains(node.id) {
                    subagents(of: node)
                }
            }

            if display.hasMore {
                if showingAllSessions {
                    // Everything nameable is now listed, so what is left cannot be named:
                    // no local record exists for these chats on this Mac.
                    row("Unnamed sessions (\(display.hiddenCount))", Format.money(cents: display.hiddenCents))
                } else {
                    disclosure(
                        "Show \(display.hiddenCount) more",
                        value: Format.money(cents: display.hiddenCents)
                    ) { showingAllSessions = true }
                }
            }
            if showingAllSessions {
                disclosure("Show less", value: nil) { showingAllSessions = false }
            }
        }
    }

    /// Cycle-wide spend by model, collapsed to a single row until asked for.
    ///
    /// This is the counterpart to the per-session split: that one says which model made
    /// *this job* expensive, this one says where the month went overall. Collapsed by
    /// default so it costs one row when you aren't asking.
    @ViewBuilder
    private func modelTotals(_ models: [ModelSpend]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                showingModels.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showingModels ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 8)
                    Text("MODELS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .kerning(0.4)
                    Spacer(minLength: 8)
                    Text(Format.money(cents: models.reduce(0) { $0 + $1.cents }))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingModels {
                ForEach(models) { spend in
                    HStack {
                        Text(spend.model)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Format.money(cents: spend.cents)).monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .padding(.leading, 12)
                }
            }
        }
    }

    /// Subagents get the same treatment as the top-level list: the priciest few, and the
    /// rest one click away. One chat spawned fifteen, which is a lot of menu.
    @ViewBuilder
    private func subagents(of node: SessionNode) -> some View {
        let showAll = expandedChildren.contains(node.id)
        let display = node.childDisplay(limit: showAll ? .max : Self.subagentRowLimit)

        ForEach(display.rows) { child in
            HStack {
                Text(child.name ?? "Unnamed")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Format.money(cents: child.rolledCents)).monospacedDigit()
            }
            .font(.system(size: 11))
            .padding(.leading, 18)
        }
        if display.hasMore {
            subagentDisclosure(
                "Show \(display.hiddenCount) more",
                value: Format.money(cents: display.hiddenCents)
            ) { expandedChildren.insert(node.id) }
        } else if showAll && !node.children.isEmpty {
            subagentDisclosure("Show less", value: nil) { expandedChildren.remove(node.id) }
        }
    }

    private func subagentDisclosure(
        _ title: String, value: String?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if let value { Text(value).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .font(.system(size: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 18)
    }

    private func sessionRow(_ node: SessionNode) -> some View {
        let canExpand = !node.children.isEmpty
        let isOpen = expandedSessions.contains(node.id)
        return Button {
            guard canExpand else { return }
            if isOpen { expandedSessions.remove(node.id) } else { expandedSessions.insert(node.id) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 8)
                    .opacity(canExpand ? 1 : 0)
                Text(node.name ?? "Unnamed session")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Format.money(cents: node.rolledCents)).monospacedDigit()
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func disclosure(_ title: String, value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if let value { Text(value).foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
