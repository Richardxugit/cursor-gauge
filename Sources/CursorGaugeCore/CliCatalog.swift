import Foundation

/// Summarises what `cursor-agent` recorded locally.
///
/// The CLI keeps its own store, entirely separate from the editor's: one directory per
/// conversation under `~/.cursor/chats/<workspace-hash>/<agent-id>/`, holding a `meta.json`
/// and a SQLite `store.db`. Nothing in `state.vscdb` mentions any of it, which is why CLI
/// spend arrived in the report as unattributable — the billing feed knew the cost, and
/// there was no local record to put a name to.
///
/// Two limits are structural rather than incidental, and both are stated wherever the
/// numbers surface:
///
/// - **Messages carry no timestamps.** Only the conversation has `createdAtMs` and
///   `updatedAtMs`, so the window can only be applied per conversation and the counts are
///   whole-conversation rather than window-scoped. Measured on a real account this is close
///   to exact: no CLI conversation spanned more than 1.5 hours, and the median was four
///   minutes, so the overlap a cycle boundary could cut through is tiny.
/// - **Roughly two thirds of the blobs are not plaintext** — the metadata carries a
///   `blobEncryptionKey`. What is readable is read; nothing is decrypted. Activity counts
///   from the CLI are therefore a floor. Cost is unaffected: that comes from the billing
///   API and is already exact.
public final class CliCatalog {
    private let root: URL
    private let timeZone: TimeZone

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/chats", isDirectory: true)
    }

    public init(root: URL = CliCatalog.defaultRoot, timeZone: TimeZone = .current) {
        self.root = root
        self.timeZone = timeZone
    }

    /// Everything the CLI recorded for conversations still active at or after `since`.
    public func digest(since: Date) -> ActivityDigest {
        let result = read(since: since)
        let unavailableSources: Set<ActivitySource> = result.unavailable ? [.cli] : []
        let conversations = result.conversations
        guard !conversations.isEmpty else {
            return ActivityDigest(
                tools: [], prompts: .empty, files: [], byConversation: [:], daily: [],
                unavailableSources: unavailableSources
            )
        }

        var tools: [String: Int] = [:]
        var servers: [String: String] = [:]
        var reads: [String: Int] = [:]
        var edits: [String: Int] = [:]
        var lengths: [Int] = []
        var perDay: [Date: (prompts: Int, tools: Int)] = [:]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        for conversation in conversations {
            for (name, count) in conversation.activity.tools {
                tools[name, default: 0] += count
                if let server = conversation.servers[name] { servers[name] = server }
            }
            for (ext, count) in conversation.readsByExtension { reads[ext, default: 0] += count }
            for (ext, count) in conversation.editsByExtension { edits[ext, default: 0] += count }
            lengths.append(contentsOf: conversation.activity.promptLengths)

            // The whole conversation lands on the day it started. Its span is minutes, so
            // spreading it would be false precision on data that has no per-message clock.
            if let started = conversation.activity.firstActivity {
                let day = calendar.startOfDay(for: started)
                var entry = perDay[day] ?? (0, 0)
                entry.prompts += conversation.activity.prompts
                entry.tools += conversation.activity.toolCalls
                perDay[day] = entry
            }
        }

        let sorted = lengths.sorted()
        return ActivityDigest(
            tools: tools
                .map { ToolUsage(name: $0.key, calls: $0.value, server: servers[$0.key]) }
                .sorted { ($0.calls, $1.name) > ($1.calls, $0.name) },
            prompts: PromptStats(
                count: sorted.count,
                medianChars: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                longestChars: sorted.last ?? 0,
                // The CLI takes its instruction as an argument rather than through a prompt
                // box, so there is no slash-command convention to rank.
                commands: []
            ),
            files: Set(reads.keys).union(edits.keys)
                .map { FileTypeUsage(ext: $0, reads: reads[$0] ?? 0, edits: edits[$0] ?? 0) }
                .sorted { ($0.operations, $1.ext) > ($1.operations, $0.ext) },
            byConversation: Dictionary(
                conversations.map { ($0.id, $0.activity) }, uniquingKeysWith: { first, _ in first }
            ),
            daily: perDay
                .map { DayActivity(day: $0.key, prompts: $0.value.prompts, toolCalls: $0.value.tools) }
                .sorted { $0.day < $1.day },
            unavailableSources: unavailableSources
        )
    }

    // MARK: - Reading

    private struct Conversation {
        let id: String
        let activity: ConversationActivity
        /// Tool name to MCP server, for the calls that went through one.
        let servers: [String: String]
        let readsByExtension: [String: Int]
        let editsByExtension: [String: Int]
    }

    private struct ReadResult {
        var conversations: [Conversation] = []
        /// Set when an existing store could not be fully read. An absent root is *not* a
        /// failure: never having used the CLI is a normal, quiet state.
        var unavailable = false
    }

    private func read(since: Date) -> ReadResult {
        let manager = FileManager.default
        var result = ReadResult()
        guard let workspaces = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else {
            if manager.fileExists(atPath: root.path) { result.unavailable = true }
            return result
        }

        for workspace in workspaces {
            guard let directories = try? manager.contentsOfDirectory(
                at: workspace, includingPropertiesForKeys: nil
            ) else {
                result.unavailable = true
                continue
            }
            for directory in directories {
                guard let meta = metadata(in: directory) else {
                    // A corrupt meta.json cannot place the conversation in the window, so
                    // it is skipped — but a present, unreadable meta is a failure to report.
                    if manager.fileExists(
                        atPath: directory.appendingPathComponent("meta.json").path
                    ) {
                        result.unavailable = true
                    }
                    continue
                }
                guard meta.updated >= since else { continue }
                let entry = conversation(at: directory, meta: meta)
                if !entry.storeReadable { result.unavailable = true }
                result.conversations.append(entry.conversation)
            }
        }
        return result
    }

    private struct Meta {
        let title: String?
        let cwd: String?
        let created: Date
        let updated: Date
    }

    private func metadata(in directory: URL) -> Meta? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let created = (object["createdAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let updated = (object["updatedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        guard let created else { return nil }
        return Meta(
            title: object["title"] as? String,
            cwd: object["cwd"] as? String,
            created: created,
            updated: updated ?? created
        )
    }

    /// Returns the conversation and whether its store was fully read. A missing `store.db`
    /// is fine — a conversation directory that has not finished writing contributes its
    /// metadata alone. A `store.db` that exists but cannot be opened, lacks the blobs
    /// table, or holds unreadable blobs is a partial read.
    private func conversation(
        at directory: URL, meta: Meta
    ) -> (conversation: Conversation, storeReadable: Bool) {
        var tools: [String: Int] = [:]
        var servers: [String: String] = [:]
        var reads: [String: Int] = [:]
        var edits: [String: Int] = [:]
        var lengths: [Int] = []
        var storeReadable = true

        let storeURL = directory.appendingPathComponent("store.db")
        if FileManager.default.fileExists(atPath: storeURL.path) {
            if let database = ReadOnlyDatabase(url: storeURL) {
                let queried = database.query("SELECT data FROM blobs") { row in
                    // Only the plaintext blobs are parsed. A blob that does not begin with
                    // `{` is either encrypted or a format this does not claim to understand,
                    // and is skipped rather than guessed at — and flagged, so the report
                    // knows the counts are a floor.
                    guard let text = row.text(0), text.hasPrefix("{"),
                          let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                            as? [String: Any] else {
                        storeReadable = false
                        return
                    }
                    let role = object["role"] as? String
                    let parts = object["content"] as? [[String: Any]] ?? []

                    if role == "user" {
                        let length = parts.compactMap { $0["text"] as? String }.joined().count
                        if length > 0 { lengths.append(length) }
                    }

                    for part in parts where part["type"] as? String == "tool-call" {
                        let arguments = part["args"] as? [String: Any] ?? [:]
                        var name = part["toolName"] as? String ?? "?"
                        var server: String?
                        // An MCP call names the bridge, not the work. Report what actually ran and
                        // keep the server alongside, matching how the editor's names decompose.
                        if name == "CallMcpTool" {
                            server = arguments["server"] as? String
                            name = arguments["toolName"] as? String ?? name
                        }
                        tools[name, default: 0] += 1
                        if let server { servers[name] = server }

                        if let path = arguments["path"] as? String {
                            let ext = Self.extension(of: path)
                            if Self.changesFiles(name) {
                                edits[ext, default: 0] += 1
                            } else {
                                reads[ext, default: 0] += 1
                            }
                        }
                    }
                }
                if !queried {
                    // The store opened but is not the CLI's shape.
                    storeReadable = false
                }
            } else {
                // The store exists but cannot be opened.
                storeReadable = false
            }
        }

        return (
            Conversation(
                id: directory.lastPathComponent,
                activity: ConversationActivity(
                    workspace: meta.cwd.map { ($0 as NSString).lastPathComponent },
                    workspacePath: meta.cwd,
                    mode: "cli",
                    prompts: lengths.count,
                    toolCalls: tools.values.reduce(0, +),
                    tools: tools,
                    firstActivity: meta.created,
                    lastActivity: meta.updated,
                    promptLengths: lengths,
                    fileTypes: reads.merging(edits, uniquingKeysWith: +),
                    source: .cli
                ),
                servers: servers,
                readsByExtension: reads,
                editsByExtension: edits
            ),
            storeReadable: storeReadable
        )
    }

    /// The CLI's writing tools. Everything else carrying a path is a read.
    private static func changesFiles(_ tool: String) -> Bool {
        ["Write", "StrReplace", "Edit", "Delete", "Create"].contains { tool.hasPrefix($0) }
    }

    private static func `extension`(of path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "(none)" : "." + ext
    }
}

