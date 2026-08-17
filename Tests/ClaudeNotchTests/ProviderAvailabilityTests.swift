import Foundation
import Testing
@testable import ClaudeNotch

/// The detection itself reads the real filesystem, so these pin the parts that decide what the
/// user sees: that Claude is always offered, that detection is side-effect free, and that a
/// provider which isn't installed explains itself instead of erroring.
@MainActor
@Suite struct ProviderAvailabilityTests {
    @Test func claudeIsAlwaysOffered() {
        // Claude degrades on its own (live limits, terminal feed, log estimate), so it must never
        // drop out of the cycle and leave the island with nothing to show.
        #expect(ProviderAvailability.isAvailable(.claude))
        #expect(ProviderAvailability.available().contains(.claude))
    }

    @Test func availabilityKeepsMenuOrder() {
        let available = ProviderAvailability.available()
        let expected = UsageProviderID.allCases.filter { available.contains($0) }
        #expect(available == expected)
    }

    @Test func detectionIsCheapAndRepeatable() {
        // Cached, so the constantly re-rendering pill can ask as often as it likes. Repeated calls
        // must agree, and must not launch anything.
        let first = ProviderAvailability.available()
        let second = ProviderAvailability.available()
        #expect(first == second)
        ProviderAvailability.invalidate()
        #expect(ProviderAvailability.available() == first)
    }

    @Test func everyProviderCanExplainItself() {
        // A provider with no install shows this instead of a raw "executable not found".
        for provider in UsageProviderID.allCases {
            #expect(!provider.setupHint.isEmpty)
            #expect(!provider.displayName.isEmpty)
        }
    }

    @Test func codexDetectionMatchesTheTransportsOwnLookup() {
        // Detection and the app-server transport must agree on what "installed" means, or the
        // cycle would offer a provider that then fails to launch.
        #expect(ProviderAvailability.isAvailable(.codex) == (CodexPaths.executable() != nil))
    }
}
