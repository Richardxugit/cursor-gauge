import Foundation

/// Renders a `UsageReport` as one self-contained HTML page.
///
/// No external assets, no scripts, no web fonts: the page has to survive being emailed as a
/// single file and opened offline, so everything it needs is inline. Hover detail is pure
/// CSS for the same reason.
///
/// Chart choices follow the project's data-visualisation rules and are deliberate:
///
/// - Magnitude across repos, tools, models and commands is a **ranked horizontal bar in one
///   hue**. Shading each bar by its own length would encode the same fact twice and burn
///   the only free channel.
/// - Cost per day and activity per day are **two stacked charts, never one chart with two
///   y-axes** — aligning two scales invents a correlation the data does not contain.
/// - Every bar carries its value as a direct label, so the page is a table with bars in it
///   and no figure depends on hovering to be read.
public enum ReportRenderer {
    public static func html(_ report: UsageReport) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Cursor usage — \(escape(Format.day(report.cycleStart))) to \(escape(Format.day(report.cycleEnd)))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <main class="page">
        \(header(report))
        \(headline(report))
        \(workspaceSection(report))
        \(modelSection(report))
        \(dailySection(report))
        \(sessionSection(report))
        \(toolSection(report))
        \(fileSection(report))
        \(promptSection(report))
        \(footer(report))
        </main>
        </body>
        </html>
        """
    }

    // MARK: - Header and headline

    private static func header(_ report: UsageReport) -> String {
        let window = "\(Format.day(report.cycleStart)) – \(Format.day(report.cycleEnd))"
        let generated = DateFormatter.reportStamp.string(from: report.generatedAt)
        return """
        <header class="head">
          <h1>Cursor usage</h1>
          <p class="sub">Billing cycle \(escape(window)) · generated \(escape(generated))</p>
          \(report.truncated ? banner("The events feed did not cover everything the billing API declared for this cycle. Figures below are a floor, not a total.") : "")
          \(activityNotice(report))
        </header>
        """
    }

    private static func activityNotice(_ report: UsageReport) -> String {
        let unavailable = report.unavailableActivitySources
        if !unavailable.isEmpty {
            let message: String
            switch (unavailable.contains(.gui), unavailable.contains(.cli)) {
            case (true, true):
                message = "Neither the editor's nor the CLI's activity store was readable — the local activity could not be read. Cost coverage is unaffected."
            case (true, false):
                message = "The editor activity store could not be read. Local activity is incomplete; cost coverage is unaffected."
            case (false, true):
                message = "The CLI activity store could not be read. Local activity is incomplete; cost coverage is unaffected."
            case (false, false):
                return ""
            }
            return banner(message)
        }
        guard !report.hasActivity else { return "" }
        return banner("Cursor's local stores recorded no activity in this cycle. This is a quiet cycle, not a read failure.")
    }

    private static func headline(_ report: UsageReport) -> String {
        let metrics = report.metrics
        let limit = metrics.limitDollars.map { Format.money(dollars: $0) } ?? "no limit"
        let ofLimit = metrics.rawFraction.map(Format.percent) ?? "n/a"
        let projected = metrics.projectedCents.map { Format.money(cents: $0) } ?? "too early"
        let daysLeft = max(Int(report.cycleEnd.timeIntervalSince(report.generatedAt) / 86_400), 0)

        // The status word carries the meaning; the colour only reinforces it. A reader who
        // cannot separate amber from grey still gets the same sentence.
        let (statusClass, statusWord) = switch metrics.level {
        case .critical: ("critical", "over threshold")
        case .warning: (metrics.isAheadOfPace ? "warning" : "warning", metrics.isAheadOfPace ? "ahead of pace" : "approaching limit")
        case .normal: ("good", metrics.isAheadOfPace ? "ahead of pace" : "on pace")
        }

        return """
        <section>
          <div class="tiles">
            \(tile(label: "Spent this cycle", value: Format.money(cents: metrics.spentCents), note: "of \(limit)"))
            \(tile(label: "Of limit", value: ofLimit, note: "\(Format.percent(metrics.cycleElapsedFraction)) of the cycle elapsed"))
            \(tile(label: "Projected", value: projected, note: "by \(Format.day(report.cycleEnd))"))
            \(tile(label: "Burn rate", value: Format.money(cents: metrics.burnRateCentsPerDay), note: "per day"))
            \(tile(label: "Days remaining", value: "\(daysLeft)", note: statusWord, noteClass: statusClass))
          </div>
          \(meter(report))
        </section>
        """
    }

    /// Spend against the limit, with the calendar's own position marked.
    ///
    /// On a $200 limit a healthy month barely moves the bar, so the pace marker is the part
    /// that actually informs: it shows where spending *should* be by today.
    private static func meter(_ report: UsageReport) -> String {
        guard let fraction = report.metrics.fraction else { return "" }
        let elapsed = report.metrics.cycleElapsedFraction
        return """
        <figure class="meter-figure">
          <div class="meter" role="img" aria-label="\(escape(Format.percent(report.metrics.rawFraction ?? 0))) of the limit spent, \(escape(Format.percent(elapsed))) of the cycle elapsed">
            <div class="meter-fill status-\(report.metrics.level.rawValue)" style="width:\(pct(fraction))"></div>
            <div class="meter-pace" style="left:\(pct(elapsed))"></div>
          </div>
          <figcaption>The vertical rule marks today's position in the cycle. Spending to the left of it is behind pace.</figcaption>
        </figure>
        """
    }

    // MARK: - Where the money went

    private static func workspaceSection(_ report: UsageReport) -> String {
        let residuals = [
            report.cloudCents > 0
                ? "<li><span class=\"res-label\">Cloud agents</span><span class=\"res-note\">\(report.cloudCount) chat\(report.cloudCount == 1 ? "" : "s") that ran without an editor, so Cursor keeps no local record of them</span><span class=\"res-value\">\(Format.money(cents: report.cloudCents))</span></li>"
                : "",
            report.unattributedCents > 0
                ? "<li><span class=\"res-label\">Unattributed</span><span class=\"res-note\">billed work whose chat is not in the local store</span><span class=\"res-value\">\(Format.money(cents: report.unattributedCents))</span></li>"
                : "",
            report.unbilledConversations > 0
                ? "<li><span class=\"res-label\">Free of charge</span><span class=\"res-note\">\(report.unbilledConversations) chat\(report.unbilledConversations == 1 ? "" : "s") did work that cost nothing — cached or included requests</span><span class=\"res-value\">\(Format.money(cents: 0))</span></li>"
                : "",
        ].filter { !$0.isEmpty }.joined()

        // The residual buckets describe cost, which always arrives, so they must survive an
        // unreadable local store. Gating this section on activity once hid cloud spend
        // entirely whenever Cursor's database could not be read.
        guard !report.workspaces.isEmpty || !residuals.isEmpty else { return "" }

        let rows = report.workspaces.map { repo in
            bar(
                label: repo.workspace,
                value: Format.money(cents: repo.cents),
                fraction: divide(repo.cents, report.workspaces.first?.cents),
                note: "\(repo.sessions) chat\(repo.sessions == 1 ? "" : "s") · \(count(repo.toolCalls)) tool calls · \(count(repo.prompts)) prompts"
            )
        }.joined()

        // Only worth a line when both front ends were actually used; on an editor-only
        // account it would be a row saying "100% of it, from the only place it could be".
        let cli = report.bySource[.cli]
        let gui = report.bySource[.gui]
        let split = (cli?.cents ?? 0) > 0 && (gui?.cents ?? 0) > 0
            ? """
              <p class="lede split">Cursor the editor \(Format.money(cents: gui?.cents ?? 0))
              across \(gui?.conversations ?? 0) chats · <code>cursor-agent</code> in a terminal
              \(Format.money(cents: cli?.cents ?? 0)) across \(cli?.conversations ?? 0).
              The two keep separate records and name their tools differently, so tool counts
              below are listed under each one's own vocabulary.</p>
              """
            : ""

        return """
        <section>
          <h2>Where the money went</h2>
          \(split)
          <p class="lede">Spend joined to the repository each chat was open in — the one question neither
          the billing API nor the local store can answer alone.</p>
          \(report.workspaces.isEmpty ? "<p class=\"empty\">No spend could be traced to a repository this cycle.</p>" : "<div class=\"bars\">\(rows)</div>")
          \(residuals.isEmpty ? "" : "<ul class=\"residuals\">\(residuals)</ul>")
        </section>
        """
    }

    private static func modelSection(_ report: UsageReport) -> String {
        guard !report.models.isEmpty else { return "" }
        let rows = report.models.map { model in
            bar(
                label: model.model,
                value: Format.money(cents: model.cents),
                fraction: divide(model.cents, report.models.first?.cents)
            )
        }.joined()
        return """
        <section>
          <h2>Models</h2>
          <p class="lede">\(escape(ModelName.auto)) covers requests Cursor billed under its Auto setting without
          naming the model it routed to — that choice is not recorded anywhere, locally or in the API.</p>
          <div class="bars">\(rows)</div>
        </section>
        """
    }

    // MARK: - Daily rhythm

    /// Two charts, deliberately.
    ///
    /// Cost is in cents and activity is a count. Putting them on one plot with two y-axes
    /// would let the reader infer a correlation from where the scales happen to line up.
    private static func dailySection(_ report: UsageReport) -> String {
        guard !report.daily.isEmpty else { return "" }
        let peakCost = report.daily.map(\.cents).max() ?? 0
        let peakWork = report.daily.map { Double($0.toolCalls) }.max() ?? 0

        func chart(_ title: String, _ caption: String, series: (DayLine) -> (Double, String)) -> String {
            let columns = report.daily.map { day -> String in
                let (fraction, tip) = series(day)
                return """
                <div class="col"><div class="col-bar" style="height:\(pct(fraction))"></div>\
                <span class="tip">\(escape(tip))</span></div>
                """
            }.joined()
            let labels = axisLabels(report.daily.map(\.day))
            return """
            <figure class="chart">
              <figcaption class="chart-title">\(escape(title))<span class="chart-peak">\(escape(caption))</span></figcaption>
              <div class="cols">\(columns)</div>
              <div class="axis">\(labels)</div>
            </figure>
            """
        }

        return """
        <section>
          <h2>Day by day</h2>
          <p class="lede">Cost and effort are different units, so they get one chart each. Reading them
          side by side shows the days where a lot of work was cheap, or a little was expensive.</p>
          \(chart("Spend", "peak \(Format.money(cents: peakCost))") { day in
              (divide(day.cents, peakCost), "\(Format.day(day.day)) · \(Format.money(cents: day.cents))")
          })
          \(chart("Tool calls", "peak \(count(Int(peakWork)))") { day in
              (divide(Double(day.toolCalls), peakWork),
               "\(Format.day(day.day)) · \(plural(day.toolCalls, "tool call")) · \(plural(day.prompts, "prompt"))")
          })
        </section>
        """
    }

    /// First, middle and last day only — a label under every column is unreadable and unread.
    private static func axisLabels(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let middle = days[days.count / 2]
        let picked = days.count < 3 ? [first] : [first, middle, last]
        return picked.map { "<span>\(escape(Format.day($0)))</span>" }.joined()
    }

    // MARK: - Sessions

    private static func sessionSection(_ report: UsageReport) -> String {
        guard !report.sessions.isEmpty else { return "" }
        let rows = report.sessions.prefix(20).map { session in
            """
            <tr>
              <td class="name">\(escape(session.name ?? "—"))\(session.isCloud ? " <span class=\"chip\">cloud</span>" : "")</td>
              <td>\(escape(session.workspace ?? "—"))</td>
              <td class="num">\(Format.money(cents: session.cents))</td>
              <td class="num">\(count(session.requests))</td>
              <td class="num">\(session.prompts > 0 ? count(session.prompts) : "—")</td>
              <td class="num">\(session.toolCalls > 0 ? count(session.toolCalls) : "—")</td>
            </tr>
            """
        }.joined()
        let hidden = report.sessions.count - min(report.sessions.count, 20)
        return """
        <section>
          <h2>Chats</h2>
          <p class="lede">Cost rolls a chat's subagents into it, so the activity beside it does too.</p>
          <div class="scroll">
            <table>
              <thead><tr><th>Chat</th><th>Repository</th><th class="num">Cost</th>
                <th class="num">Requests</th><th class="num">Prompts</th><th class="num">Tools</th></tr></thead>
              <tbody>\(rows)</tbody>
            </table>
          </div>
          \(hidden > 0 ? "<p class=\"empty\">\(hidden) further chat\(hidden == 1 ? "" : "s") not shown.</p>" : "")
        </section>
        """
    }

    // MARK: - How the work ran

    private static func toolSection(_ report: UsageReport) -> String {
        guard !report.tools.isEmpty else { return "" }
        let peak = report.tools.first?.calls ?? 0
        let rows = report.tools.prefix(18).map { tool in
            var notes: [String] = []
            if let server = tool.server { notes.append("via \(server)") }
            if tool.errors > 0 { notes.append("\(count(tool.errors)) failed") }
            if tool.rejected > 0 { notes.append("\(count(tool.rejected)) rejected") }
            if tool.cancelled > 0 { notes.append("\(count(tool.cancelled)) cancelled") }
            return bar(
                label: tool.name,
                value: count(tool.calls),
                fraction: divide(Double(tool.calls), Double(peak)),
                note: notes.joined(separator: " · ")
            )
        }.joined()

        let totals = report.tools.reduce(into: (calls: 0, errors: 0, rejected: 0)) {
            $0.calls += $1.calls; $0.errors += $1.errors; $0.rejected += $1.rejected
        }
        let mcp = report.tools.filter { $0.server != nil }
        let integrations = Dictionary(grouping: mcp, by: { $0.server ?? "" })
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.calls }) }
            .sorted { ($0.1, $1.0) > ($1.1, $0.0) }
            .map { "<li><span>\(escape($0.0))</span><span class=\"res-value\">\(count($0.1))</span></li>" }
            .joined()

        return """
        <section>
          <h2>How the work ran</h2>
          <div class="tiles">
            \(tile(label: "Tool calls", value: count(totals.calls), note: "in this cycle"))
            \(tile(label: "Failed", value: count(totals.errors), note: rate(totals.errors, of: totals.calls)))
            \(tile(label: "Edits rejected", value: count(totals.rejected), note: "changes turned down"))
            \(tile(label: "Distinct tools", value: count(report.tools.count), note: "\(count(mcp.count)) from integrations"))
          </div>
          <div class="bars">\(rows)</div>
          \(integrations.isEmpty ? "" : """
          <h3>Integrations</h3>
          <ul class="residuals compact">\(integrations)</ul>
          """)
        </section>
        """
    }

    private static func fileSection(_ report: UsageReport) -> String {
        let files = report.files.prefix(12)
        guard !files.isEmpty else { return "" }
        let peak = files.first?.operations ?? 0
        let rows = files.map { file -> String in
            let readWidth = divide(Double(file.reads), Double(peak))
            let editWidth = divide(Double(file.edits), Double(peak))
            return """
            <div class="bar-row">
              <span class="bar-label">\(escape(file.ext))</span>
              <span class="bar-track">
                <span class="bar-fill s1" style="width:\(pct(readWidth))"></span>
                <span class="bar-fill s2" style="width:\(pct(editWidth))"></span>
              </span>
              <span class="bar-value">\(count(file.operations))</span>
              <span class="bar-note">\(count(file.reads)) read · \(count(file.edits)) edited</span>
            </div>
            """
        }.joined()
        return """
        <section>
          <h2>What was touched</h2>
          <p class="lede">File operations by type. Only paths were read out of the store — never contents.</p>
          <ul class="legend">
            <li><span class="key s1"></span>Read</li>
            <li><span class="key s2"></span>Edited</li>
          </ul>
          <div class="bars stacked">\(rows)</div>
        </section>
        """
    }

    private static func promptSection(_ report: UsageReport) -> String {
        let prompts = report.prompts
        guard prompts.count > 0 else { return "" }
        let peak = prompts.commands.first?.count ?? 0
        let rows = prompts.commands.prefix(12).map { command in
            bar(
                label: command.command,
                value: count(command.count),
                fraction: divide(Double(command.count), Double(peak))
            )
        }.joined()
        return """
        <section>
          <h2>How you asked</h2>
          <div class="tiles">
            \(tile(label: "Prompts", value: count(prompts.count), note: "you wrote this cycle"))
            \(tile(label: "Typical length", value: "\(count(prompts.medianChars)) chars", note: "median, so one long paste cannot skew it"))
            \(tile(label: "Longest", value: "\(count(prompts.longestChars)) chars", note: "single prompt"))
            \(tile(label: "Commands used", value: count(prompts.commands.reduce(0) { $0 + $1.count }), note: "\(count(prompts.commands.count)) distinct"))
          </div>
          \(rows.isEmpty ? "" : """
          <h3>Commands</h3>
          <div class="bars">\(rows)</div>
          """)
        </section>
        """
    }

    // MARK: - Footer

    private static func footer(_ report: UsageReport) -> String {
        // The raw sum, so the two figures in this sentence cannot disagree by a rounding
        // penny and make a correct breakdown look broken.
        let parts = report.attributedCents
        let verdict = report.reconciles
            ? "adds up to the cycle total"
            : "DOES NOT add up to the cycle total — treat the breakdown above as unreliable"
        return """
        <footer>
          <p class="reconcile \(report.reconciles ? "ok" : "bad")">
            Repositories, cloud agents and unattributed spend total
            \(Format.money(cents: parts)) against a cycle total of
            \(Format.money(cents: report.totalCents)) — \(verdict).
          </p>
          <p class="fine">
            Cost comes from Cursor's billing API; everything else from Cursor's own local
            database, read without modifying it. No prompt text, file contents, or other team
            members' details reach this page — but chat titles and repository names do, and a
            title can carry a ticket number, so treat this file the way you would treat your
            branch names. Activity is recorded only on this machine, so a cloud agent appears
            as cost with nothing behind it.
          </p>
        </footer>
        """
    }

    // MARK: - Components

    private static func tile(
        label: String, value: String, note: String, noteClass: String = ""
    ) -> String {
        """
        <div class="tile">
          <span class="tile-label">\(escape(label))</span>
          <span class="tile-value">\(escape(value))</span>
          <span class="tile-note \(noteClass.isEmpty ? "" : "status-text-\(noteClass)")">\(escape(note))</span>
        </div>
        """
    }

    /// One ranked row. The value is always written out, so nothing here needs a hover to read.
    private static func bar(
        label: String, value: String, fraction: Double, note: String = ""
    ) -> String {
        // A long tool name ellipsizes in its column; `title` keeps the full one reachable.
        """
        <div class="bar-row">
          <span class="bar-label" title="\(escape(label))">\(escape(label))</span>
          <span class="bar-track"><span class="bar-fill s1" style="width:\(pct(fraction))"></span></span>
          <span class="bar-value">\(escape(value))</span>
          \(note.isEmpty ? "" : "<span class=\"bar-note\">\(escape(note))</span>")
        </div>
        """
    }

    private static func banner(_ text: String) -> String {
        "<p class=\"banner\">\(escape(text))</p>"
    }

    // MARK: - Helpers

    /// Guards the zero-denominator case so an empty cycle renders rather than producing `nan%`.
    private static func divide(_ value: Double, _ by: Double?) -> Double {
        guard let by, by > 0 else { return 0 }
        return min(max(value / by, 0), 1)
    }

    private static func pct(_ fraction: Double) -> String {
        String(format: "%.2f%%", fraction * 100)
    }

    private static func rate(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "none" }
        return Format.percent(Double(part) / Double(whole)) + " of calls"
    }

    private static func count(_ value: Int) -> String {
        NumberFormatter.grouped.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Only regular plurals appear here, so an `s` is enough.
    private static func plural(_ value: Int, _ noun: String) -> String {
        "\(count(value)) \(noun)\(value == 1 ? "" : "s")"
    }

    /// Chat names and repository paths are user data and reach this page verbatim, so they
    /// are escaped rather than trusted. `&` first, or the other replacements get re-encoded.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

// MARK: - Stylesheet

private extension ReportRenderer {
    /// Palette and chrome come from the project's data-visualisation reference. The two
    /// categorical slots used here — blue and orange — were run through the palette
    /// validator against both surfaces: worst-pair colour-vision separation ΔE 24.7 light
    /// and 26.8 dark, against a target of 8.
    ///
    /// Light values live on bare `:root`; the dark ones are declared twice, under the OS
    /// media query and under an explicit `[data-theme]`, so a stamped theme wins either way.
    static var stylesheet: String {
        """
        :root {
          color-scheme: light;
          --surface: #fcfcfb;
          --plane: #f9f9f7;
          --ink: #0b0b0b;
          --ink-2: #52514e;
          --muted: #898781;
          --grid: #e1e0d9;
          --axis: #c3c2b7;
          --hairline: rgba(11, 11, 11, 0.10);
          --s1: #2a78d6;
          --s2: #eb6834;
          --good: #0ca30c;
          --warning: #fab219;
          --critical: #d03b3b;
          --good-text: #006300;
        }
        @media (prefers-color-scheme: dark) {
          :root:where(:not([data-theme="light"])) {
            color-scheme: dark;
            --surface: #1a1a19;
            --plane: #0d0d0d;
            --ink: #ffffff;
            --ink-2: #c3c2b7;
            --grid: #2c2c2a;
            --axis: #383835;
            --hairline: rgba(255, 255, 255, 0.10);
            --s1: #3987e5;
            --s2: #d95926;
            --good-text: #0ca30c;
          }
        }
        :root[data-theme="dark"] {
          color-scheme: dark;
          --surface: #1a1a19;
          --plane: #0d0d0d;
          --ink: #ffffff;
          --ink-2: #c3c2b7;
          --grid: #2c2c2a;
          --axis: #383835;
          --hairline: rgba(255, 255, 255, 0.10);
          --s1: #3987e5;
          --s2: #d95926;
          --good-text: #0ca30c;
        }

