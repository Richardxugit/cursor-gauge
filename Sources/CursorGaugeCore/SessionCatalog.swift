import Foundation

/// Looks up chat names and subagent parentage in Cursor's local store.
///
/// Reads `composerHeaders`, not the `composerData` blobs in `cursorDiskKV`. The header
/// table is keyed by `composerId` and carries the same names and the same parent links —
/// verified against the blobs with no mismatches — while the blobs average 91 KB and
/// reach 692 KB, so resolving a cycle's worth from them would move megabytes per poll.
///
/// Every failure here is swallowed. Session names are a garnish on the gauge; an
/// unreadable database costs the user names, never numbers.
public final class SessionCatalog {
    private let databaseURL: URL
    private var cache: [String: SessionRecord] = [:]
    private let lock = NSLock()

    /// A chat spawned by a chat spawned by a chat is already unusual; four hops is well
    /// past anything Cursor produces and keeps a malformed chain bounded.
    private static let maxParentDepth = 4
    /// SQLite's default host-parameter ceiling is 999.
    private static let batchSize = 200

    public init(databaseURL: URL = TokenStore.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    public func forget() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
    }

    /// Resolves `ids` and, transitively, their parents.
    ///
    /// Parents are followed because one may have billed nothing itself and so never appear
    /// in the usage events, yet still be the chat everything hangs off.
    public func records(for ids: [String]) -> [String: SessionRecord] {
        lock.lock(); defer { lock.unlock() }

        var resolved: [String: SessionRecord] = [:]
        var wanted = Set(ids)

        for _ in 0...Self.maxParentDepth {
            let missing = wanted.filter { resolved[$0] == nil }
            guard !missing.isEmpty else { break }

            for id in missing where cache[id] != nil {
                resolved[id] = cache[id]
            }
            let uncached = missing.filter { cache[$0] == nil }
            if !uncached.isEmpty {
                for (id, record) in fetch(Array(uncached)) {
                    cache[id] = record
                    resolved[id] = record
                }
            }

            // Ids absent from the table stay absent — recorded so we neither re-query them
            // nor mistake them for pending work.
            for id in missing where resolved[id] == nil {
                resolved[id] = SessionRecord(name: nil, parentID: nil)
                cache[id] = resolved[id]
            }

            let parents = resolved.values.compactMap(\.parentID)
            let next = Set(parents).subtracting(resolved.keys)
            guard !next.isEmpty else { break }
            wanted.formUnion(next)
        }

        // Absent rows were only placeholders; hand back nothing rather than a false name.
        return resolved.filter { $0.value.name != nil || $0.value.parentID != nil }
    }

    // MARK: - SQLite

    private func fetch(_ ids: [String]) -> [String: SessionRecord] {
        guard let database = ReadOnlyDatabase(url: databaseURL) else { return [:] }

        var found: [String: SessionRecord] = [:]
        for chunk in stride(from: 0, to: ids.count, by: Self.batchSize).map({
            Array(ids[$0..<min($0 + Self.batchSize, ids.count)])
        }) {
            // json_extract runs inside SQLite, so only the two short strings cross into
            // Swift rather than the whole row.
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            database.query("""
                SELECT composerId,
                       json_extract(value, '$.name'),
                       json_extract(value, '$.subagentInfo.parentComposerId')
                FROM composerHeaders WHERE composerId IN (\(placeholders))
                """, chunk) { row in
                guard let id = row.text(0) else { return }
                found[id] = SessionRecord(name: row.text(1), parentID: row.text(2))
            }
        }
        return found
    }
}
