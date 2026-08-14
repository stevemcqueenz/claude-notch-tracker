import Foundation
import SQLite3
import Testing
@testable import ClaudeNotch

@Suite struct ProtobufMessageTests {
    @Test func readsScalarsAndNestedMessages() {
        let inner = PB.varint(field: 1, value: 1_786_707_127)
        let message = PB.varint(field: 2, value: 14_844)
            + PB.varint(field: 3, value: 138)
            + PB.string(field: 19, value: "gemini-3.7-flash")
            + PB.message(field: 9, payload: inner)

        let parsed = ProtobufMessage(message)
        #expect(parsed.varint(2) == 14_844)
        #expect(parsed.varint(3) == 138)
        #expect(parsed.string(19) == "gemini-3.7-flash")
        #expect(parsed.message(9)?.varint(1) == 1_786_707_127)
    }

    @Test func absentFieldsAreNil() {
        let parsed = ProtobufMessage(PB.varint(field: 1, value: 5))
        #expect(parsed.varint(7) == nil)
        #expect(parsed.message(7) == nil)
        #expect(parsed.string(7) == nil)
    }

    @Test func skipsUnrequestedFieldsOfEveryWireType() {
        // 64-bit, 32-bit and length-delimited fields sit between the two varints we want, so a
        // wrong skip width would surface as a misread rather than a nil.
        var message = PB.varint(field: 1, value: 7)
        message += PB.fixed64(field: 2, value: 0xDEAD_BEEF_FEED_FACE)
        message += PB.fixed32(field: 3, value: 0xCAFE_BABE)
        message += PB.string(field: 4, value: "ignored")
        message += PB.varint(field: 5, value: 99)

        let parsed = ProtobufMessage(message)
        #expect(parsed.varint(1) == 7)
        #expect(parsed.varint(5) == 99)
    }

    @Test func truncatedBufferDoesNotCrash() {
        let full = PB.string(field: 1, value: "gemini-3.7-flash")
        for length in 0..<full.count {
            let parsed = ProtobufMessage(full.prefix(length))
            _ = parsed.string(1)
            _ = parsed.varint(1)
        }
    }

    @Test func rejectsLengthBeyondBuffer() {
        // field 1, wire type 2, claiming 200 bytes of payload in a 3-byte buffer.
        let message = Data([0x0A, 0xC8, 0x01])
        #expect(ProtobufMessage(message).string(1) == nil)
    }
}

@Suite struct AntigravityUsageResponseTests {
    /// The shape `agy -p "/usage" --output-format json` actually returns.
    private static let live = """
    {"conversation_id":"","status":"SUCCESS","response":"Gemini Models\\tWeekly...",
     "num_turns":0,
     "usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0},
     "command":{"name":"usage","data":{"groups":[
       {"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro",
        "buckets":[
          {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly",
           "remaining_fraction":0.8548470139503479,"reset_time":"2026-08-21T12:44:14Z"},
          {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h",
           "remaining_fraction":0.1290820986032486,"reset_time":"2026-08-14T17:44:14Z"}]},
       {"name":"Claude and GPT models","description":"Models within this group: Claude Opus",
        "buckets":[
          {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly",
           "remaining_fraction":1,"reset_time":"2026-08-21T13:46:46Z"},
          {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h",
           "remaining_fraction":1,"reset_time":"2026-08-14T18:46:46Z"}]}]}}}
    """

