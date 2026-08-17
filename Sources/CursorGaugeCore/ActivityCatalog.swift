import Foundation

// MARK: - What a window of local activity looks like

/// One tool, and how it fared.
public struct ToolUsage: Equatable, Identifiable {
    /// Cursor's own name, kept verbatim — `read_file_v2`, `mcp-atlassian-getJiraIssue`.
    public let name: String
    public let calls: Int
    public let errors: Int
    public let cancelled: Int
    /// Edits the user turned down. Only the file-changing tools can produce these.
    public let rejected: Int

    public var id: String { name }

    public init(name: String, calls: Int, errors: Int = 0, cancelled: Int = 0, rejected: Int = 0) {
        self.name = name
        self.calls = calls
        self.errors = errors
        self.cancelled = cancelled
        self.rejected = rejected
    }

    /// The MCP server this tool came from, or `nil` for one of Cursor's built-ins.
    ///
    /// Cursor names MCP tools `mcp-<server>-<tool>`, so this is the first segment. The
    /// convention is not airtight — a couple of Cursor's own bridges are named
    /// `mcp-extension-…` and `mcp-cursor-ide-…` — so read this as "which integration",
    /// not as a guarantee about the server's identity.
    public var server: String? {
        guard name.hasPrefix("mcp-") else { return nil }
        let rest = name.dropFirst("mcp-".count)
        let segment = rest.prefix { $0 != "-" }
        return segment.isEmpty ? nil : String(segment)
    }
}

/// A slash command and how often it was reached for.
public struct CommandUsage: Equatable, Identifiable {
    public let command: String
    public let count: Int

    public var id: String { command }

    public init(command: String, count: Int) {
        self.command = command
        self.count = count
    }
}

/// How the work was asked for — shape only. No prompt text is ever carried here.
public struct PromptStats: Equatable {
    public let count: Int
    /// Median beats mean: one 21,000-character paste would otherwise define the typical prompt.
    public let medianChars: Int
    public let longestChars: Int
    public let commands: [CommandUsage]

    public static let empty = PromptStats(count: 0, medianChars: 0, longestChars: 0, commands: [])

    public init(count: Int, medianChars: Int, longestChars: Int, commands: [CommandUsage]) {
        self.count = count
        self.medianChars = medianChars
        self.longestChars = longestChars
        self.commands = commands
    }
}

/// What kind of file the work touched.
public struct FileTypeUsage: Equatable, Identifiable {
    /// A lowercased extension including the dot, or `(none)` for files without one.
    public let ext: String
    public let reads: Int
    public let edits: Int

    public var id: String { ext }
    public var operations: Int { reads + edits }

    public init(ext: String, reads: Int, edits: Int) {
        self.ext = ext
        self.reads = reads
        self.edits = edits
    }
}

/// What one chat did locally.
///
/// `prompts` and `toolCalls` are scoped to the requested window. `linesAdded`,
/// `linesRemoved` and `filesChanged` come from the chat's header and are **lifetime**
/// totals for that chat — Cursor keeps no per-day breakdown of them. A chat that began
/// last cycle therefore reports lines it accrued before the window opened, so present
/// them as belonging to the chat rather than to the period.
public struct ConversationActivity: Equatable {
    /// The repo's directory name, e.g. `ko-services`.
    public let workspace: String?
    public let workspacePath: String?
    /// `agent`, `chat`, or `debug`.
    public let mode: String?
    public let prompts: Int
    public let toolCalls: Int
    public let linesAdded: Int
    public let linesRemoved: Int
    public let filesChanged: Int
    /// Which tools ran here, and how often.
    ///
    /// Carried per conversation rather than only in the global ranking because it is the
    /// evidence behind what a chat *was*: one that edited files did different work from one
    /// that only read them. Exported raw so a consumer can draw its own conclusions instead
    /// of inheriting a taxonomy invented here.
    public let tools: [String: Int]
    /// Bounds of this chat's activity inside the window, for anything time-based.
    public let firstActivity: Date?
    public let lastActivity: Date?
    /// Lengths of the prompts written here, in order. Lengths only — never the text.
    public let promptLengths: [Int]
    /// Extension to operation count for the files this chat touched. Alongside `tools`, this
    /// is what lets a consumer tell documentation work from test work without reading a word
    /// of the prompts.
    public let fileTypes: [String: Int]

