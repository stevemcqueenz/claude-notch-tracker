import Foundation
import SQLite3

/// Token totals read out of Antigravity's local conversation stores.
///
/// The quota feed reports how much allowance is *left*; nothing in it says what was actually
/// spent, on which model, or in which project. These are the numbers that fill the chart, the
/// stat tiles, and the sessions list — and being local, they survive an offline or signed-out
/// `agy`, which the quota call does not.
struct AntigravityLocalStats: Sendable, Equatable {
    /// startOfDay → input + output tokens.
    var tokensByDay: [Date: Int] = [:]
    var totalTokens = 0
    var totalTurns = 0
    var thinkingTokens = 0
    /// Model name → turns served by it.
    var turnsByModel: [String: Int] = [:]
    var conversations: [Conversation] = []

    struct Conversation: Sendable, Equatable {
        let id: String
        var tokens: Int
        var turns: Int
        var last: Date
        /// Local folder the conversation ran against, when the store records one.
        var workspace: String?
    }

    var isEmpty: Bool { totalTurns == 0 }

    /// The model that served the most turns.
    var topModel: String? {
        turnsByModel.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }?.key
    }

    func tokens(on day: Date) -> Int {
        tokensByDay[Calendar.current.startOfDay(for: day)] ?? 0
    }
}

/// Scans the conversation stores, caching each one by modification date so a poll re-reads only
/// what actually changed.
///
/// Not an actor by design: every method blocks on file and SQLite I/O, and actors run on the
/// cooperative pool where blocking starves unrelated tasks. The owning provider confines all
/// calls to its own utility queue instead.
final class AntigravityLocalStore: @unchecked Sendable {
    /// A single store's contribution, kept so an unchanged file costs one stat() and no parsing.
    private struct CachedStore {
        let modified: Date
        let stats: AntigravityLocalStats
    }

    private var cache: [URL: CachedStore] = [:]
    private let locateStores: @Sendable () -> [URL]

    /// `locateStores` is injectable so tests can point the reader at a fixture directory —
    /// `FileManager.homeDirectoryForCurrentUser` ignores `$HOME`, so there is no way to redirect
    /// the real lookup from a test without it.
    init(locateStores: @escaping @Sendable () -> [URL] = { AntigravityPaths.conversationStores() }) {
        self.locateStores = locateStores
    }

    func scan() -> AntigravityLocalStats {
        let stores = locateStores()
        var merged = AntigravityLocalStats()
        var seen: Set<URL> = []

        for url in stores {
            seen.insert(url)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast

            let stats: AntigravityLocalStats
            if let cached = cache[url], cached.modified == modified {
                stats = cached.stats
            } else {
                stats = Self.read(store: url)
                cache[url] = CachedStore(modified: modified, stats: stats)
            }
            merged.merge(stats)
        }

        // Drop stores that have since been deleted, so the cache tracks the directory rather
        // than growing for the life of the process.
        cache = cache.filter { seen.contains($0.key) }
        merged.conversations.sort { $0.last > $1.last }
        return merged
    }

    /// Whether a store can be opened at all — used by the integration test to tell an empty
    /// history apart from stores that silently failed to open.
    static func canRead(_ url: URL) -> Bool {
        guard let handle = open(url) else { return false }
        sqlite3_close(handle)
        return true
    }

    // MARK: reading one store

    /// Field numbers inside a `gen_metadata` blob.
    ///
    /// Antigravity ships no schema for these, so the layout below was read off the wire format
    /// and checked against a full local history: `output == thinking + text` held for every one
    /// of 2,638 turns, which is what pins fields 3, 9 and 10 to their meanings. Anything that
    /// fails to decode is skipped, so a schema change costs accuracy, never a crash.
    private enum Field {
        static let record = 1           // the turn record wrapping everything below
        static let usage = 4            // token counts for this turn
        static let inputTokens = 2      //   prompt tokens sent
        static let outputTokens = 3     //   thinking + text
        static let thinkingTokens = 9   //   reasoning portion of the output
        static let timing = 9           // record.9 — wall-clock timing for the turn
        static let startedAt = 4        //   timing.4 — a google.protobuf.Timestamp
        static let seconds = 1          //     timestamp.1 — unix seconds
        static let model = 19           // record.19 — e.g. "gemini-3.7-flash"
        static let workspace = 7        // trajectory_metadata_blob.7 — "file:///path/to/project"
    }