    @Test func mapsLiveQuotaPayload() throws {
        let response = try AntigravityCLI.validate(Data(Self.live.utf8))
        let snapshot = AntigravitySnapshotMapper.make(
            quota: response, quotaError: nil, stats: .init(),
            activeModel: "Gemini 3.7 Flash (High)", now: Date()
        )

        #expect(snapshot.provider == .antigravity)
        #expect(snapshot.source == "agy CLI")
        #expect(snapshot.statusMessage == nil)
        #expect(snapshot.limits.count == 4)

        // 5-hour before weekly, and groups kept together.
        #expect(snapshot.limits.map(\.label) == [
            "Gemini · 5-Hour", "Gemini · Weekly",
            "Claude/GPT · 5-Hour", "Claude/GPT · Weekly",
        ])

        // remaining 0.129 → 87.1% used, and that is what the pill shows.
        let session = try #require(snapshot.limits.first)
        #expect(session.id == "gemini-5h")
        #expect(abs((session.usedFraction ?? 0) - 0.8709179013967514) < 0.000001)
        #expect(snapshot.primaryUsage == session.usedFraction)
        #expect(session.resetsAt == ISO8601DateFormatter().date(from: "2026-08-14T17:44:14Z"))
        #expect(snapshot.limits.last?.usedFraction == 0)
    }

    @Test func leadsWithTheGroupOwningTheActiveModel() throws {
        let response = try AntigravityCLI.validate(Data(Self.live.utf8))
        let snapshot = AntigravitySnapshotMapper.make(
            quota: response, quotaError: nil, stats: .init(),
            activeModel: "Claude Sonnet 4.5", now: Date()
        )
        // Working in a Claude model must not put a Gemini number on the notch.
        #expect(snapshot.limits.first?.id == "3p-5h")
        #expect(snapshot.primaryUsage == 0)
    }

    /// An older CLI answered `/usage` from the model instead of handling it, producing prose and
    /// no envelope. That must fail loudly rather than render invented quota.
    @Test func rejectsModelAnsweredUsage() {
        let hallucinated = """
        {"conversation_id":"2a01d77c","status":"SUCCESS",
         "response":"### Usage\\n* Active Model: Gemini 3.7 Flash\\n* Check the Settings menu."}
        """
        #expect(throws: AntigravityProviderError.self) {
            try AntigravityCLI.validate(Data(hallucinated.utf8))
        }
    }

    @Test func reportsBackendFailure() {
        let failed = """
        {"conversation_id":"","status":"ERROR","response":"",
         "error":"Eligibility check failed: Post \\"https://internal.example/v1internal:load\\""}
        """
        #expect(throws: AntigravityProviderError.self) {
            try AntigravityCLI.validate(Data(failed.utf8))
        }
    }

    /// A CLI that ignores its own `--print-timeout` must not hold the provider's queue forever.
    @Test func killsACLIThatOutlivesItsTimeout() throws {
        let started = Date()
        #expect(throws: AntigravityProviderError.timedOut) {
            try AntigravityCLI.capture(executable: URL(fileURLWithPath: "/bin/sleep"),
                                       arguments: ["30"], timeout: 0.5)
        }
        // Back well before the sleep would have ended on its own.
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func returnsOutputOfAProcessThatFinishesInTime() throws {
        let data = try AntigravityCLI.capture(executable: URL(fileURLWithPath: "/bin/echo"),
                                              arguments: ["{}"], timeout: 5)
        #expect(String(decoding: data, as: UTF8.self) == "{}\n")
    }

    @Test func keepsLocalStatsWhenQuotaIsUnavailable() {
        var stats = AntigravityLocalStats()
        stats.totalTokens = 20_553_387
        stats.totalTurns = 2_638
        stats.turnsByModel = ["gemini-3.7-flash": 2_068, "gemini-3.6-flash": 552]
        stats.tokensByDay = [Calendar.current.startOfDay(for: Date()): 17_491_115]

        let snapshot = AntigravitySnapshotMapper.make(
            quota: nil, quotaError: "Antigravity CLI not found",
            stats: stats, activeModel: nil, now: Date()
        )

        // Offline: no rings, but the chart and tiles still have something to show.
        #expect(snapshot.limits.isEmpty)
        #expect(snapshot.statusMessage == "Antigravity CLI not found")
        #expect(snapshot.fetchedAt == nil)
        #expect(snapshot.lifetimeTokens == 20_553_387)
        #expect(snapshot.dailySeries.count == 7)
        #expect(snapshot.dailySeries.last?.tokens == 17_491_115)
        #expect(snapshot.stats.contains { $0.id == "top-model" && $0.value == "Gemini 3.7 Flash" })
    }
}

@Suite struct AntigravityLocalStoreTests {
    /// Opt-in, against this machine's real Antigravity history:
    /// `ANTIGRAVITY_NOTCH_RUN_INTEGRATION_TEST=1 swift test --filter liveLocalStoreWhenRequested`
    @Test func liveLocalStoreWhenRequested() {
        guard ProcessInfo.processInfo
            .environment["ANTIGRAVITY_NOTCH_RUN_INTEGRATION_TEST"] == "1" else { return }

        let stores = AntigravityPaths.conversationStores()
        let stats = AntigravityLocalStore().scan()
        let readable = stores.filter { AntigravityLocalStore.canRead($0) }

        print("""
        stores=\(stores.count) readable=\(readable.count) \
        turns=\(stats.totalTurns) tokens=\(stats.totalTokens) \
        models=\(stats.turnsByModel) days=\(stats.tokensByDay.count)
        """)

        // Every store the scan found must actually be readable; a silent open failure would
        // undercount the totals rather than surface as an error.
        #expect(readable.count == stores.count)
        #expect(stats.totalTurns > 0)
    }

    @Test func decodesTokensModelsAndWorkspaceFromAStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = directory.appendingPathComponent("11111111-2222-3333-4444-555555555555.db")
        let midday = Date(timeIntervalSince1970: 1_786_707_127)
        try FixtureStore.write(
            to: store,
            workspace: "file:///Users/example/code/portfolio-website",
            turns: [
                .init(input: 14_844, output: 138, thinking: 81, model: "gemini-3.7-flash",
                      at: midday),
                .init(input: 18_974, output: 120, thinking: 63, model: "gemini-3.7-flash",
                      at: midday.addingTimeInterval(60)),
                .init(input: 4_666, output: 106, thinking: 41, model: "gemini-3.6-flash",
                      at: midday.addingTimeInterval(120)),
            ]
        )

