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
            if row.at >= sessionStart, row.at < now {
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
        let dayCosts = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.at) }
            .mapValues { $0.reduce(0) { $0 + $1.cost } }
        let todayCost = rows.isEmpty ? nil : (dayCosts[today] ?? 0)
        let lifetimeCost = rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.cost }

        var series: [DailyUsagePoint] = []
        if !rows.isEmpty {
            let calendar = Calendar.current
            series = (0..<7).reversed().compactMap { back in
                guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
                return DailyUsagePoint(date: day, tokens: 0, cost: dayCosts[day] ?? 0)
            }
        }

        return ProviderUsageSnapshot(
            provider: .opencodeGo,
            limits: [
                UsageLimitMetric(id: "opencode-session", label: "5-Hour",
                                 usedFraction: w.session.usedFraction, resetsAt: w.session.resetsAt),
                UsageLimitMetric(id: "opencode-weekly", label: "7-Day",
                                 usedFraction: w.weekly.usedFraction, resetsAt: w.weekly.resetsAt),
                UsageLimitMetric(id: "opencode-monthly", label: "Monthly",
                                 usedFraction: w.monthly.usedFraction, resetsAt: w.monthly.resetsAt),
            ],
            todayCost: todayCost,
            lifetimeCost: lifetimeCost,
            dailySeries: series,
            chartTitle: "last 7 days · local",
            source: "local",
            fetchedAt: now
        )
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
        if hasTable("session_message", handle: handle) {
            sql = v2UsageSQL
        } else if hasTable("part", handle: handle) {
            sql = partUsageSQL
        } else {
            sql = messageUsageSQL
        }
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
            guard createdMs > 0, cost >= 0, cost.isFinite else { continue }
            rows.append(Row(at: Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000), cost: cost))
        }
        return rows
    }

    private static let providerMessagesSQL = """
        SELECT
          id AS messageID,
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost,
          json_type(data, '$.cost') IN ('integer', 'real') AS hasCost
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.providerID') = 'opencode-go'
          AND json_extract(data, '$.role') = 'assistant'
        """

    private static let messageUsageSQL = """
        SELECT createdMs, cost FROM (\(providerMessagesSQL)) WHERE hasCost
        """

    /// opencode V2 stores assistant turns in `session_message`; the provider lives under
    /// `$.model.providerID` and there is no `message`/`part` table to join. Rows without a cost
    /// (e.g. a quota error) read as 0 and still count, so the panel shows the window rather than
    /// falling back to unavailable.
    private static let v2UsageSQL = """
        SELECT
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost
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
          CAST(json_extract(p.data, '$.cost') AS REAL) AS cost
        FROM part p
        JOIN provider_messages m ON m.messageID = p.message_id
        WHERE json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
        UNION ALL
        SELECT createdMs, cost FROM provider_messages m
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
