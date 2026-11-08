import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct PromptCacheTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func event(at offset: TimeInterval, session: String = "s", model: String = "claude-opus-5-5",
               read: Int = 0, write: Int = 0, write1h: Int = 0, sidechain: Bool = false) -> UsageEvent {
        UsageEvent(timestamp: start.addingTimeInterval(offset), sessionId: session, requestId: nil,
                   messageId: "\(session)-\(offset)", model: model, cwd: "", inputTokens: 1,
                   outputTokens: 1, cacheCreationTokens: write, cacheReadTokens: read,
                   cacheCreation1hTokens: write1h, isSidechain: sidechain)
    }

    func expiry(_ events: [UsageEvent], session: String = "s") -> TimeInterval? {
        PromptCacheEstimator.statuses(from: events)[session]?.expiresAt.timeIntervalSince(start)
    }

    @Test func oneHourWriteExpiresAnHourAfterLastRequestLessMargin() {
        #expect(expiry([event(at: 0, write: 1000, write1h: 1000)]) == 3540)
    }

    @Test func fiveMinuteWriteUsesShortTTL() {
        #expect(expiry([event(at: 0, write: 1000)]) == 240)
    }

    @Test func cacheHitRestartsTheClockAndKeepsTheWrittenTTL() {
        let events = [event(at: 0, write: 1000, write1h: 1000), event(at: 1800, read: 1000)]
        #expect(expiry(events) == 5340)
    }

    /// Claude Code's default, for a session whose only visible turns are reads.
    @Test func readWithNoVisibleWriteAssumesOneHour() {
        #expect(expiry([event(at: 0, read: 1000)]) == 3540)
    }

    /// A subagent shares the sessionId but not the cache, so it mustn't extend the parent's clock.
    @Test func subagentTurnsDoNotRefreshTheParent() {
        let events = [event(at: 0, write: 1000, write1h: 1000),
                      event(at: 1800, read: 500, sidechain: true)]
        #expect(expiry(events) == 3540)
    }

    @Test func sessionWithoutCachedContextHasNoStatus() {
        #expect(expiry([event(at: 0)]) == nil)
    }

    @Test func nonClaudeBackendHasNoStatus() {
        #expect(expiry([event(at: 0, model: "deepseek-v4-pro", read: 1000)]) == nil)
    }

    /// Switching backend abandons the Claude cache, so its old countdown shouldn't linger.
    @Test func switchingToAnotherBackendClearsTheStatus() {
        let events = [event(at: 0, write: 1000, write1h: 1000),
                      event(at: 60, model: "deepseek-v4-pro", read: 1000)]
        #expect(expiry(events) == nil)
    }

    @Test func rebuildCostIsWritePriceLessReadPrice() throws {
        // 1M cached on Opus 5.5: $10/M to rewrite for an hour, $0.50/M to read.
        let events = [event(at: 0, read: 900_000, write: 100_000, write1h: 100_000)]
        let status = try #require(PromptCacheEstimator.statuses(from: events)["s"])
        #expect(abs(status.rebuildCost - 9.5) < 0.0001)
    }

    @Test func warnsOnlyInTheLastFiveMinutes() {
        let status = PromptCacheStatus(expiresAt: start, rebuildCost: 1)
        #expect(!status.isExpiringSoon(at: start.addingTimeInterval(-301)))
        #expect(status.isExpiringSoon(at: start.addingTimeInterval(-300)))
        #expect(!status.isExpiringSoon(at: start))
        #expect(status.isExpired(at: start))
    }

    @Test func parserFlagsSubagentLines() throws {
        let line = """
        {"type":"assistant","isSidechain":true,"timestamp":"2026-07-03T10:00:00Z","sessionId":"s",\
        "message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1}}}
        """
        let e = try #require(LogParser.parse(data: Data(line.utf8)).first)
        #expect(e.isSidechain)
    }

    @Test func snapshotCarriesTheStatusToTheSessionRow() throws {
        let store = UsageStore()
        let url = URL(fileURLWithPath: "/tmp/session.jsonl")
        store.ingest(fileURL: url, events: [event(at: 0, write: 1000, write1h: 1000)])
        let session = try #require(store.snapshot(now: start).projectsToday.first)
        #expect(session.cache?.expiresAt == start.addingTimeInterval(3540))
    }
}
