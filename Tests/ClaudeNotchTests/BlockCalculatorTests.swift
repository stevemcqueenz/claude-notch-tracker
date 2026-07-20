import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct BlockCalculatorTests {
    func event(_ iso: String, tokens: Int = 10, session: String = "s1") -> UsageEvent {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return UsageEvent(timestamp: f.date(from: iso)!, sessionId: session,
            requestId: nil, messageId: nil, model: "claude-opus-4-8",
            cwd: "/tmp/project",
            inputTokens: tokens, outputTokens: 0, cacheCreationTokens: 0,
            cacheReadTokens: 0)
    }

    @Test func splitsBlocksOnFiveHourGap() {
        let events = [
            event("2026-07-03T10:05:00Z"),
            event("2026-07-03T11:00:00Z"),
            event("2026-07-03T18:00:00Z"),
        ]
        let blocks = BlockCalculator.blocks(from: events)
        #expect(blocks.count == 2)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        #expect(blocks[0].start == f.date(from: "2026-07-03T10:00:00Z"))
        #expect(blocks[0].end == f.date(from: "2026-07-03T15:00:00Z"))
        #expect(blocks[0].totalTokens == 20)
        #expect(blocks[1].start == f.date(from: "2026-07-03T18:00:00Z"))
    }

    @Test func activeBlockReportsRemainingAndFraction() {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let events = [event("2026-07-03T10:05:00Z")]
        let now = f.date(from: "2026-07-03T12:00:00Z")!
        let active = BlockCalculator.activeBlock(from: events, now: now)
        let block = try? #require(active)
        #expect(block != nil)
        #expect(abs(block!.remaining(at: now) - 3*3600) < 1)
        #expect(abs(block!.fractionElapsed(at: now) - 0.4) < 0.001)
    }

    @Test func noActiveBlockWhenIdlePastWindow() {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let events = [event("2026-07-03T10:05:00Z")]
        let now = f.date(from: "2026-07-03T16:00:00Z")!
        #expect(BlockCalculator.activeBlock(from: events, now: now) == nil)
    }
}