    public init(
        workspace: String? = nil, workspacePath: String? = nil, mode: String? = nil,
        prompts: Int = 0, toolCalls: Int = 0,
        linesAdded: Int = 0, linesRemoved: Int = 0, filesChanged: Int = 0,
        tools: [String: Int] = [:],
        firstActivity: Date? = nil, lastActivity: Date? = nil,
        promptLengths: [Int] = [], fileTypes: [String: Int] = [:]
    ) {
        self.fileTypes = fileTypes
        self.workspace = workspace
        self.workspacePath = workspacePath
        self.mode = mode
        self.prompts = prompts
        self.toolCalls = toolCalls
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.filesChanged = filesChanged
        self.tools = tools
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.promptLengths = promptLengths
    }
}

/// One day's worth of work.
public struct DayActivity: Equatable, Identifiable {
    public let day: Date
    public let prompts: Int
    public let toolCalls: Int

    public var id: Date { day }

    public init(day: Date, prompts: Int, toolCalls: Int) {
        self.day = day
        self.prompts = prompts
        self.toolCalls = toolCalls
    }
}

/// Everything the local store knows about a window of work, and nothing about its cost.
public struct ActivityDigest: Equatable {
    /// Ranked by call count, descending.
    public let tools: [ToolUsage]
    public let prompts: PromptStats
    /// Ranked by total operations, descending.
    public let files: [FileTypeUsage]
    /// Every chat the local store knows about, plus any that produced activity without a
    /// header. Deliberately *not* restricted to the window: it is the lookup a cost report
    /// joins against, and a chat can bill in this cycle while its messages were written in
    /// the last one. The activity counts inside each entry are still window-scoped.
    public let byConversation: [String: ConversationActivity]
    /// Chronological, one entry per day that saw activity.
    public let daily: [DayActivity]

    /// What an absent, locked, corrupt or renamed store yields.
    public static let empty = ActivityDigest(
        tools: [], prompts: .empty, files: [], byConversation: [:], daily: []
    )

    public var isEmpty: Bool { self == .empty }

    public init(
        tools: [ToolUsage], prompts: PromptStats, files: [FileTypeUsage],
        byConversation: [String: ConversationActivity], daily: [DayActivity]
    ) {
        self.tools = tools
        self.prompts = prompts
        self.files = files
        self.byConversation = byConversation
        self.daily = daily
    }
}

// MARK: - Reading it

/// Summarises what Cursor recorded locally over a window of time.
///
/// Sibling to `SessionCatalog`, and deliberately built the same way: read-only, failures
/// swallowed, and **every aggregation performed inside SQLite**. That last point is the
/// design. The `bubbleId:` rows on a working account total roughly 200 MB — a single
/// `params` field can hold an entire file body — while the answers are a few dozen short
/// rows. Counting in SQL and returning only the totals keeps a full six-month scan under a
/// second and keeps file contents inside the database, where they belong.
public final class ActivityCatalog {
    private let databaseURL: URL
    private let timeZone: TimeZone

    /// Long enough to rank the real commands, short enough that a prompt beginning with a
    /// stray slash cannot bloat the table.
    private static let maxCommandLength = 60

    /// `timeZone` decides where one day ends and the next begins. It defaults to the user's,
    /// because a chart of their working days should match the days they actually worked;
    /// tests pin it to UTC so the boundaries are not a function of where the test runs.
    public init(databaseURL: URL = TokenStore.defaultDatabaseURL, timeZone: TimeZone = .current) {
        self.databaseURL = databaseURL
        self.timeZone = timeZone
    }

    /// Everything recorded at or after `since`.
    ///
    /// The window matters: pairing six months of tool counts with one cycle of spend would
    /// be arithmetically true and completely misleading, so the caller's window is applied
    /// to every query here.
    public func digest(since: Date) -> ActivityDigest {
        guard let database = ReadOnlyDatabase(url: databaseURL) else { return .empty }
        let start = Self.boundary.string(from: since)

        // A store missing the bubble table has nothing to say. Distinguishing that from a
        // genuinely quiet window keeps a renamed table from reading as "you did no work".
        guard let tools = tools(database, since: start) else { return .empty }

        let files = files(database, since: start)
        return ActivityDigest(
            tools: tools,
            prompts: prompts(database, since: start),
            files: files.overall,
            byConversation: conversations(database, since: start, fileTypes: files.perConversation),
            daily: daily(database, since: start)
        )
    }

