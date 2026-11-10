import Foundation

/// A repository key that cannot confuse two different directories that share a basename,
/// nor a pathless record with a path-carrying one.
private enum WorkspaceIdentity: Hashable {
    case path(String)
    case name(String)
}

/// What one repository cost, and what was done inside it.
public struct WorkspaceSpend: Equatable, Identifiable {
    /// The repo's directory name, e.g. `ko-services`.
    public let workspace: String
    /// Full path of the repo directory when the local record carried one.
    public let workspacePath: String?
    public let cents: Double
    /// Distinct chats that billed against this repo.
    public let sessions: Int
    public let prompts: Int
    public let toolCalls: Int
    /// Lifetime lines for the chats involved — see `ConversationActivity`.
    public let linesAdded: Int

    public var id: String { workspacePath ?? "name:\(workspace)" }
}

/// One chat, costed and described.
public struct SessionLine: Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let workspace: String?
    /// The whole piece of work: this chat plus its subagents.
    public let cents: Double
    public let requests: Int
    public let prompts: Int
    public let toolCalls: Int
    public let isCloud: Bool
}

/// What one conversation cost, flat.
public struct ConversationCost: Equatable, Identifiable {
    public let id: String
    public let name: String?
    /// This chat's own requests only — subagents are their own entries here, unlike in
    /// `SessionLine`, so the ledger sums to the cycle without double counting.
    public let cents: Double
    public let requests: Int
    public let isCloud: Bool
}

/// A day of the cycle, with both halves on it.
public struct DayLine: Equatable, Identifiable {
    public let day: Date
    public let cents: Double
    public let prompts: Int
    public let toolCalls: Int

    public var id: Date { day }
}

/// A cycle's spend, explained.
///
/// Built by joining the billing feed to Cursor's local store on the conversation id. The
/// two halves are independent: cost always arrives, activity is best-effort. Everything
/// here is derived — `build` is a pure function of its inputs, so the whole report can be
/// exercised without a network or a database.
public struct UsageReport {
    public let generatedAt: Date
    public let cycleStart: Date
    public let cycleEnd: Date
    public let metrics: UsageMetrics
    /// Whether the events feed served fewer rows than the billing API declared, in which
    /// case the cycle is only partly covered.
    public let truncated: Bool

    /// Ranked by cost. Residual spend is deliberately *not* in here — see the three
    /// buckets below, which exist so that no money is quietly filed under a repo it did
    /// not come from.
    public let workspaces: [WorkspaceSpend]
    /// Spend from chats that ran without an editor attached and left no local record.
    public let cloudCents: Double
    public let cloudCount: Int
    /// Billed work whose chat is not in the local store, plus events carrying no
    /// conversation id at all.
    public let unattributedCents: Double
    /// Chats that did work in this window but cost nothing — cached or free requests.
    /// A count only: they carry no spend, so adding them to a total would be wrong.
    public let unbilledConversations: Int
    /// Spend and chat count per source. GUI and CLI are the two front ends; `unknown`
    /// holds billed work with no local record, so it is never drawn as editor spend.
    public let bySource: [ActivitySource: (cents: Double, conversations: Int)]

    public let totalCents: Double
    public let models: [ModelSpend]
    public let sessions: [SessionLine]
    /// Every conversation that billed, flat and unrolled — including those `sessions` folds
    /// into a total because they had no local name. Ranked by cost.
    public let ledger: [ConversationCost]
    public let tools: [ToolUsage]
    public let prompts: PromptStats
    public let files: [FileTypeUsage]
    public let daily: [DayLine]

    /// Whether the local store had anything to say. False means the report is cost-only —
    /// worth stating on the page rather than rendering empty sections.
    public var hasActivity: Bool { !tools.isEmpty || prompts.count > 0 }

    /// Local stores that exist but could not be read. Empty means both front ends were
    /// read, and a quiet report is therefore a quiet cycle — not a failure.
    public let unavailableActivitySources: Set<ActivitySource>

