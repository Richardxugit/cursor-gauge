import Foundation

/// One billed request, reduced to what grouping needs.
public struct SessionEvent: Equatable {
    /// Cursor's `conversationId`, which is the composer id of the chat in its history.
    /// `nil` on the rare event that carries none.
    public let conversationID: String?
    /// The model actually billed, e.g. `claude-sonnet-5-thinking-high`. Note the usage
    /// events name real models where the aggregate endpoint reports a `modelIntent`
    /// (`default`), so this is the more precise of the two.
    public let model: String?
    public let cents: Double
    public let timestamp: Date

    public init(conversationID: String?, model: String?, cents: Double, timestamp: Date) {
        self.conversationID = conversationID
        self.model = model
        self.cents = cents
        self.timestamp = timestamp
    }
}

/// What one model cost within a session.
public struct ModelSpend: Equatable, Identifiable {
    public let model: String
    public let cents: Double

    public var id: String { model }

    public init(model: String, cents: Double) {
        self.model = model
        self.cents = cents
    }
}

/// What the local Cursor store knows about a chat.
public struct SessionRecord: Equatable {
    public let name: String?
    /// `subagentInfo.parentComposerId` — set when Cursor spawned this chat from another.
    public let parentID: String?

    public init(name: String?, parentID: String?) {
        self.name = name
        self.parentID = parentID
    }
}

/// A chat and the subagent chats it spawned.
public struct SessionNode: Equatable, Identifiable {
    public let id: String
    public let name: String?
    /// Spend billed directly to this chat, excluding its subagents.
    public let ownCents: Double
    public let requestCount: Int
    public let lastActivity: Date
    public let children: [SessionNode]
    /// Spend by model across the whole job — this chat and every subagent under it —
    /// ranked by cost. Sums to `rolledCents` apart from events that named no model.
    public let models: [ModelSpend]

    /// What the whole piece of work cost — this chat plus everything under it.
    public var rolledCents: Double {
        children.reduce(ownCents) { $0 + $1.rolledCents }
    }
}

/// What the menu renders when the list is cut to a given length.
public struct SessionDisplay: Equatable {
    public let rows: [SessionNode]
    public let hiddenCount: Int
    /// The remainder, in the same rounding the rows are drawn with, so the column adds up.
    public let hiddenCents: Double

    public var hasMore: Bool { hiddenCount > 0 }
}

/// Every named session this cycle, ranked, plus a bucket for spend that cannot be named.
public struct SessionBreakdown: Equatable {
    /// Named roots by rolled cost, descending. Holds *all* of them; the view truncates.
    public let ranked: [SessionNode]
    /// Roots with no local record, plus events carrying no conversation id.
    public let unnamedCents: Double
    /// Roots only — an unattributed event is spend, not a session.
    public let unnamedCount: Int
    public let totalCents: Double

    public static let empty = SessionBreakdown(ranked: [], unnamedCents: 0, unnamedCount: 0, totalCents: 0)

    /// Cuts the list to `limit` rows and derives the remainder.
    ///
    /// `hiddenCents` is computed from the **rounded** row values rather than raw cents.
    /// Summing raw and rounding once at the end is correct in memory but reads wrong on
    /// screen: the real cycle produced a column showing $23.52 against a $23.51 total.
    public func display(limit: Int) -> SessionDisplay {
        let rows = Array(ranked.prefix(max(limit, 0)))
        let shown = rows.reduce(0) { $0 + Format.displayedCents($1.rolledCents) }
        return SessionDisplay(
            rows: rows,
            hiddenCount: (ranked.count - rows.count) + unnamedCount,
            hiddenCents: max(Format.displayedCents(totalCents) - shown, 0)
        )
    }

    public static func build(events: [SessionEvent], catalog: [String: SessionRecord]) -> SessionBreakdown {
        let total = events.reduce(0) { $0 + $1.cents }

        // Own spend per chat, ignoring events we cannot attribute to one.
        var own: [String: Double] = [:]
        var count: [String: Int] = [:]
        var seen: [String: Date] = [:]
        var ownModels: [String: [String: Double]] = [:]
        for e in events {
            guard let id = e.conversationID else { continue }
            own[id, default: 0] += e.cents
            count[id, default: 0] += 1
            seen[id] = max(seen[id] ?? .distantPast, e.timestamp)
            if let model = e.model { ownModels[id, default: [:]][model, default: 0] += e.cents }
        }

        // A parent may itself have billed nothing, so pull ancestors in from the catalog.
        var nodes = Set(own.keys)
        var pending = Array(nodes)
        while let id = pending.popLast() {
            guard let parent = catalog[id]?.parentID, catalog[parent] != nil,
                  !nodes.contains(parent) else { continue }
            nodes.insert(parent)
            pending.append(parent)
        }

        // A parent link is only real if we hold the parent; anything else is an orphan,
        // which becomes a root rather than disappearing.
        var parentOf: [String: String] = [:]
        for id in nodes {
            if let parent = catalog[id]?.parentID, nodes.contains(parent) { parentOf[id] = parent }
        }
        breakCycles(&parentOf, among: nodes)

        var childrenOf: [String: [String]] = [:]
        for (child, parent) in parentOf { childrenOf[parent, default: []].append(child) }

        func node(_ id: String) -> SessionNode {
            let kids = (childrenOf[id] ?? []).map(node).sorted { $0.ownCents > $1.ownCents }
            // Merge each subagent's split upward so a parent describes the whole job.
            var totals = ownModels[id] ?? [:]
            for kid in kids {
                for spend in kid.models { totals[spend.model, default: 0] += spend.cents }
            }
            return SessionNode(
                id: id,
                name: catalog[id]?.name,
                ownCents: own[id] ?? 0,
                requestCount: count[id] ?? 0,
                lastActivity: kids.reduce(seen[id] ?? .distantPast) { max($0, $1.lastActivity) },
                children: kids,
                models: totals
                    .map { ModelSpend(model: $0.key, cents: $0.value) }
                    .sorted { ($0.cents, $1.model) > ($1.cents, $0.model) }
            )
        }

        let roots = nodes.filter { parentOf[$0] == nil }.map(node)
        let ranked = roots.filter { $0.name != nil }.sorted { $0.rolledCents > $1.rolledCents }

        // Defined by subtraction, so nothing can fall between the categories: it covers
        // un-nameable roots *and* events that carried no conversation id at all.
        let namedTotal = ranked.reduce(0) { $0 + $1.rolledCents }
        return SessionBreakdown(
            ranked: ranked,
            unnamedCents: max(total - namedTotal, 0),
            unnamedCount: roots.filter { $0.name == nil }.count,
            totalCents: total
        )
    }

    /// Cursor should never produce a parent cycle, but a corrupt or half-written row could.
    /// Snap the lowest-sorting id in each cycle to a root so the walk terminates and every
    /// node is emitted exactly once.
    private static func breakCycles(_ parentOf: inout [String: String], among nodes: Set<String>) {
        for start in nodes.sorted() {
            var slow = start
            var path: [String] = []
            var visited: Set<String> = []
            while let next = parentOf[slow] {
                if visited.contains(next) {
                    let cycle = path.drop { $0 != next }
                    if let canonical = cycle.min() { parentOf[canonical] = nil }
                    break
                }
                visited.insert(next)
                path.append(next)
                slow = next
            }
        }
    }
}