    // MARK: - Queries

    private func tools(_ database: ReadOnlyDatabase, since: String) -> [ToolUsage]? {
        var found: [ToolUsage] = []
        let ran = database.query("""
            SELECT json_extract(value, '$.toolFormerData.name') AS tool,
                   count(*),
                   sum(json_extract(value, '$.toolFormerData.status') = 'error'),
                   sum(json_extract(value, '$.toolFormerData.status') = 'cancelled'),
                   sum(json_extract(value, '$.toolFormerData.userDecision') = 'rejected')
            FROM cursorDiskKV
            WHERE \(Self.bubblesInWindow)
              AND json_extract(value, '$.toolFormerData.name') IS NOT NULL
            GROUP BY tool
            ORDER BY 2 DESC, tool
            """, [since]) { row in
            guard let name = row.text(0) else { return }
            found.append(ToolUsage(
                name: name, calls: row.int(1),
                errors: row.int(2), cancelled: row.int(3), rejected: row.int(4)
            ))
        }
        return ran ? found : nil
    }

    private func prompts(_ database: ReadOnlyDatabase, since: String) -> PromptStats {
        // Only the lengths cross into Swift; the prompt text stays in the database.
        var lengths: [Int] = []
        database.query("""
            SELECT length(json_extract(value, '$.text'))
            FROM cursorDiskKV
            WHERE \(Self.bubblesInWindow) AND \(Self.isPrompt)
            """, [since]) { row in
            lengths.append(row.int(0))
        }

        var commands: [CommandUsage] = []
        database.query("""
            SELECT command, count(*) FROM (
                SELECT lower(CASE WHEN instr(flat, ' ') > 0
                                  THEN substr(flat, 1, instr(flat, ' ') - 1)
                                  ELSE substr(flat, 1, \(Self.maxCommandLength)) END) AS command
                FROM (
                    SELECT replace(replace(json_extract(value, '$.text'),
                                           char(10), ' '), char(13), ' ') AS flat
                    FROM cursorDiskKV
                    WHERE \(Self.bubblesInWindow) AND \(Self.isPrompt)
                )
                WHERE flat LIKE '/%'
            )
            -- A prompt opening with a file path is not a command; a second slash gives it away.
            WHERE instr(substr(command, 2), '/') = 0 AND length(command) > 1
            GROUP BY command
            ORDER BY 2 DESC, command
            """, [since]) { row in
            guard let command = row.text(0) else { return }
            commands.append(CommandUsage(command: command, count: row.int(1)))
        }

        let sorted = lengths.sorted()
        return PromptStats(
            count: sorted.count,
            medianChars: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
            longestChars: sorted.last ?? 0,
            commands: commands
        )
    }

    /// Returns the cycle-wide ranking and, separately, the same figures per conversation.
    ///
    /// The path lives inside `params`, which Cursor stores as a JSON *string* — hence the
    /// second `json_extract`. Tools disagree on the key, so both are tried. Grouping happens
    /// inside SQLite so that `params.streamingContent`, which holds whole file bodies, never
    /// leaves the database; only extensions and counts come back.
    private func files(
        _ database: ReadOnlyDatabase, since: String
    ) -> (overall: [FileTypeUsage], perConversation: [String: [String: Int]]) {
        var reads: [String: Int] = [:]
        var edits: [String: Int] = [:]
        var perConversation: [String: [String: Int]] = [:]
        database.query("""
            SELECT conversation, tool, path, count(*) FROM (
                SELECT conversation, tool,
                       CASE WHEN json_valid(params)
                            THEN coalesce(json_extract(params, '$.relativeWorkspacePath'),
                                          json_extract(params, '$.targetFile'))
                       END AS path
                FROM (
                    SELECT substr(key, 10, instr(substr(key, 10), ':') - 1) AS conversation,
                           json_extract(value, '$.toolFormerData.name') AS tool,
                           json_extract(value, '$.toolFormerData.params') AS params
                    FROM cursorDiskKV
                    WHERE \(Self.bubblesInWindow)
                      AND json_extract(value, '$.toolFormerData.name') IS NOT NULL
                )
            )
            WHERE path IS NOT NULL
            GROUP BY conversation, tool, path
            """, [since]) { row in
            guard let tool = row.text(1), let path = row.text(2) else { return }
            let ext = Self.extension(of: path)
            let count = row.int(3)
            if Self.changesFiles(tool) {
                edits[ext, default: 0] += count
            } else {
                reads[ext, default: 0] += count
            }
            if let id = row.text(0), !id.isEmpty {
                perConversation[id, default: [:]][ext, default: 0] += count
            }
        }

        let overall = Set(reads.keys).union(edits.keys)
            .map { FileTypeUsage(ext: $0, reads: reads[$0] ?? 0, edits: edits[$0] ?? 0) }
            .sorted { ($0.operations, $1.ext) > ($1.operations, $0.ext) }
        return (overall, perConversation)
    }

