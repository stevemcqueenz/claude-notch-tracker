import Foundation
import SQLite3

enum OpencodeGoLocalUsageError: LocalizedError {
    case notDetected
    case historyUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notDetected: "opencode-go not detected"
        case .historyUnavailable(let message): "opencode-go local usage unavailable: \(message)"
        }
    }
}

/// opencode-go usage, read entirely from opencode's local SQLite history.
///
/// opencode writes one assistant `message` row per model call, carrying the call's USD cost and
/// the gateway `providerID`. The account quota is not local, so the quota windows are
/// reconstructed from that spend: a rolling 5-hour window, the current UTC week, and the current
/// month. Limits are the documented opencode-go plan allowances (USD), and each window reports
/// `used / limit` — the UI renders the remainder.
///
/// The reader never writes (read-only open, with the same `immutable=1` fallback the Antigravity
/// store uses for a live WAL). Anything that fails to decode is skipped, so a schema change costs
/// accuracy, never a crash.
enum OpencodeGoLocalUsage {
    struct Row: Equatable, Sendable {
        let at: Date
        let cost: Double
        /// The model that served the turn, when the payload carries one.
        let model: String?
        /// The conversation the turn belongs to, plus its title/directory when the store exposes them.
        let sessionID: String?
        let title: String?
        let directory: String?

        init(at: Date, cost: Double, model: String? = nil, sessionID: String? = nil,
             title: String? = nil, directory: String? = nil) {
            self.at = at
            self.cost = cost
            self.model = model
            self.sessionID = sessionID
            self.title = title
            self.directory = directory
        }
    }

    struct Window: Equatable, Sendable {
        let used: Double
        let limit: Double
        let resetsAt: Date

        var usedFraction: Double {
            guard limit > 0, used.isFinite else { return 0 }
            return min(1, max(0, used / limit))
        }
    }

    struct Windows: Equatable, Sendable {
        let session: Window
        let weekly: Window
        let monthly: Window
    }

    static let sessionLimit = 12.0
    static let weeklyLimit = 30.0
    static let monthlyLimit = 60.0
    private static let fiveHours: TimeInterval = 5 * 60 * 60

    // MARK: fetch