        * { box-sizing: border-box; }
        body {
          margin: 0;
          background: var(--plane);
          color: var(--ink);
          font: 15px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        .page { max-width: 1040px; margin: 0 auto; padding: 40px 24px 64px; }

        h1 { font-size: 26px; font-weight: 650; letter-spacing: -0.01em; margin: 0; }
        h2 { font-size: 18px; font-weight: 650; margin: 0 0 4px; letter-spacing: -0.005em; }
        h3 { font-size: 13px; font-weight: 600; color: var(--ink-2); margin: 24px 0 8px;
             text-transform: uppercase; letter-spacing: 0.06em; }
        .sub { color: var(--ink-2); margin: 6px 0 0; font-size: 14px; }
        .lede { color: var(--ink-2); margin: 0 0 20px; font-size: 14px; max-width: 68ch; }
        .empty { color: var(--muted); font-size: 14px; margin: 12px 0 0; }
        .head { margin-bottom: 36px; }
        section {
          background: var(--surface);
          border: 1px solid var(--hairline);
          border-radius: 12px;
          padding: 24px;
          margin-bottom: 20px;
        }

        .banner {
          margin: 16px 0 0; padding: 10px 14px;
          border-left: 3px solid var(--warning);
          background: color-mix(in srgb, var(--warning) 8%, var(--surface));
          border-radius: 4px; font-size: 14px; color: var(--ink-2);
        }

        /* Stat tiles: where the number IS the story, there is no chart. */
        .tiles {
          display: grid; gap: 1px; background: var(--hairline);
          grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
          border: 1px solid var(--hairline); border-radius: 10px; overflow: hidden;
          margin-bottom: 24px;
        }
        .tile { background: var(--surface); padding: 16px 18px; display: flex; flex-direction: column; gap: 3px; }
        .tile-label { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; }
        .tile-value { font-size: 25px; font-weight: 600; letter-spacing: -0.02em; line-height: 1.15; }
        .tile-note { font-size: 12.5px; color: var(--ink-2); }
        .status-text-good { color: var(--good-text); font-weight: 550; }
        .status-text-warning { color: var(--ink-2); font-weight: 550; }
        .status-text-critical { color: var(--critical); font-weight: 550; }

        /* Spend against the limit, with today's position in the cycle marked. */
        .meter-figure { margin: 0; }
        .meter {
          position: relative; height: 8px; border-radius: 4px;
          background: var(--grid); overflow: visible;
        }
        .meter-fill { height: 100%; border-radius: 4px; }
        .meter-fill.status-normal { background: var(--s1); }
        .meter-fill.status-warning { background: var(--warning); }
        .meter-fill.status-critical { background: var(--critical); }
        .meter-pace { position: absolute; top: -4px; bottom: -4px; width: 2px; background: var(--ink); opacity: 0.55; }
        figcaption { font-size: 12.5px; color: var(--muted); margin-top: 10px; }

        /* Ranked bars. One hue: shading by length would encode the same fact twice. */
        .bars { display: flex; flex-direction: column; gap: 14px; }
        .bar-row {
          display: grid; align-items: center; gap: 4px 12px;
          grid-template-columns: minmax(90px, 240px) 1fr auto;
        }
        .bar-label {
          font-size: 13.5px; color: var(--ink); overflow: hidden;
          text-overflow: ellipsis; white-space: nowrap;
        }
        .bar-track { display: flex; gap: 2px; height: 9px; background: transparent; }
        .bar-fill { height: 100%; border-radius: 0 4px 4px 0; min-width: 2px; }
        .bar-fill.s1 { background: var(--s1); }
        .bar-fill.s2 { background: var(--s2); }
        .bar-row:first-child .bar-fill { border-radius: 0 4px 4px 0; }
        .bar-value { font-size: 13.5px; font-weight: 550; font-variant-numeric: tabular-nums; text-align: right; }
        .bar-note { grid-column: 2 / -1; font-size: 12px; color: var(--muted); }

        .legend { display: flex; gap: 18px; list-style: none; padding: 0; margin: 0 0 18px; font-size: 13px; color: var(--ink-2); }
        .legend li { display: flex; align-items: center; gap: 7px; }
        .key { width: 11px; height: 11px; border-radius: 3px; display: inline-block; }
        .key.s1 { background: var(--s1); }
        .key.s2 { background: var(--s2); }

        /* Two charts, never two y-axes on one plot. */
        .chart { margin: 0 0 28px; }
        .chart-title { font-size: 13px; font-weight: 600; color: var(--ink-2); display: flex;
                       justify-content: space-between; margin-bottom: 10px; }
        .chart-peak { color: var(--muted); font-weight: 400; }
        .cols {
          display: flex; align-items: flex-end; gap: 2px; height: 96px;
          border-bottom: 1px solid var(--axis);
        }
        .col { position: relative; flex: 1 1 0; height: 100%; display: flex; align-items: flex-end; min-width: 3px; }
        .col-bar { width: 100%; background: var(--s1); border-radius: 3px 3px 0 0; min-height: 1px; }
        .col:hover .col-bar { background: var(--ink); }
        /* Hover enhances; it never gates. Every total is also written out above. */
        .tip {
          position: absolute; bottom: calc(100% + 8px); left: 50%; transform: translateX(-50%);
          background: var(--ink); color: var(--surface); font-size: 12px; white-space: nowrap;
          padding: 5px 9px; border-radius: 5px; opacity: 0; pointer-events: none;
          transition: opacity 90ms ease; z-index: 5;
        }
        .col:hover .tip { opacity: 1; }
        .axis { display: flex; justify-content: space-between; margin-top: 8px;
                font-size: 11.5px; color: var(--muted); font-variant-numeric: tabular-nums; }

        .scroll { overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; font-size: 13.5px; }
        th, td { text-align: left; padding: 9px 12px 9px 0; border-bottom: 1px solid var(--grid); }
        th { font-size: 11.5px; text-transform: uppercase; letter-spacing: 0.05em;
             color: var(--muted); font-weight: 600; }
        td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
        td.name { max-width: 320px; }
        tbody tr:last-child td { border-bottom: none; }
        .chip {
          font-size: 10.5px; padding: 1px 6px; border-radius: 4px; vertical-align: 1px;
          background: color-mix(in srgb, var(--s1) 16%, var(--surface)); color: var(--ink-2);
        }

        .residuals { list-style: none; padding: 0; margin: 24px 0 0; border-top: 1px solid var(--grid); }
        .residuals li {
          display: grid; grid-template-columns: minmax(90px, 200px) 1fr auto;
          gap: 4px 12px; padding: 11px 0; border-bottom: 1px solid var(--grid); align-items: baseline;
        }
        .residuals li:last-child { border-bottom: none; }
        .residuals.compact li { grid-template-columns: 1fr auto; }
        .res-label { font-size: 13.5px; }
        .res-note { font-size: 12px; color: var(--muted); }
        .res-value { font-size: 13.5px; font-weight: 550; font-variant-numeric: tabular-nums; text-align: right; }

        footer { margin-top: 28px; }
        .reconcile { font-size: 13px; padding: 12px 16px; border-radius: 8px; margin: 0 0 12px; }
        .reconcile.ok { color: var(--ink-2); background: var(--surface); border: 1px solid var(--hairline); }
        .reconcile.bad { color: var(--critical); background: color-mix(in srgb, var(--critical) 8%, var(--surface));
                         border: 1px solid var(--critical); font-weight: 550; }
        .fine { font-size: 12.5px; color: var(--muted); max-width: 76ch; margin: 0; }
        .split { border-left: 2px solid var(--s1); padding-left: 12px; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em; }

        @media (max-width: 620px) {
          .page { padding: 24px 16px 48px; }
          .bar-row, .residuals li { grid-template-columns: 1fr auto; }
          .bar-track { grid-column: 1 / -1; order: 3; }
          .bar-note { grid-column: 1 / -1; order: 4; }
        }
        """
    }
}

private extension DateFormatter {
    static let reportStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter
    }()
}

private extension NumberFormatter {
    static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
