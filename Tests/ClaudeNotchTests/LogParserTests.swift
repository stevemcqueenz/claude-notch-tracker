import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct LogParserTests {
    func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")!
    }

    @Test func parsesOnlyBillableAssistantLines() throws {
        let events = try LogParser.parse(fileURL: fixtureURL("basic"))
        #expect(events.count == 1)
        let e = try #require(events.first)
        #expect(e.sessionId == "s1")
        #expect(e.requestId == "r1")
        #expect(e.messageId == "m1")
        #expect(e.model == "claude-opus-4-8")
        #expect(e.inputTokens == 100)
        #expect(e.outputTokens == 50)
        #expect(e.cacheCreationTokens == 10)
        #expect(e.cacheReadTokens == 200)
        #expect(e.totalTokens == 360)
    }

    @Test func parsesFractionalIso8601Timestamp() throws {
        let events = try LogParser.parse(fileURL: fixtureURL("basic"))
        let e = try #require(events.first)
        #expect(abs(e.timestamp.timeIntervalSince1970 - 1783107094.147) < 0.01)
    }
}