    private func conversations(
        _ database: ReadOnlyDatabase, since: String, fileTypes: [String: [String: Int]]
    ) -> [String: ConversationActivity] {
        // `bubbleId:<composerId>:<bubbleId>` — take the middle field. "bubbleId:" is nine
        // characters, so the id starts at ten.
        var prompts: [String: Int] = [:]
        var toolCalls: [String: Int] = [:]
        var first: [String: Date] = [:]
        var last: [String: Date] = [:]
        database.query("""
            SELECT substr(key, 10, instr(substr(key, 10), ':') - 1) AS conversation,
                   sum(\(Self.isPrompt)),
                   sum(json_extract(value, '$.toolFormerData.name') IS NOT NULL),
                   min(json_extract(value, '$.createdAt')),
                   max(json_extract(value, '$.createdAt'))
            FROM cursorDiskKV
            WHERE \(Self.bubblesInWindow)
            GROUP BY conversation
            """, [since]) { row in
            guard let id = row.text(0), !id.isEmpty else { return }
            prompts[id] = row.int(1)
            toolCalls[id] = row.int(2)
            first[id] = row.text(3).flatMap(Self.boundary.date(from:))
            last[id] = row.text(4).flatMap(Self.boundary.date(from:))
        }

        // Which tools ran in which chat. One row per (chat, tool) pair rather than per call,
        // so the volume that crosses into Swift stays in the hundreds.
        var toolsPerConversation: [String: [String: Int]] = [:]
        database.query("""
            SELECT substr(key, 10, instr(substr(key, 10), ':') - 1) AS conversation,
                   json_extract(value, '$.toolFormerData.name') AS tool,
                   count(*)
            FROM cursorDiskKV
            WHERE \(Self.bubblesInWindow)
              AND json_extract(value, '$.toolFormerData.name') IS NOT NULL
            GROUP BY conversation, tool
            """, [since]) { row in
            guard let id = row.text(0), !id.isEmpty, let tool = row.text(1) else { return }
            toolsPerConversation[id, default: [:]][tool] = row.int(2)
        }

        // Prompt *lengths* per chat. The text stays in the database; see `promptText(since:)`
        // for the one path that reads it, which nothing calls unless explicitly asked.
        var lengths: [String: [Int]] = [:]
        database.query("""
            SELECT substr(key, 10, instr(substr(key, 10), ':') - 1) AS conversation,
                   length(json_extract(value, '$.text'))
            FROM cursorDiskKV
            WHERE \(Self.bubblesInWindow) AND \(Self.isPrompt)
            ORDER BY json_extract(value, '$.createdAt')
            """, [since]) { row in
            guard let id = row.text(0), !id.isEmpty else { return }
            lengths[id, default: []].append(row.int(1))
        }

        // The header table is 300-odd rows on a working account, so it is read whole rather
        // than joined per id.
        var headers: [String: (String?, String?, Int, Int, Int)] = [:]
        database.query("""
            SELECT composerId,
                   json_extract(value, '$.workspaceIdentifier.uri.fsPath'),
                   json_extract(value, '$.unifiedMode'),
                   json_extract(value, '$.totalLinesAdded'),
                   json_extract(value, '$.totalLinesRemoved'),
                   json_extract(value, '$.filesChangedCount')
            FROM composerHeaders
            WHERE json_valid(value)
            """) { row in
            guard let id = row.text(0) else { return }
            headers[id] = (row.text(1), row.text(2), row.int(3), row.int(4), row.int(5))
        }

        // Headers join in whole, not just the ones with activity in the window: a chat can
        // bill this cycle while its messages were written in the last one, and dropping it
        // here would send its cost to the unattributed bucket for no good reason.
        return Set(prompts.keys).union(toolCalls.keys).union(headers.keys).reduce(into: [:]) { result, id in
            let header = headers[id]
            result[id] = ConversationActivity(
                workspace: header?.0.map { ($0 as NSString).lastPathComponent },
                workspacePath: header?.0,
                mode: header?.1,
                prompts: prompts[id] ?? 0,
                toolCalls: toolCalls[id] ?? 0,
                linesAdded: header?.2 ?? 0,
                linesRemoved: header?.3 ?? 0,
                filesChanged: header?.4 ?? 0,
                tools: toolsPerConversation[id] ?? [:],
                firstActivity: first[id],
                lastActivity: last[id],
                promptLengths: lengths[id] ?? [],
                fileTypes: fileTypes[id] ?? [:]
            )
        }
    }

