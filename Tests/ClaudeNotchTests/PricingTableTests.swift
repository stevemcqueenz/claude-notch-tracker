import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct PricingTableTests {
    func event(model: String, input: Int = 1_000_000, output: Int = 1_000_000,
               write: Int = 0, write1h: Int = 0, read: Int = 0) -> UsageEvent {
        UsageEvent(timestamp: .init(), sessionId: "s", requestId: nil, messageId: nil,
            model: model, cwd: "/tmp/proj", inputTokens: input, outputTokens: output,
            cacheCreationTokens: write, cacheReadTokens: read, cacheCreation1hTokens: write1h)
    }
    func cost(_ model: String, input: Int = 1_000_000, output: Int = 1_000_000,
              write: Int = 0, write1h: Int = 0, read: Int = 0) -> Double {
        PricingTable.cost(for: event(model: model, input: input, output: output,
                                     write: write, write1h: write1h, read: read))
    }

    /// Published list prices per 1M tokens. 1M in + 1M out, so the expected cost is input+output.
    @Test(arguments: [
        ("claude-opus-5", 30.0),           // $5 + $25 — NOT the $15/$75 of Opus 4.5 and earlier
        ("claude-opus-4-8", 30.0),
        ("claude-opus-4-7", 30.0),
        ("claude-opus-4-6", 30.0),
        ("claude-opus-4-1", 90.0),         // legacy Opus really is $15/$75
        ("claude-fable-5", 60.0),          // $10 + $50
        ("claude-fable-5-1", 60.0),
        ("claude-opus-5-5", 24.0),         // $4 + $20, not Opus 5's $5/$25
        ("claude-sonnet-5", 12.0),         // $2 + $10
        ("claude-sonnet-5-5", 12.0),       // $2 + $10
        ("claude-sonnet-4-6", 18.0),       // $3 + $15
        ("claude-haiku-4-5-20251001", 6.0) // $1 + $5, dated id still matches
    ])
    func modelRatesMatchPublishedPrices(model: String, expected: Double) {
        #expect(abs(cost(model) - expected) < 0.0001)
    }

    /// Regression: "fable" matched no entry and fell through to the Sonnet-rate fallback, pricing
    /// Anthropic's most expensive model at less than a third of its rate.
    @Test func fableIsNotPricedAsSonnet() {
        #expect(cost("claude-fable-5") != cost("claude-sonnet-4-6"))
        #expect(cost("claude-fable-5") > cost("claude-opus-5"))
    }

    /// Regression: a bare "opus" substring priced every current Opus at the retired $15/$75.
    @Test func currentOpusIsNotPricedAsLegacyOpus() {
        #expect(cost("claude-opus-5") < cost("claude-opus-4-1"))
    }

    /// Opus 5.5 is $4/$20 with cache reads at $0.20; Sonnet 5.5 reads at $0.20 too.
    @Test func opus55HasItsOwnRate() {
        #expect(abs(cost("claude-opus-5-5", input: 0, output: 0, read: 1_000_000) - 0.20) < 0.0001)
        #expect(abs(cost("claude-opus-5-5", input: 0, output: 0, write: 1_000_000) - 5.0) < 0.0001)
        #expect(abs(cost("claude-sonnet-5-5", input: 0, output: 0, read: 1_000_000) - 0.20) < 0.0001)
    }

    /// Cache writes cost 1.25x input for the 5-minute cache and 2x for the 1-hour one.
    @Test func cacheWritesArePricedByTTL() {
        #expect(abs(cost("claude-opus-5", input: 0, output: 0, write: 1_000_000) - 6.25) < 0.0001)
        #expect(abs(cost("claude-opus-5", input: 0, output: 0,
                         write: 1_000_000, write1h: 1_000_000) - 10.0) < 0.0001)
        // A half-and-half split lands between the two.
        #expect(abs(cost("claude-opus-5", input: 0, output: 0,
                         write: 1_000_000, write1h: 500_000) - 8.125) < 0.0001)
    }

    /// A log with no TTL breakdown must not be charged the 1-hour premium, and a malformed
    /// 1-hour share larger than the total must not inflate the bill past all-1h.
    @Test func missingOrOversizedTTLSharesStayInBounds() {
        #expect(abs(cost("claude-opus-5", input: 0, output: 0, write: 1_000_000) - 6.25) < 0.0001)
        #expect(abs(cost("claude-opus-5", input: 0, output: 0,
                         write: 1_000_000, write1h: 9_000_000) - 10.0) < 0.0001)
    }

    /// Reads are a tenth of input, except Fable 5.1 at a fortieth ($0.25/MTok).
    @Test func cacheReadsAreATenthOfInputExceptFable51() {
        #expect(abs(cost("claude-opus-5", input: 0, output: 0, read: 1_000_000) - 0.50) < 0.0001)
        #expect(abs(cost("claude-fable-5", input: 0, output: 0, read: 1_000_000) - 1.00) < 0.0001)
        #expect(abs(cost("claude-fable-5-1", input: 0, output: 0, read: 1_000_000) - 0.25) < 0.0001)
    }

    /// The fallback exists only for models released after this table was written. Everything we
    /// actually see in real logs must match a deliberate entry — that's what Fable failed to do.
    @Test func everyModelSeenInTheWildMatchesAnEntry() {
        let seen = ["claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-fable-5", "claude-fable-5-1",
                    "claude-sonnet-4-6", "claude-sonnet-5", "claude-sonnet-5-5", "claude-haiku-4-5-20251001"]
        for model in seen {
            #expect(PricingTable.rates.contains { model.contains($0.match) },
                    "\(model) falls through to the fallback rate")
        }
    }

    @Test func unknownModelFallsBackNonZero() {
        #expect(cost("mystery-model") > 0)
    }
}
