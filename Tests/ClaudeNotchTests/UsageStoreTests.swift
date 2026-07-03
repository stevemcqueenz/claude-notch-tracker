import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct UsageStoreTests {
    func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
    }

    @Test func dedupesAndAggregates() throws {
        let store = UsageStore()
        try store.ingest(fileURL: fixtureURL("dedup"))
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let now = f.date(from: "2026-07-03T10:30:00Z")!
        let snap = store.snapshot(now: now)
        #expect(snap.tokensToday == 1_500_000)
        #expect(abs(snap.costToday - 15.40) < 0.0001)
        #expect(snap.topModel == "claude-opus-4-8")
        #expect(snap.blockRemaining != nil)
        #expect(!snap.isEmpty)
    }

    @Test func emptyStoreIsEmptySnapshot() {
        let snap = UsageStore().snapshot(now: Date())
        #expect(snap.isEmpty)
        #expect(snap.tokensToday == 0)
        #expect(snap.blockRemaining == nil)
    }
}