    /// The prompts themselves, by conversation.
    ///
    /// Deliberately a separate call rather than a field on `ActivityDigest`: the digest
    /// promises to carry statistics and not content, and that promise is only worth
    /// something if reading the text requires asking for it by name. Nothing in the app
    /// calls this — only an export the user has explicitly opted into.
    public func promptText(since: Date) -> [String: [String]] {
        guard let database = ReadOnlyDatabase(url: databaseURL) else { return [:] }
        var found: [String: [String]] = [:]
        database.query("""
            SELECT substr(key, 10, instr(substr(key, 10), ':') - 1) AS conversation,
                   json_extract(value, '$.text')
            FROM cursorDiskKV
            WHERE \(Self.bubblesInWindow) AND \(Self.isPrompt)
            ORDER BY json_extract(value, '$.createdAt')
            """, [Self.boundary.string(from: since)]) { row in
            guard let id = row.text(0), !id.isEmpty, let text = row.text(1) else { return }
            found[id, default: []].append(text)
        }
        return found
    }

    private func daily(_ database: ReadOnlyDatabase, since: String) -> [DayActivity] {
        // `createdAt` is stored in UTC, so it is shifted into the reporting zone before the
        // date is sliced off. A window spanning a daylight-saving change uses the offset in
        // force when the report runs, which can misfile a single boundary hour — the
        // alternative is a per-row timezone calculation for a chart that reads in days.
        let shift = "\(timeZone.secondsFromGMT()) seconds"
        var days: [DayActivity] = []
        database.query("""
            SELECT substr(datetime(json_extract(value, '$.createdAt'), ?2), 1, 10) AS day,
                   sum(\(Self.isPrompt)),
                   sum(json_extract(value, '$.toolFormerData.name') IS NOT NULL)
            FROM cursorDiskKV
            WHERE \(Self.bubblesInWindow)
            GROUP BY day
            ORDER BY day
            """, [since, shift]) { row in
            guard let text = row.text(0), let day = self.calendarDay.date(from: text) else { return }
            days.append(DayActivity(day: day, prompts: row.int(1), toolCalls: row.int(2)))
        }
        return days
    }

    // MARK: - Shared SQL

    /// `json_valid` guards every extract: `json_extract` *raises* on a malformed document
    /// rather than returning null, which would abort the whole statement over one bad row.
    ///
    /// `createdAt` is an ISO 8601 string, so `>=` compares it lexicographically — correct
    /// for this format, and it needs no index. See `boundary` for the one catch.
    private static let bubblesInWindow = """
        key LIKE 'bubbleId:%' AND json_valid(value) \
        AND json_extract(value, '$.createdAt') >= ?1
        """

    private static let isPrompt = """
        (json_extract(value, '$.type') = 1 AND coalesce(json_extract(value, '$.text'), '') <> '')
        """

    /// Formatted **with** fractional seconds, deliberately.
    ///
    /// Cursor writes `2026-08-01T00:00:00.500Z`. Compared against a boundary written as
    /// `2026-08-01T00:00:00Z`, the `Z` sorts after the `.`, so the boundary would come out
    /// *greater* than a moment that follows it and the first fraction of a second of every
    /// window would vanish. Matching the stored format removes the trap.
    private static let boundary: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Reads back the sliced date in the same zone it was sliced in, so the `Date` marks
    /// local midnight rather than UTC midnight.
    private lazy var calendarDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Tools that write rather than read. Everything else carrying a path is a read.
    private static func changesFiles(_ tool: String) -> Bool {
        ["edit", "create", "delete", "write"].contains { tool.hasPrefix($0) }
    }

    private static func `extension`(of path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "(none)" : "." + ext
    }
}