        let stats = FixtureStore.scan(directory: directory)

        #expect(stats.totalTurns == 3)
        #expect(stats.totalTokens == 14_844 + 138 + 18_974 + 120 + 4_666 + 106)
        #expect(stats.thinkingTokens == 81 + 63 + 41)
        #expect(stats.turnsByModel == ["gemini-3.7-flash": 2, "gemini-3.6-flash": 1])
        #expect(stats.topModel == "gemini-3.7-flash")
        #expect(stats.tokens(on: midday) == stats.totalTokens)

        let conversation = try #require(stats.conversations.first)
        #expect(conversation.workspace == "portfolio-website")
        #expect(conversation.turns == 3)
        #expect(conversation.last == midday.addingTimeInterval(120))
    }

    @Test func ignoresRowsThatDoNotDecode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = directory.appendingPathComponent("garbage.db")
        try FixtureStore.write(to: store, workspace: nil, turns: [
            .init(input: 100, output: 10, thinking: 4, model: "gemini-3.7-flash",
                  at: Date(timeIntervalSince1970: 1_786_707_127)),
        ], extraBlobs: [
            Data([0xFF, 0xFF, 0xFF, 0xFF]),
            Data(),
            Data([0x0A, 0xC8, 0x01]),   // claims 200 bytes it does not have
        ])

        let stats = FixtureStore.scan(directory: directory)
        #expect(stats.totalTurns == 1)
        #expect(stats.totalTokens == 110)
    }
}

// MARK: - fixtures

/// Minimal protobuf writer, so tests build the wire format they claim to parse.
private enum PB {
    static func varint(field: Int, value: UInt64) -> Data {
        raw(UInt64(field) << 3 | 0) + raw(value)
    }
    static func fixed64(field: Int, value: UInt64) -> Data {
        raw(UInt64(field) << 3 | 1) + withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
    static func fixed32(field: Int, value: UInt32) -> Data {
        raw(UInt64(field) << 3 | 5) + withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
    static func message(field: Int, payload: Data) -> Data {
        raw(UInt64(field) << 3 | 2) + raw(UInt64(payload.count)) + payload
    }
    static func string(field: Int, value: String) -> Data {
        message(field: field, payload: Data(value.utf8))
    }

    private static func raw(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }
}

/// Builds a conversation store shaped like Antigravity's, so the reader is exercised against
/// real SQLite and real wire format without committing anyone's conversation history.
private enum FixtureStore {
    struct Turn {
        let input: Int, output: Int, thinking: Int
        let model: String
        let at: Date
    }

    static func write(to url: URL, workspace: String?, turns: [Turn],
                      extraBlobs: [Data] = []) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            throw FixtureError.open
        }
        defer { sqlite3_close(handle) }

        exec(handle, "CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob)")
        exec(handle, "CREATE TABLE trajectory_metadata_blob (id text PRIMARY KEY, data blob)")

        for (index, turn) in turns.enumerated() {
            let usage = PB.varint(field: 2, value: UInt64(turn.input))
                + PB.varint(field: 3, value: UInt64(turn.output))
                + PB.varint(field: 9, value: UInt64(turn.thinking))
            let timing = PB.message(
                field: 4,
                payload: PB.varint(field: 1, value: UInt64(turn.at.timeIntervalSince1970))
            )
            let record = PB.message(field: 4, payload: usage)
                + PB.message(field: 9, payload: timing)
                + PB.string(field: 19, value: turn.model)
            insertBlob(handle, table: "gen_metadata", index: index,
                       blob: PB.message(field: 1, payload: record))
        }
        for (offset, blob) in extraBlobs.enumerated() {
            insertBlob(handle, table: "gen_metadata", index: turns.count + offset, blob: blob)
        }

        if let workspace {
            insertBlob(handle, table: "trajectory_metadata_blob", index: nil,
                       blob: PB.string(field: 7, value: workspace))
        }
    }

    /// Scans only the fixture stores in `directory` — never the machine's real history.
    static func scan(directory: URL) -> AntigravityLocalStats {
        let stores = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "db" }
        return AntigravityLocalStore { stores }.scan()
    }

    private static func exec(_ handle: OpaquePointer, _ sql: String) {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    private static func insertBlob(_ handle: OpaquePointer, table: String,
                                   index: Int?, blob: Data) {
        let sql = index == nil
            ? "INSERT INTO \(table) (id, data) VALUES ('main', ?)"
            : "INSERT INTO \(table) (idx, data) VALUES (\(index!), ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        _ = blob.withUnsafeBytes { buffer in
            // SQLITE_TRANSIENT: the statement is stepped and finalized before `blob` goes away,
            // but copying keeps that guarantee independent of this scope's lifetime.
            sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(blob.count),
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_step(statement)
    }

    enum FixtureError: Error { case open }
}