    static func fetch(databaseURL: URL = OpencodeGoPaths.databaseURL,
                      now: Date = Date()) throws -> ProviderUsageSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw OpencodeGoLocalUsageError.notDetected
        }
        let rows = try readRows(databaseURL: databaseURL)
        guard !rows.isEmpty else {
            throw OpencodeGoLocalUsageError.historyUnavailable("no local usage rows")
        }
        return snapshot(rows: rows, now: now)
    }

    // MARK: window math

    static func windows(rows: [Row], now: Date) -> Windows {
        let sessionStart = now.addingTimeInterval(-fiveHours)
        let weekStart = startOfUTCWeek(now: now)
        let weekEnd = weekStart.addingTimeInterval(7 * 86_400)
        let month = monthBounds(now: now)

        var sessionCost = 0.0
        var weeklyCost = 0.0
        var monthlyCost = 0.0
        var oldestSession = now
        for row in rows {
            // Upper bound is inclusive: a call logged this instant belongs to this window.
            // (Future-dated rows from clock skew stay out.)
            if row.at >= sessionStart, row.at <= now {
                sessionCost += row.cost
                oldestSession = min(oldestSession, row.at)
            }
            if row.at >= weekStart, row.at < weekEnd { weeklyCost += row.cost }
            if row.at >= month.start, row.at < month.end { monthlyCost += row.cost }
        }

        return Windows(
            session: Window(used: sessionCost, limit: sessionLimit,
                            resetsAt: oldestSession.addingTimeInterval(fiveHours)),
            weekly: Window(used: weeklyCost, limit: weeklyLimit, resetsAt: weekEnd),
            monthly: Window(used: monthlyCost, limit: monthlyLimit, resetsAt: month.end)
        )
    }

    static func snapshot(rows: [Row], now: Date) -> ProviderUsageSnapshot {
        let w = windows(rows: rows, now: now)
        let today = Calendar.current.startOfDay(for: now)
        let dayCost = dayCosts(rows: rows)
        let todayCost = rows.isEmpty ? nil : (dayCost[today] ?? 0)
        let lifetimeCost = rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.cost }

        var stats: [UsageStatMetric] = []
        if let model = topModel(rows: rows) {
            stats.append(UsageStatMetric(id: "top-model", label: "top model",
                                         value: model, subtitle: nil))
        }
        if let left = sessionsLeft(rows: rows, now: now) {
            stats.append(UsageStatMetric(id: "sessions-left", label: "Sessions left",
                                         value: "~\(left) left", subtitle: "estimate"))
        }

        return ProviderUsageSnapshot(
            provider: .opencodeGo,
            limits: [
                UsageLimitMetric(id: "opencode-session", label: "5-Hour",
                                 usedFraction: w.session.usedFraction, resetsAt: w.session.resetsAt,
                                 window: 5 * 3600),
                UsageLimitMetric(id: "opencode-weekly", label: "7-Day",
                                 usedFraction: w.weekly.usedFraction, resetsAt: w.weekly.resetsAt,
                                 window: 7 * 86_400),
                UsageLimitMetric(id: "opencode-monthly", label: "Monthly",
                                 usedFraction: w.monthly.usedFraction, resetsAt: w.monthly.resetsAt,
                                 window: 30 * 86_400),
            ],
            stats: stats,
            todayCost: todayCost,
            lifetimeCost: lifetimeCost,
            dailySeries: dailySeries(rows: rows, now: now),
            chartTitle: "last 7 days · local",
            sessions: sessions(rows: rows),
            source: "local estimate",
            fetchedAt: now
        )
    }

    /// Oldest-first spend for the last seven local days. Shared by the local snapshot and the web
    /// path (which has server meters but no daily buckets); empty rows stay empty.
    static func dailySeries(rows: [Row], now: Date) -> [DailyUsagePoint] {
        guard !rows.isEmpty else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let dayCost = dayCosts(rows: rows)
        return (0..<7).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return DailyUsagePoint(date: day, tokens: 0, cost: dayCost[day] ?? 0)
        }
    }

    /// Best-effort local daily spend for a caller that already has server numbers: never throws,
    /// and an unreadable/empty store just means no series rather than no web numbers.
    static func fetchDailySeries(databaseURL: URL = OpencodeGoPaths.databaseURL,
                                 now: Date = Date()) -> [DailyUsagePoint] {
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let rows = try? readRows(databaseURL: databaseURL) else { return [] }
        return dailySeries(rows: rows, now: now)
    }

    /// Recent conversations by spend, newest first. Rows with no session id are window-only.
    static func sessions(rows: [Row]) -> [UsageSessionMetric] {
        var bySession: [String: (name: String, cost: Double, last: Date)] = [:]
        for row in rows {
            guard let id = row.sessionID else { continue }
            let name = sessionName(title: row.title, directory: row.directory)
            var entry = bySession[id] ?? (name, 0, .distantPast)
            entry.cost += row.cost
            entry.last = max(entry.last, row.at)
            if entry.name == "session", name != "session" { entry.name = name }
            bySession[id] = entry
        }
        return bySession.map {
            UsageSessionMetric(id: $0.key, name: $0.value.name, cost: $0.value.cost,
                               tokens: nil, last: $0.value.last)
        }
        .sorted { $0.last > $1.last }
    }

    /// A conversation's title, else its project folder (Claude's cwd-basename fallback), else "session".
    static func sessionName(title: String?, directory: String?) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let directory, !directory.isEmpty {
            return (directory as NSString).lastPathComponent
        }
        return "session"
    }

    /// The model that spent the most locally, when the payloads carry one.
    static func topModel(rows: [Row]) -> String? {
        var byModel: [String: Double] = [:]
        for row in rows where row.cost > 0 {
            guard let model = row.model, !model.isEmpty else { continue }
            byModel[model, default: 0] += row.cost
        }
        return byModel.max { $0.value < $1.value }?.key
    }

    /// How many more full 5-hour allowances the remaining weekly budget funds, at the current
    /// 5-hour burn. nil unless the window is genuinely burning (a positive slope) and the limit
    /// lands before the window resets; anything else would be a number we didn't earn. Mirrors
    /// `AppModel.etaToLimit`'s slope gate.
    static func sessionsLeft(rows: [Row], now: Date) -> Int? {
        let w = windows(rows: rows, now: now)
        let sessionStart = now.addingTimeInterval(-fiveHours)
        let burning = rows.filter { $0.at >= sessionStart && $0.at <= now && $0.cost > 0 }
        guard let oldest = burning.map(\.at).min() else { return nil }
        let span = now.timeIntervalSince(oldest)
        guard span > 60 else { return nil }
        let slope = burning.reduce(0) { $0 + $1.cost } / span   // dollars per second
        guard slope > 0 else { return nil }
        let remaining = sessionLimit - w.session.used
        guard remaining > 0 else { return nil }
        guard remaining / slope < w.session.resetsAt.timeIntervalSince(now) else { return nil }
        return Int(max(0, weeklyLimit - w.weekly.used) / sessionLimit)
    }

    private static func dayCosts(rows: [Row]) -> [Date: Double] {
        Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.at) }
            .mapValues { $0.reduce(0) { $0 + $1.cost } }
    }

    /// Monday 00:00 UTC, matching how opencode-go meters its weekly window.
    private static func startOfUTCWeek(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                           from: now)) ?? now
    }

    /// The current calendar month in the local timezone: the 1st at 00:00 through the 1st of the
    /// next month.
    private static func monthBounds(now: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }

    // MARK: sqlite

    private static func readRows(databaseURL: URL) throws -> [Row] {
        guard let handle = open(databaseURL) else {
            throw OpencodeGoLocalUsageError.historyUnavailable("could not open opencode.db")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 250)

        let sql: String
        let sessionTable: String?
        if hasTable("session_message", handle: handle) {
            sql = v2UsageSQL
            sessionTable = hasTable("session_v2", handle: handle) ? "session_v2" : nil
        } else if hasTable("part", handle: handle) {
            sql = partUsageSQL
            sessionTable = hasTable("session", handle: handle) ? "session" : nil
        } else {
            sql = messageUsageSQL
            sessionTable = hasTable("session", handle: handle) ? "session" : nil
        }
        // Titles/directories are a separate best-effort lookup, so a store without the session
        // table still yields usage rows (just unnamed) instead of failing the whole read.
        let metaByID = sessionTable.map { sessionMeta(table: $0, handle: handle) } ?? [:]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw OpencodeGoLocalUsageError.historyUnavailable("unreadable usage query")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let createdMs = sqlite3_column_int64(statement, 0)
            let cost = sqlite3_column_double(statement, 1)
            let model = text(statement, 2)
            let sessionID = text(statement, 3)
            guard createdMs > 0, cost >= 0, cost.isFinite else { continue }
            let meta = sessionID.flatMap { metaByID[$0] }
            rows.append(Row(at: Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000),
                            cost: cost, model: model, sessionID: sessionID,
                            title: meta?.title, directory: meta?.directory))
        }
        return rows
    }

    /// Title + directory for every conversation, keyed by session id. Best-effort: a table that
    /// doesn't answer leaves rows nameless rather than failing the whole read.
    private static func sessionMeta(table: String, handle: OpaquePointer)
        -> [String: (title: String?, directory: String?)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT id, title, directory FROM \(table)",
                                 -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return [:]
        }
        defer { sqlite3_finalize(statement) }
        var meta: [String: (title: String?, directory: String?)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { continue }
            meta[id] = (text(statement, 1), text(statement, 2))
        }
        return meta
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    private static let providerMessagesSQL = """
        SELECT
          id AS messageID,
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost,
          json_type(data, '$.cost') IN ('integer', 'real') AS hasCost,
          COALESCE(json_extract(data, '$.modelID'), json_extract(data, '$.model.id')) AS model,
          session_id AS sessionID
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.providerID') = 'opencode-go'
          AND json_extract(data, '$.role') = 'assistant'
        """

    private static let messageUsageSQL = """
        SELECT createdMs, cost, model, sessionID FROM (\(providerMessagesSQL)) WHERE hasCost
        """

    /// opencode V2 stores assistant turns in `session_message`; the provider lives under
    /// `$.model.providerID` and the model under `$.model.id`. Rows without a cost (e.g. a quota
    /// error) read as 0 and still count, so the panel shows the window rather than falling back
    /// to unavailable.
    private static let v2UsageSQL = """
        SELECT
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost,
          json_extract(data, '$.model.id') AS model,
          session_id AS sessionID
        FROM session_message
        WHERE type = 'assistant'
          AND json_valid(data)
          AND json_extract(data, '$.model.providerID') = 'opencode-go'
        """

    private static let partUsageSQL = """
        WITH provider_messages AS (\(providerMessagesSQL))
        SELECT
          CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
            AS createdMs,
          CAST(json_extract(p.data, '$.cost') AS REAL) AS cost,
          m.model AS model,
          m.sessionID AS sessionID
        FROM part p
        JOIN provider_messages m ON m.messageID = p.message_id
        WHERE json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
        UNION ALL
        SELECT createdMs, cost, model, sessionID FROM provider_messages m
        WHERE hasCost
          AND NOT EXISTS (
            SELECT 1 FROM part p
            WHERE p.message_id = m.messageID
              AND json_valid(p.data)
              AND json_extract(p.data, '$.type') = 'step-finish'
              AND json_type(p.data, '$.cost') IN ('integer', 'real')
          )
        """

    private static func hasTable(_ name: String, handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle,
                                 "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
                                 -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return false
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Read-only; never disturbs a store opencode owns. A live WAL can refuse the plain open, so
    /// fall back to `immutable=1` (reads the main file and ignores the WAL).
    private static func open(_ url: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            return handle
        }
        sqlite3_close(handle)
        handle = nil

        guard let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              sqlite3_open_v2("file:\(encoded)?immutable=1", &handle,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }
}
