import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct PricingTableTests {
    func event(model: String) -> UsageEvent {
        UsageEvent(timestamp: .init(), sessionId: "s", requestId: nil, messageId: nil,
            model: model, cwd: "/tmp/project",
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheCreationTokens: 0, cacheReadTokens: 0)
    }

    @Test func opusCostMatchesRates() {
        // 1M input @ $15 + 1M output @ $75 = $90
        let cost = PricingTable.cost(for: event(model: "claude-opus-4-8"))
        #expect(abs(cost - 90.0) < 0.0001)
    }

    @Test func unknownModelFallsBackNonZero() {
        #expect(PricingTable.cost(for: event(model: "mystery-model")) > 0)
    }
}
