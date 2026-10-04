import Foundation
import SQLite3
import Testing
@testable import ClaudeNotch

/// The 5-hour / weekly / monthly window math and the SQLite read behind opencode-go. The window
/// checks are pure (fixed rows, fixed `now`) so they pin the arithmetic, and the SQLite check uses
/// the same one-table fixture shape opencode writes.
@Suite struct OpencodeGoLocalUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func splitsSpendAcrossTheThreeWindows() {
        // A single $6 call one minute ago, against the 12/30/60 plan limits.
        let rows = [OpencodeGoLocalUsage.Row(at: now.addingTimeInterval(-60), cost: 6)]
        let w = OpencodeGoLocalUsage.windows(rows: rows, now: now)

        #expect(abs(w.session.usedFraction - 0.5) < 0.0001)
        #expect(abs(w.weekly.usedFraction - 0.2) < 0.0001)
        #expect(abs(w.monthly.usedFraction - 0.1) < 0.0001)
    }

    @Test func sessionWindowRollsAndSetsItsResetFromTheOldestRow() {
        let rows = [
            OpencodeGoLocalUsage.Row(at: now.addingTimeInterval(-6 * 3600), cost: 5),  // outside 5h
            OpencodeGoLocalUsage.Row(at: now.addingTimeInterval(-2 * 3600), cost: 3),
            OpencodeGoLocalUsage.Row(at: now.addingTimeInterval(-60), cost: 3),
        ]
        let w = OpencodeGoLocalUsage.windows(rows: rows, now: now)

        #expect(abs(w.session.used - 6) < 0.0001)   // the 6h-old call has rolled off
        // Reset is the oldest in-window call + 5 hours, not the wall clock.
        let expectedReset = now.addingTimeInterval(-2 * 3600 + 5 * 3600)
        #expect(abs(w.session.resetsAt.timeIntervalSince(expectedReset)) < 1)
        #expect(w.session.resetsAt > now)
    }

    @Test func weeklyResetIsTheEndOfTheUTCWeek() {
        let rows = [OpencodeGoLocalUsage.Row(at: now, cost: 1)]
        let w = OpencodeGoLocalUsage.windows(rows: rows, now: now)

        #expect(w.weekly.resetsAt > now)
        #expect(w.weekly.resetsAt.timeIntervalSince(now) <= 7 * 86_400)
    }

    @Test func monthWindowIsTheLocalCalendarMonth() {
        let calendar = Calendar.current
        let midMonth = calendar.date(from: DateComponents(year: 2027, month: 3, day: 15, hour: 12))!
        let lastMonth = calendar.date(from: DateComponents(year: 2027, month: 2, day: 28, hour: 12))!
        let rows = [
            OpencodeGoLocalUsage.Row(at: midMonth, cost: 6),
            OpencodeGoLocalUsage.Row(at: lastMonth, cost: 100),
        ]
        let w = OpencodeGoLocalUsage.windows(rows: rows, now: midMonth)

        // Only this calendar month's spend counts.
        #expect(abs(w.monthly.used - 6) < 0.0001)
        // Reset is the 1st of next month, local time.
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: midMonth))!
        let expectedEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        #expect(abs(w.monthly.resetsAt.timeIntervalSince(expectedEnd)) < 1)
    }

    @Test func clampsFractionAtOne() {
        let rows = [OpencodeGoLocalUsage.Row(at: now, cost: 1_000)]
        let w = OpencodeGoLocalUsage.windows(rows: rows, now: now)
        #expect(w.session.usedFraction == 1)
        #expect(w.weekly.usedFraction == 1)
        #expect(w.monthly.usedFraction == 1)
    }

    @Test func mapsWindowsOntoTheSharedSnapshotShape() {
        let rows = [OpencodeGoLocalUsage.Row(at: now.addingTimeInterval(-60), cost: 6)]
        let snapshot = OpencodeGoLocalUsage.snapshot(rows: rows, now: now)

        #expect(snapshot.provider == .opencodeGo)
        #expect(snapshot.source == "local estimate")
        #expect(snapshot.limits.map(\.label) == ["5-Hour", "7-Day", "Monthly"])
        #expect(snapshot.limits.first?.usedFraction == 0.5)
        #expect(snapshot.dailySeries.count == 7)
        #expect(snapshot.fetchedAt == now)
    }

    @Test func readsV2SessionMessageRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-go-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = root.appendingPathComponent("opencode.db")
        let createdMs = Int64((now.timeIntervalSince1970 - 60) * 1000)
        try Self.writeV2Fixture(at: database, createdMs: createdMs)

        let snapshot = try OpencodeGoLocalUsage.fetch(databaseURL: database, now: now)

        // The opencode-go row counts; the ollama row in the same table is ignored.
        #expect(snapshot.provider == .opencodeGo)
        #expect(snapshot.limits.first?.usedFraction == 0.5)
        #expect(abs((snapshot.limits.last?.usedFraction ?? 0) - 0.1) < 0.0001)
    }

    @Test func fallsBackToTheV1MessageTable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-go-v1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = root.appendingPathComponent("opencode.db")
        let createdMs = Int64((now.timeIntervalSince1970 - 60) * 1000)
        try Self.writeV1Fixture(at: database, createdMs: createdMs, cost: 6)

        let snapshot = try OpencodeGoLocalUsage.fetch(databaseURL: database, now: now)
        #expect(snapshot.limits.first?.usedFraction == 0.5)
        // V1 has no title here, so the session falls back to the project folder's basename.
        #expect(snapshot.sessions.first?.name == "v1proj")
    }

    @Test func v2SessionsAndTopModelComeFromTheSessionTable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-go-v2-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = root.appendingPathComponent("opencode.db")
        let createdMs = Int64((now.timeIntervalSince1970 - 60) * 1000)
        try Self.writeV2Fixture(at: database, createdMs: createdMs)

        let snapshot = try OpencodeGoLocalUsage.fetch(databaseURL: database, now: now)
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.name == "Refactor the parser")
        #expect(abs((snapshot.sessions.first?.cost ?? 0) - 6) < 0.0001)
        #expect(snapshot.stats.first { $0.id == "top-model" }?.value == "qwen3.8-flash")
    }

    @Test func v2RowsWithoutCostOrModelStillCount() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-go-v2-bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = root.appendingPathComponent("opencode.db")
        let createdMs = Int64((now.timeIntervalSince1970 - 60) * 1000)
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw OpencodeGoLocalUsageError.historyUnavailable("fixture open failed")
        }
        defer { sqlite3_close(db) }
        // A quota error: the provider matches but there is no cost or model id.
        let data = "{\"time\":{\"created\":\(createdMs)},\"model\":{\"providerID\":\"opencode-go\"}}"
        let sql = """
            CREATE TABLE session_message (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL,
              seq INTEGER NOT NULL, time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            INSERT INTO session_message VALUES ('m1','s1','assistant',1,\(createdMs),\(createdMs),'\(data)');
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpencodeGoLocalUsageError.historyUnavailable("fixture write failed")
        }

        let snapshot = try OpencodeGoLocalUsage.fetch(databaseURL: database, now: now)
        #expect(snapshot.limits.first?.usedFraction == 0)
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.cost == 0)
        #expect(snapshot.stats.contains { $0.id == "top-model" } == false)
    }

    @Test func sessionsLeftIsNilWhenNothingIsBurning() {
        let flat = [OpencodeGoLocalUsage.Row(at: now.addingTimeInterval(-3600), cost: 0)]
        #expect(OpencodeGoLocalUsage.sessionsLeft(rows: flat, now: now) == nil)
        // A $6 call that already rolled out of the 5-hour window: no current slope to trust.
        let stale = [OpencodeGoLocalUsage.Row(at: now.addingTimeInterval(-6 * 3600), cost: 6)]
        #expect(OpencodeGoLocalUsage.sessionsLeft(rows: stale, now: now) == nil)
    }

    @Test func sessionsLeftCountsTheWeeklyReserveWhenBurning() {
        // $6 burned over the last hour: on pace to exhaust the $12 window before it resets, so
        // each remaining session is a full one. Weekly $30 - $6 = $24 -> two $12 sessions.
        let rows = [OpencodeGoLocalUsage.Row(at: now.addingTimeInterval(-3600), cost: 6)]
        #expect(OpencodeGoLocalUsage.sessionsLeft(rows: rows, now: now) == 2)
    }

    @Test func missingDatabaseIsNotDetected() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).db")
        #expect(throws: OpencodeGoLocalUsageError.self) {
            try OpencodeGoLocalUsage.fetch(databaseURL: missing, now: now)
        }
    }

    /// opencode V2: assistant turns live in `session_message`, provider under `$.model.providerID`.
    private static func writeV2Fixture(at url: URL, createdMs: Int64) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw OpencodeGoLocalUsageError.historyUnavailable("fixture open failed")
        }
        defer { sqlite3_close(database) }

        let ours = "{\"time\":{\"created\":\(createdMs)},\"cost\":6,"
            + "\"model\":{\"id\":\"qwen3.8-flash\",\"providerID\":\"opencode-go\"}}"
        let theirs = "{\"time\":{\"created\":\(createdMs)},\"cost\":999,"
            + "\"model\":{\"id\":\"qwen3.5-9b\",\"providerID\":\"ollama\"}}"
        let sql = """
            CREATE TABLE session_v2 (
              id TEXT PRIMARY KEY, directory TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '');
            CREATE TABLE session_message (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL,
              seq INTEGER NOT NULL, time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            INSERT INTO session_v2 VALUES ('s1', '/home/agent/work/thing', 'Refactor the parser');
            INSERT INTO session_message VALUES ('m1', 's1', 'assistant', 1, \(createdMs), \(createdMs), '\(ours)');
            INSERT INTO session_message VALUES ('m2', 's1', 'assistant', 2, \(createdMs), \(createdMs), '\(theirs)');
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpencodeGoLocalUsageError.historyUnavailable("fixture write failed")
        }
    }

    /// opencode V1: assistant turns live in `message` with a top-level providerID.
    private static func writeV1Fixture(at url: URL, createdMs: Int64, cost: Double) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw OpencodeGoLocalUsageError.historyUnavailable("fixture open failed")
        }
        defer { sqlite3_close(database) }

        let data = "{\"time\":{\"created\":\(createdMs)},\"cost\":\(cost),"
            + "\"providerID\":\"opencode-go\",\"role\":\"assistant\",\"modelID\":\"kimi-k2.5\"}"
        let sql = """
            CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '');
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER NOT NULL, data TEXT NOT NULL);
            INSERT INTO session VALUES ('s1', '/home/agent/work/v1proj', '');
            INSERT INTO message (id, session_id, time_created, data) VALUES ('message-1', 's1', \(createdMs), '\(data)');
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpencodeGoLocalUsageError.historyUnavailable("fixture write failed")
        }
    }
}
