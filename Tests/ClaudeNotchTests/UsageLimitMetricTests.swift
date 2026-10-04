import Foundation
import Testing
@testable import ClaudeNotch

struct UsageLimitMetricTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func elapsedFractionComesFromWindowAndReset() {
        let m = UsageLimitMetric(id: "s", label: "5-Hour", usedFraction: 0.4,
                                 resetsAt: now.addingTimeInterval(2 * 3600), window: 5 * 3600.0)
        #expect(abs((m.elapsedFraction(now: now) ?? -1) - 0.6) < 1e-9)
        let noWindow = UsageLimitMetric(id: "s", label: "5-Hour", usedFraction: 0.4, resetsAt: now)
        #expect(noWindow.elapsedFraction(now: now) == nil)
    }

    @Test func pillShowsTheSessionUnlessALimitIsUsedUp() {
        var s = ProviderUsageSnapshot(provider: .claude)
        s.limits = [
            .init(id: "5h", label: "5-Hour", usedFraction: 0.10, resetsAt: nil, window: 5 * 3600.0),
            .init(id: "7d", label: "7-Day", usedFraction: 0.90, resetsAt: nil, window: 7 * 86_400.0),
            .init(id: "fable", label: "Fable", usedFraction: 1.0, resetsAt: nil, scoped: true),
        ]
        // A full weekly is still not "used up", and a maxed per-model cap never takes over.
        #expect(s.bindingLimit?.id == "5h")
        #expect(s.primaryUsage == 0.10)
        #expect(s.accountUsage == 0.90)

        s.limits[1] = .init(id: "7d", label: "7-Day", usedFraction: 1.0, resetsAt: nil)
        #expect(s.bindingLimit?.id == "7d")
        #expect(s.primaryUsage == 1.0)
    }

    @Test func failedFetchKeepsLastGoodLimits() {
        var good = ProviderUsageSnapshot(provider: .codex)
        good.limits = [.init(id: "5h", label: "5-Hour", usedFraction: 0.3, resetsAt: nil)]
        good.fetchedAt = now
        let failed = ProviderUsageSnapshot.unavailable(.codex, message: "timed out")
        let kept = failed.keepingLastGoodReading(from: good)
        #expect(kept.limits == good.limits)
        #expect(kept.fetchedAt == now)                    // ages into the stale state
        #expect(kept.statusMessage == "timed out")

        let other = ProviderUsageSnapshot.unavailable(.antigravity)
        #expect(other.keepingLastGoodReading(from: good).limits.isEmpty)   // never across providers
    }
}