    /// Guards against a misparse turning one corrupt row into billions of tokens.
    private static let maximumPlausibleTokens = 100_000_000

    private static func read(store url: URL) -> AntigravityLocalStats {
        var stats = AntigravityLocalStats()
        guard let handle = open(url) else { return stats }
        defer { sqlite3_close(handle) }

        let id = url.deletingPathExtension().lastPathComponent
        let workspace = self.workspace(in: handle)
        var tokens = 0
        var turns = 0
        var last = Date.distantPast
        let calendar = Calendar.current

        query(handle, "SELECT data FROM gen_metadata") { statement in
            guard let pointer = sqlite3_column_blob(statement, 0) else { return }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0 else { return }
            let blob = Data(bytes: pointer, count: count)

            guard let record = ProtobufMessage(blob).message(Field.record),
                  let usage = record.message(Field.usage) else { return }

            let input = Int(usage.varint(Field.inputTokens) ?? 0)
            let output = Int(usage.varint(Field.outputTokens) ?? 0)
            let thinking = Int(usage.varint(Field.thinkingTokens) ?? 0)
            guard input >= 0, output >= 0,
                  input < maximumPlausibleTokens, output < maximumPlausibleTokens else { return }

            let total = input + output
            tokens += total
            turns += 1
            stats.thinkingTokens += max(0, min(thinking, output))

            if let model = record.string(Field.model), !model.isEmpty {
                stats.turnsByModel[model, default: 0] += 1
            }

            if let seconds = record.message(Field.timing)?
                .message(Field.startedAt)?
                .varint(Field.seconds), seconds > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(seconds))
                stats.tokensByDay[calendar.startOfDay(for: date), default: 0] += total
                if date > last { last = date }
            }
        }

        guard turns > 0 else { return stats }
        stats.totalTokens = tokens
        stats.totalTurns = turns
        stats.conversations = [
            .init(id: id, tokens: tokens, turns: turns,
                  last: last == .distantPast ? Date.distantPast : last,
                  workspace: workspace)
        ]
        return stats
    }

    /// The project folder a conversation ran in, if the store recorded one.
    private static func workspace(in handle: OpaquePointer) -> String? {
        var uri: String?
        query(handle, "SELECT data FROM trajectory_metadata_blob LIMIT 1") { statement in
            guard let pointer = sqlite3_column_blob(statement, 0) else { return }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0 else { return }
            uri = ProtobufMessage(Data(bytes: pointer, count: count)).string(Field.workspace)
        }
        guard let uri, !uri.isEmpty else { return nil }
        // Stored as a file:// URL; the display name only ever wants the folder.
        let path = URL(string: uri)?.path ?? uri
        let folder = (path as NSString).lastPathComponent
        return folder.isEmpty ? nil : folder
    }

    // MARK: sqlite

    /// Opens read-only, and never writes: the app must not disturb a store the CLI owns.
    private static func open(_ url: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            return handle
        }
        sqlite3_close(handle)
        handle = nil

        // A store being written right now can refuse a plain read-only open, because replaying
        // its WAL would mean touching the -shm file. `immutable=1` reads the main database and
        // ignores the WAL — a slightly stale number beats an empty panel, and the next poll
        // picks up the rest.
        guard let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              sqlite3_open_v2("file:\(encoded)?immutable=1", &handle,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    private static func query(_ handle: OpaquePointer, _ sql: String,
                              row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }
}

private extension AntigravityLocalStats {
    mutating func merge(_ other: AntigravityLocalStats) {
        totalTokens += other.totalTokens
        totalTurns += other.totalTurns
        thinkingTokens += other.thinkingTokens
        tokensByDay.merge(other.tokensByDay, uniquingKeysWith: +)
        turnsByModel.merge(other.turnsByModel, uniquingKeysWith: +)
        conversations.append(contentsOf: other.conversations)
    }
}
