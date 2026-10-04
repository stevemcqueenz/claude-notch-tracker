import Foundation
import Testing
@testable import ClaudeNotch

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(_ json: String) throws -> ProviderUsageSnapshot {
    OllamaCloudSnapshotMapper.make(usage: try OllamaCloudUsage.parse(Data(json.utf8)), now: now)
}

@Suite struct OllamaCloudMapperTests {
    @Test func limitsPlanShowsBothMetersAndTheSpend() throws {
        let s = try snapshot("""
        {"activity": {"cost": "$12.34", "period": {"type": "last_4_weeks"}},
         "limits": {"session": {"usage": 0.03, "models": [{"name": "glm-5.3-flash", "request_count": 54}]},
                    "weekly": {"usage": 0.005, "models": [{"name": "glm-5.3-flash", "request_count": 458}]}}}
        """)
        #expect(s.provider == .ollamaCloud)
        #expect(s.limits.map(\.id) == ["ollama-session", "ollama-weekly"])
        #expect(s.limits.map(\.label) == ["5-Hour", "7-Day"])
        #expect(s.limits.map(\.usedFraction) == [0.03, 0.005])
        #expect(s.limits.map(\.window) == [5 * 3600.0, 7 * 86_400.0])
        #expect(s.limits.allSatisfy { $0.resetsAt == nil })
        #expect(s.pill == nil)
        #expect(s.stats == [UsageStatMetric(id: "ollama-cost", label: "last 4 weeks", value: "$12.34", subtitle: nil)])
        #expect(s.source == "ollama.com")
        #expect(s.fetchedAt == now)
    }

    @Test func zeroLimitsStayMeters() throws {
        // A legacy plan unused this week reads 0 % and has spent money: still a limits plan.
        let s = try snapshot("""
        {"activity": {"cost": "$1,234.50"}, "limits": {"session": {"usage": 0}, "weekly": {"usage": 0}}}
        """)
        #expect(s.limits.map(\.usedFraction) == [0, 0])
        #expect(s.pill == nil)
        #expect(s.primaryUsage == 0)
    }

    @Test func missingLimitsMeanACreditPlan() throws {
        let s = try snapshot(#"{"activity": {"cost": "$1,234.50"}}"#)
        #expect(s.limits.isEmpty)
        #expect(s.pill == UsagePill(text: "$1.2K", tint: .ok))
        #expect(s.stats.first?.value == "$1,234.50")
        // An empty `limits` object has neither window either.
        #expect(try snapshot(#"{"activity": {"cost": "$5"}, "limits": {}}"#).pill?.text == "$5.0")
    }

    @Test func modelsDecodeAsArrayOrObject() throws {
        let array = try snapshot("""
        {"limits": {"weekly": {"usage": 0.1, "models": [{"name": "a", "request_count": 3}, {"name": "b", "request_count": 9}]}}}
        """)
        let object = try snapshot("""
        {"limits": {"weekly": {"usage": 0.1, "models": {"a": {"request_count": 3}, "b": {"request_count": 9}}}}}
        """)
        #expect(array.sessions == object.sessions)
        #expect(array.sessions.map(\.name) == ["b", "a"])
        #expect(array.sessions.map(\.tokens) == [9, 3])
        #expect(array.sessions.allSatisfy { $0.last == now && $0.cost == nil })
        #expect(array.sessionsTitle == "models this week · requests")
    }

    @Test func sessionsAreMostRequestsFirstThenByName() throws {
        let s = try snapshot("""
        {"limits": {"weekly": {"models": {"zeta": {"request_count": 5}, "alpha": {"request_count": 5},
                                          "mid": {"request_count": 40}, "none": {}}}}}
        """)
        #expect(s.sessions.map(\.name) == ["mid", "alpha", "zeta", "none"])
        #expect(s.sessions.last?.tokens == 0)
    }

    @Test func missingFieldsDegradeQuietly() throws {
        // Only the weekly window, no usage, no cost: meters with no reading, no stats, no pill.
        let s = try snapshot(#"{"limits": {"weekly": {}}}"#)
        #expect(s.limits.map(\.usedFraction) == [nil, nil])
        #expect(s.stats.isEmpty && s.sessions.isEmpty && s.pill == nil)

        // Nothing at all: no meters and nothing to put in the pill.
        let empty = try snapshot("{}")
        #expect(empty.limits.isEmpty && empty.pill == nil)

        #expect(throws: OllamaCloudUsage.Failure.self) { try OllamaCloudUsage.parse(Data("[]".utf8)) }
    }

    @Test func windowLabelStandsInForAMissingReset() {
        let session = UsageLimitMetric(id: "s", label: "5-Hour", usedFraction: 0, resetsAt: nil, window: 5 * 3600)
        let weekly = UsageLimitMetric(id: "w", label: "7-Day", usedFraction: 0, resetsAt: nil, window: 7 * 86_400)
        #expect(session.windowLabel == "5-hour window")
        #expect(weekly.windowLabel == "7-day window")
        #expect(UsageLimitMetric(id: "x", label: "x", usedFraction: 0, resetsAt: nil).windowLabel == nil)
    }
}

@Suite struct APIKeyCredentialsTests {
    @Test func deepSeekKeepsItsKeychainIdentifiers() {
        // Existing users' saved keys live under exactly these names.
        let deepseek = APIKeyCredentials.deepseek
        #expect(deepseek.service == "Claude Notch – DeepSeek API key")
        #expect(deepseek.account == "api-key")
        #expect(deepseek.storedFlag == "deepseekKeyStored")
        #expect(deepseek.environmentVariable == "DEEPSEEK_API_KEY")
    }

    @Test func ollamaHasItsOwnItem() {
        let ollama = APIKeyCredentials.ollama
        #expect(ollama.environmentVariable == "OLLAMA_API_KEY")
        #expect(ollama.service != APIKeyCredentials.deepseek.service)
        #expect(ollama.storedFlag != APIKeyCredentials.deepseek.storedFlag)
    }
}