    /// The three buckets, summed. Every billed cent lands in exactly one of them.
    public var attributedCents: Double {
        workspaces.reduce(0) { $0 + $1.cents } + cloudCents + unattributedCents
    }

    /// The check that proves nothing was dropped or double-counted.
    ///
    /// Compared **raw**, not in the rounding the page draws with. An earlier version summed
    /// each bucket already rounded to whole cents, which made the verdict depend on how many
    /// repositories happened to be in the cycle: seven rounded values drift from their
    /// rounded total more readily than four, and it reported a failure on a cycle where the
    /// raw figures agreed to nine decimal places. Losing a cent to rounding is a display
    /// detail; losing one to bad attribution is a bug, and only the second is worth alarming
    /// about. The tolerance is far below the resolution of the data and far above the
    /// floating-point error of summing a few hundred events.
    public var reconciles: Bool {
        abs(attributedCents - totalCents) < 0.01
    }

    // MARK: - Building

    public static func build(
        snapshot: UsageSnapshot,
        metrics: UsageMetrics,
        activity: ActivityDigest,
        timeZone: TimeZone = .current,
        now: Date
    ) -> UsageReport {
        let events = snapshot.events
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // MARK: Attribution
        //
        // Exhaustive by construction: every event lands in exactly one of three buckets, so
        // the totals cannot drift apart. A repo when the chat is known locally; otherwise
        // the cloud bucket if the request ran headless, because "ran in the cloud" says
        // something where "unattributed" says nothing; otherwise unattributed.
        var byWorkspace: [WorkspaceIdentity: (cents: Double, sessions: Set<String>, path: String?, name: String)] = [:]
        var cloudCents = 0.0
        var cloudConversations: Set<String> = []
        var unattributedCents = 0.0

        for event in events {
            guard let id = event.conversationID, let record = activity.byConversation[id],
                  let workspace = record.workspace else {
                if event.isCloud {
                    cloudCents += event.cents
                    if let id = event.conversationID { cloudConversations.insert(id) }
                } else {
                    unattributedCents += event.cents
                }
                continue
            }
            let identity: WorkspaceIdentity = record.workspacePath.map { .path($0) } ?? .name(workspace)
            var entry = byWorkspace[identity] ?? (0, [], record.workspacePath, workspace)
            entry.cents += event.cents
            entry.sessions.insert(id)
            byWorkspace[identity] = entry
        }

        // Activity rolls up per repo from the chats that billed against it, so the numbers
        // beside a repo's cost describe the same chats that produced it.
        let workspaces = byWorkspace.map { _, entry -> WorkspaceSpend in
            let records = entry.sessions.compactMap { activity.byConversation[$0] }
            return WorkspaceSpend(
                workspace: entry.name,
                workspacePath: entry.path,
                cents: entry.cents,
                sessions: entry.sessions.count,
                prompts: records.reduce(0) { $0 + $1.prompts },
                toolCalls: records.reduce(0) { $0 + $1.toolCalls },
                linesAdded: records.reduce(0) { $0 + $1.linesAdded }
            )
        }.sorted { ($0.cents, $1.workspace) > ($1.cents, $0.workspace) }

        // MARK: Sessions
        //
        // Taken from the breakdown the menu already draws, so the report cannot rank chats
        // differently from the app it ships with. Activity is summed over each subtree
        // because the cost shown is the subtree's.
        let sessions = snapshot.sessions.ranked.map { node -> SessionLine in
            let ids = subtreeIDs(of: node)
            let records = ids.compactMap { activity.byConversation[$0] }
            return SessionLine(
                id: node.id,
                name: node.name,
                workspace: activity.byConversation[node.id]?.workspace,
                cents: node.rolledCents,
                requests: requestCount(of: node),
                prompts: records.reduce(0) { $0 + $1.prompts },
                toolCalls: records.reduce(0) { $0 + $1.toolCalls },
                isCloud: node.isCloud
            )
        }

        // MARK: The flat ledger
        //
        // Costs per conversation without rolling subagents up, so the entries sum to the
        // cycle exactly once. Names are pulled from the tree the menu already built.
        var perConversation: [String: (cents: Double, requests: Int, cloud: Bool)] = [:]
        for event in events {
            guard let id = event.conversationID else { continue }
            var entry = perConversation[id] ?? (0, 0, true)
            entry.cents += event.cents
            entry.requests += 1
            entry.cloud = entry.cloud && event.isCloud
            perConversation[id] = entry
        }
        var names: [String: String] = [:]
        func indexNames(_ node: SessionNode) {
            if let name = node.name { names[node.id] = name }
            node.children.forEach(indexNames)
        }
        snapshot.sessions.ranked.forEach(indexNames)

        let ledger = perConversation.map { id, entry in
            ConversationCost(id: id, name: names[id], cents: entry.cents,
                             requests: entry.requests, isCloud: entry.cloud)
        }.sorted { ($0.cents, $1.id) > ($1.cents, $0.id) }

        // MARK: Sources
        //
        // Which front end the money went through, or `unknown` when the chat left no local
        // record. Derived from the same events as everything else, so it cannot disagree
        // with the repository split.
        var bySource: [ActivitySource: (cents: Double, conversations: Int)] = [:]
        var seenPerSource: [ActivitySource: Set<String>] = [:]
        for event in events {
            let source = event.conversationID
                .flatMap { activity.byConversation[$0]?.source } ?? .unknown
            var entry = bySource[source] ?? (0, 0)
            entry.cents += event.cents
            bySource[source] = entry
            if let id = event.conversationID { seenPerSource[source, default: []].insert(id) }
        }
        for (source, ids) in seenPerSource {
            bySource[source]?.conversations = ids.count
        }

        // MARK: Unbilled work
        //
        // Chats that did something in the window and cost nothing. Counted, never costed:
        // they are evidence of cached or free requests, not of spend. A chat whose events
        // sum to zero is free even though its id appears in the feed, so the ledger — not
        // the presence of any event — decides who billed.
        let billed = Set(perConversation.filter { $0.value.cents != 0 }.keys)
        let unbilled = activity.byConversation.filter { id, record in
            !billed.contains(id) && (record.prompts > 0 || record.toolCalls > 0)
        }.count

        // MARK: The daily series
        //
        // A day appears if either half saw anything, so a cloud agent's spend on a quiet
        // day is not silently dropped for want of a local record.
        var costPerDay: [Date: Double] = [:]
        for event in events {
            costPerDay[calendar.startOfDay(for: event.timestamp), default: 0] += event.cents
        }
        let activityPerDay = Dictionary(
            activity.daily.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let daily = Set(costPerDay.keys).union(activityPerDay.keys).sorted().map { day in
            DayLine(
                day: day,
                cents: costPerDay[day] ?? 0,
                prompts: activityPerDay[day]?.prompts ?? 0,
                toolCalls: activityPerDay[day]?.toolCalls ?? 0
            )
        }

        return UsageReport(
            generatedAt: now,
            cycleStart: snapshot.cycleStart,
            cycleEnd: snapshot.cycleEnd,
            metrics: metrics,
            truncated: snapshot.sessionsTruncated,
            workspaces: workspaces,
            cloudCents: cloudCents,
            cloudCount: cloudConversations.count,
            unattributedCents: unattributedCents,
            unbilledConversations: unbilled,
            bySource: bySource,
            totalCents: events.reduce(0) { $0 + $1.cents },
            // Already relabelled and merged by `SessionBreakdown`, so `default` and
            // `auto-smart` arrive as one **Auto** row.
            models: snapshot.sessions.models,
            sessions: sessions,
            ledger: ledger,
            tools: activity.tools,
            prompts: activity.prompts,
            files: activity.files,
            daily: daily,
            unavailableActivitySources: activity.unavailableSources
        )
    }

    /// A node's id and every id beneath it.
    private static func subtreeIDs(of node: SessionNode) -> [String] {
        [node.id] + node.children.flatMap(subtreeIDs)
    }

    private static func requestCount(of node: SessionNode) -> Int {
        node.children.reduce(node.requestCount) { $0 + requestCount(of: $1) }
    }
}
