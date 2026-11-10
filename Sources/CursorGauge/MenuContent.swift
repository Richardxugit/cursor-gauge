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
    /// The report makes its own network call, so it gets its own in-flight flag rather than
    /// borrowing the store's — a poll and a report can run at once without disabling each other.
    @State private var isBuildingReport = false
    @State private var reportError: String?

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
            if let reportError {
                Divider().padding(.vertical, 8)
                problem("Report failed — \(reportError)")
            }
            Divider().padding(.vertical, 8)
            actions
        }
        .padding(12)
        .frame(width: 268)
        .onAppear {
            store.setMenuOpen(true)
            Task { await store.refresh() }
        }
        .onDisappear {
            store.setMenuOpen(false)
        }
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

            // Cloud agents run on Cursor's servers, so their chats usually never reach
            // this Mac and cannot be named. "Ran in the cloud" is worth saying where
            // "unnamed" says nothing, so they get their own row rather than the bucket.
            if breakdown.cloudCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "cloud")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 8)
                    Text("Cloud agents (\(breakdown.cloudCount))")
                    Spacer(minLength: 8)
                    Text(Format.money(cents: breakdown.cloudCents)).monospacedDigit()
                }
                .font(.system(size: 12))
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
                if node.isCloud {
                    // Where the work ran is part of what the row costs you: a cloud agent
                    // bills while you are not at the machine.
                    Image(systemName: "cloud")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help("Ran as a cloud agent")
                }
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
            // The report makes its own network call and scans the local store, so it takes a
            // few seconds. The title changes too: a spinner says "something is happening",
            // the wording says what.
            MenuButton(
                title: isBuildingReport ? "Building report…" : "Usage Report…",
                key: "e", busy: isBuildingReport
            ) {
                buildReport()
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

    /// Builds the report off the main actor and hands it to the browser.
    ///
    /// It fetches its own snapshot rather than reusing the store's, so the report is never a
    /// stale reading — and a failure here is reported in the menu instead of being swallowed,
    /// since a menu item that silently does nothing is worse than one that says why.
    private func buildReport() {
        // Hit testing stops a second click, but ⌘E bypasses that, so re-entry is refused
        // here rather than relying on the view to be the only guard.
        guard !isBuildingReport else { return }
        isBuildingReport = true
        reportError = nil
        Task {
            defer { isBuildingReport = false }
            do {
                let written = try await ReportCommand.write(
                    to: ReportCommand.defaultDestination(),
                    preferredTeamID: preferences.selectedTeamID
                )
                if !ReportCommand.open(written) {
                    reportError = "The report was written to \(written.path) but could not be opened."
                }
            } catch {
                reportError = (error as? APIError)?.description
                    ?? (error as? TokenError)?.description
                    ?? error.localizedDescription
            }
        }
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
/// Not private, so `--emit-menu-preview` can render it. The menu bar can't be screenshotted
/// from a terminal, and the busy state is exactly the kind of thing that compiles and still
/// looks wrong.
struct MenuButton: View {
    let title: String
    /// The command-key equivalent. The displayed shortcut is derived from this, so the
    /// label can't drift out of sync with what the key actually does.
    var key: KeyEquivalent? = nil
    var disabled: Bool = false
    /// Work is under way: show a spinner and refuse further clicks, but stay at full
    /// opacity. Dimming is how this row says "unavailable"; a dimmed row with no spinner is
    /// exactly what made the report button look stuck rather than busy.
    var busy: Bool = false
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
                // One fixed-height slot for both states, so the row cannot change height
                // when the spinner replaces the shortcut and shift the menu under the cursor.
                ZStack {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                    } else if let shortcutLabel {
                        Text(shortcutLabel).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 22, height: 14)
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
        // `disabled` only for genuinely unavailable, because SwiftUI dims a disabled label
        // itself — which is what made a busy row indistinguishable from a dead one. Busy
        // refuses the click through hit testing instead and keeps its text at full strength.
        .disabled(disabled)
        .allowsHitTesting(!busy)
        .opacity(disabled ? 0.5 : 1)
        .onHover { isHovering = $0 }
        .modifier(OptionalShortcut(key: key))
    }
}
