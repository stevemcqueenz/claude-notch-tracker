import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct CodexSnapshotMapperTests {
    @Test func liveAppServerExchangeWhenRequested() async {
        guard ProcessInfo.processInfo.environment["CODEX_NOTCH_RUN_INTEGRATION_TEST"] == "1" else {
            return
        }

        let snapshot = await CodexUsageProvider().fetch()

        #expect(snapshot.source == "Codex app-server")
        #expect(!snapshot.limits.isEmpty)
        #expect(snapshot.lifetimeTokens != nil)
    }

    @Test func mapsOfficialAppServerPayloads() throws {
        let account = try decode(CodexAccountResponse.self, json: """
        {
          "account": {"type": "chatgpt", "email": "user@example.com", "planType": "plus"},
          "requiresOpenaiAuth": true
        }
        """)
        let rateLimits = try decode(CodexRateLimitsResponse.self, json: """
        {
          "rateLimits": {
            "credits": {"balance": "12.50", "hasCredits": true, "unlimited": false},
            "limitId": "codex",
            "limitName": "Codex",
            "planType": "plus",
            "primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1784556000},
            "secondary": {"usedPercent": 70, "windowDurationMins": 10080, "resetsAt": 1785160800}
          },
          "rateLimitsByLimitId": null
        }
        """)
        let usage = try decode(CodexAccountUsageResponse.self, json: """
        {
          "summary": {"lifetimeTokens": 1234567},
          "dailyUsageBuckets": [{"startDate": "2026-07-20", "tokens": 45678}]
        }
        """)
        let threads = try decode(CodexThreadListResponse.self, json: """
        {
          "data": [{
            "id": "thread-1",
            "cwd": "/Users/example/Projects/notch",
            "name": "Provider abstraction",
            "preview": "Implement provider support",
            "updatedAt": 1784552400
          }]
        }
        """)
        let now = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 20, hour: 12
        )))

        let snapshot = CodexSnapshotMapper.make(
            account: account,
            rateLimits: rateLimits,
            usage: usage,
            threads: threads,
            now: now
        )

        #expect(snapshot.provider == .codex)
        #expect(snapshot.limits.map(\.label) == ["5-Hour", "7-Day"])
        #expect(snapshot.limits.map(\.usedFraction) == [0.42, 0.70])
        #expect(snapshot.todayTokens == 45_678)
        #expect(snapshot.lifetimeTokens == 1_234_567)
        #expect(snapshot.planName == "Codex Plus")
        #expect(snapshot.stats.first(where: { $0.id == "credits" })?.value == "12.50")
        #expect(snapshot.sessions.first?.name == "Provider abstraction")
        #expect(snapshot.statusMessage == nil)
    }

    @Test func explainsMissingUsageForAPIKeyAuth() throws {
        let account = try decode(CodexAccountResponse.self, json: """
        {
          "account": {"type": "apiKey"},
          "requiresOpenaiAuth": false
        }
        """)

        let snapshot = CodexSnapshotMapper.make(
            account: account,
            rateLimits: nil,
            usage: nil,
            threads: nil,
            errors: [4: "Usage is unavailable"],
            now: Date()
        )

        #expect(snapshot.statusMessage == "Account usage requires ChatGPT sign-in")
        #expect(snapshot.todayCost == nil)
        #expect(snapshot.lifetimeCost == nil)
    }

    @Test func neverDisplaysRawThreadPreview() throws {
        let threads = try decode(CodexThreadListResponse.self, json: """
        {
          "data": [{
            "id": "thread-private",
            "cwd": "/Users/example/Projects/notch",
            "name": null,
            "preview": "Confidential prompt content",
            "updatedAt": 1784552400
          }]
        }
        """)

        let snapshot = CodexSnapshotMapper.make(
            account: nil,
            rateLimits: nil,
            usage: nil,
            threads: threads,
            now: Date()
        )

        #expect(snapshot.sessions.first?.name == "notch")
        #expect(snapshot.sessions.first?.name != "Confidential prompt content")
    }

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
