import Foundation

/// The report as JSON, for feeding to something else.
///
/// The HTML report answers the questions it was designed around. This exists for the ones
/// it wasn't: hand the file to a model or a notebook and ask for whatever cut you want.
///
/// It deliberately exports **facts, not judgements**. Which tools ran in a chat, how long
/// its prompts were, which repo it was in — never a label like "this was a bug fix". Those
/// classifications are worth making, but making them here would bake one taxonomy into the
/// data and quietly discard the evidence behind it. A consumer can derive its own and show
/// its work; it cannot un-derive ours.
public struct ReportExport: Encodable {
    public let schema = "cursor-gauge/report/1"
    public let generatedAt: Date
    public let cycle: Cycle
    public let attribution: Attribution
    public let models: [Model]
    public let daily: [Day]
    public let tools: [Tool]
    public let fileTypes: [FileType]
    public let commands: [Command]
    public let prompts: Prompts
    public let conversations: [Conversation]
    /// Set when the event feed is incomplete — the page cap, or fewer rows than the API
    /// declared — so a consumer knows the totals are a floor.
    public let partial: Bool
    /// Whether any local activity rows were read. Pair with `activityAvailability` to tell
    /// a genuinely quiet cycle apart from an unreadable store.
    public let hasActivity: Bool
    /// Per-front-end readability. Always contains both keys; availability does not imply
    /// that any activity was recorded.
    public let activityAvailability: ActivityAvailability
    /// Whether prompt text is present. Stated so a consumer never has to guess whether an
    /// empty `promptText` means "not collected" or "no prompts".
    public let includesPromptText: Bool

    public struct ActivityAvailability: Encodable {
        public let gui: String
        public let cli: String
    }

    public struct Cycle: Encodable {
        public let start: Date
        public let end: Date
        public let spentCents: Double
        public let limitDollars: Double?
        public let fractionOfLimit: Double?
        public let fractionElapsed: Double
        public let projectedCents: Double?
        public let burnRateCentsPerDay: Double
        public let aheadOfPace: Bool
    }

    public struct Attribution: Encodable {
        public let totalCents: Double
        public let workspaces: [Workspace]
        public let cloudCents: Double
        public let cloudConversations: Int
        public let unattributedCents: Double
        public let freeOfChargeConversations: Int
        /// Whether the parts above account for `totalCents` exactly, in the rounding the
        /// HTML draws with. A consumer should refuse to chart a breakdown that says false.
        public let reconciles: Bool
    }

    public struct Workspace: Encodable {
        public let workspace: String
        public let cents: Double
        public let conversations: Int
        public let prompts: Int
        public let toolCalls: Int
        public let linesAdded: Int
    }

    public struct Model: Encodable {
        public let model: String
        public let cents: Double
    }

    public struct Day: Encodable {
        public let day: String
        public let cents: Double
        public let prompts: Int
        public let toolCalls: Int
    }

    public struct Tool: Encodable {
        public let name: String
        /// The MCP server, when the name identifies one. Null for Cursor's built-ins.
        public let server: String?
        public let calls: Int
        public let errors: Int
        public let cancelled: Int
        public let rejected: Int
    }

    public struct FileType: Encodable {
        public let ext: String
        public let reads: Int
        public let edits: Int
    }

    public struct Command: Encodable {
        public let command: String
        public let count: Int
    }

    public struct Prompts: Encodable {
        public let count: Int
        public let medianChars: Int
        public let longestChars: Int
    }

    /// One chat: what it cost, and the evidence of what it did.
    public struct Conversation: Encodable {
        public let id: String
        /// The chat's title. Null for chats with no local record, which is the normal case
        /// for cloud agents.
        public let name: String?
        public let workspace: String?
        /// `agent`, `chat` or `debug` in the editor; `cli` for a terminal agent.
        public let mode: String?
        /// Which front end ran this: `gui` (the editor) or `cli` (`cursor-agent`). The two
        /// use different tool names for comparable work, so never pool them without checking.
        public let source: ActivitySource
        public let cents: Double
        public let requests: Int
        /// True when every billed request here ran without an editor attached.
        public let isCloud: Bool
        public let prompts: Int
        public let toolCalls: Int
        /// Tool name to call count — the evidence behind what kind of work this was.
        public let tools: [String: Int]
        /// File extension to operation count, so documentation work is separable from test
        /// work without reading a prompt.
        public let fileTypes: [String: Int]
        /// Lifetime totals for the chat, not window-scoped: Cursor keeps no daily breakdown.
        public let linesAdded: Int
        public let linesRemoved: Int
        public let filesChanged: Int
        public let firstActivity: Date?
        public let lastActivity: Date?
        /// Prompt lengths in the order written.
        public let promptLengths: [Int]
        /// Present only when the caller opted in. See `ReportCommand`.
        public let promptText: [String]?
    }