// MARK: - Naming

extension CliCatalog: SessionNaming {
    /// Titles for CLI conversations, so a terminal agent's spend is named wherever a
    /// chat's is — the menu included, not only the report.
    ///
    /// Not window-filtered: a caller asking about an id wants its name whenever it ran.
    /// CLI agents have no parent, so `parentID` is always nil; the CLI has no subagents.
    public func records(for ids: [String]) -> [String: SessionRecord] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [:] }

        var found: [String: SessionRecord] = [:]
        let manager = FileManager.default
        let workspaces = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for workspace in workspaces {
            let directories = (try? manager.contentsOfDirectory(
                at: workspace, includingPropertiesForKeys: nil
            )) ?? []
            for directory in directories where wanted.contains(directory.lastPathComponent) {
                guard let title = metadata(in: directory)?.title, !title.isEmpty else { continue }
                found[directory.lastPathComponent] = SessionRecord(name: title, parentID: nil)
            }
        }
        return found
    }
}

/// Asks each source in turn and keeps the first answer.
///
/// Cursor's two front ends keep unrelated stores, so a conversation is named by whichever
/// one recorded it. Order is precedence: earlier sources win, though in practice the id
/// spaces do not overlap.
public final class CombinedNaming: SessionNaming {
    private let sources: [SessionNaming]

    public init(_ sources: [SessionNaming]) {
        self.sources = sources
    }

    public func records(for ids: [String]) -> [String: SessionRecord] {
        var combined: [String: SessionRecord] = [:]
        for source in sources {
            for (id, record) in source.records(for: ids) where combined[id] == nil {
                combined[id] = record
            }
        }
        return combined
    }
}