    // MARK: - Building

    /// - Parameter promptText: prompts by conversation id, or `nil` to omit them entirely.
    ///   Passing `nil` is the default everywhere; it has to be supplied deliberately.
    public static func build(
        report: UsageReport,
        activity: ActivityDigest,
        promptText: [String: [String]]? = nil,
        timeZone: TimeZone = .current
    ) -> ReportExport {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = timeZone
        day.locale = Locale(identifier: "en_US_POSIX")

        // Chats that billed, plus chats that did work for free. The union matters: a
        // conversation count taken only from the ledger would miss everything cached.
        let costs = Dictionary(report.ledger.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let active = activity.byConversation.filter { $0.value.prompts > 0 || $0.value.toolCalls > 0 }
        let conversations = Set(costs.keys).union(active.keys).map { id -> Conversation in
            let cost = costs[id]
            let record = activity.byConversation[id]
            return Conversation(
                id: id,
                name: cost?.name,
                workspace: record?.workspace,
                mode: record?.mode,
                source: record?.source ?? .gui,
                cents: cost?.cents ?? 0,
                requests: cost?.requests ?? 0,
                isCloud: cost?.isCloud ?? false,
                prompts: record?.prompts ?? 0,
                toolCalls: record?.toolCalls ?? 0,
                tools: record?.tools ?? [:],
                fileTypes: record?.fileTypes ?? [:],
                linesAdded: record?.linesAdded ?? 0,
                linesRemoved: record?.linesRemoved ?? 0,
                filesChanged: record?.filesChanged ?? 0,
                firstActivity: record?.firstActivity,
                lastActivity: record?.lastActivity,
                promptLengths: record?.promptLengths ?? [],
                promptText: promptText?[id] ?? (promptText == nil ? nil : [])
            )
        }.sorted { ($0.cents, $1.id) > ($1.cents, $0.id) }

        return ReportExport(
            generatedAt: report.generatedAt,
            cycle: Cycle(
                start: report.cycleStart,
                end: report.cycleEnd,
                spentCents: report.metrics.spentCents,
                limitDollars: report.metrics.limitDollars,
                fractionOfLimit: report.metrics.rawFraction,
                fractionElapsed: report.metrics.cycleElapsedFraction,
                projectedCents: report.metrics.projectedCents,
                burnRateCentsPerDay: report.metrics.burnRateCentsPerDay,
                aheadOfPace: report.metrics.isAheadOfPace
            ),
            attribution: Attribution(
                totalCents: report.totalCents,
                workspaces: report.workspaces.map {
                    Workspace(workspace: $0.workspace, cents: $0.cents, conversations: $0.sessions,
                              prompts: $0.prompts, toolCalls: $0.toolCalls, linesAdded: $0.linesAdded)
                },
                cloudCents: report.cloudCents,
                cloudConversations: report.cloudCount,
                unattributedCents: report.unattributedCents,
                freeOfChargeConversations: report.unbilledConversations,
                reconciles: report.reconciles
            ),
            models: report.models.map { Model(model: $0.model, cents: $0.cents) },
            daily: report.daily.map {
                Day(day: day.string(from: $0.day), cents: $0.cents,
                    prompts: $0.prompts, toolCalls: $0.toolCalls)
            },
            tools: report.tools.map {
                Tool(name: $0.name, server: $0.server, calls: $0.calls,
                     errors: $0.errors, cancelled: $0.cancelled, rejected: $0.rejected)
            },
            fileTypes: report.files.map { FileType(ext: $0.ext, reads: $0.reads, edits: $0.edits) },
            commands: report.prompts.commands.map { Command(command: $0.command, count: $0.count) },
            prompts: Prompts(count: report.prompts.count, medianChars: report.prompts.medianChars,
                             longestChars: report.prompts.longestChars),
            conversations: conversations,
            partial: report.truncated,
            hasActivity: report.hasActivity,
            activityAvailability: ActivityAvailability(
                gui: report.unavailableActivitySources.contains(.gui) ? "unavailable" : "available",
                cli: report.unavailableActivitySources.contains(.cli) ? "unavailable" : "available"
            ),
            includesPromptText: promptText != nil
        )
    }

    /// Pretty-printed with sorted keys: the file is meant to be read, diffed and pasted.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
