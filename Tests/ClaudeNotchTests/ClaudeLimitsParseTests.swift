import Testing
import Foundation
@testable import ClaudeNotch

@Suite struct ClaudeLimitsParseTests {
    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    /// Trimmed from a real claude.ai /usage response (Nov 2026) while the 5-hour limit was
    /// suspended: `five_hour` is null, the weekly limits are still reported.
    private let noSessionLimit = """
    {"five_hour":null,
     "seven_day":{"utilization":50.0,"resets_at":"2026-11-07T05:00:00.761313+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":null,
     "extra_usage":{"is_enabled":false,"utilization":0.0},
     "limits":[
       {"kind":"weekly_all","group":"weekly","percent":50,
        "resets_at":"2026-11-07T05:00:00.761313+00:00","scope":null,"is_active":false},
       {"kind":"weekly_scoped","group":"weekly","percent":81,
        "resets_at":"2026-11-07T05:00:00.761442+00:00",
        "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}],
     "spend":{"enabled":false,"percent":0}}
    """

    @Test func nullFiveHourKeepsWeeklyAndFable() {
        let l = ClaudeAPIService.parse(json(noSessionLimit), source: "test")
        #expect(l.sessionPct == nil)
        #expect(l.sessionResetsAt == nil)
        #expect(l.weeklyPct == 0.5)
        #expect(l.weeklyResetsAt != nil)
        #expect(l.fablePct == 0.81)
        #expect(l.fableResetsAt != nil)
        // The response is real data, not a failed read: it must not be thrown away.
        #expect(l.hasAnyLimit)
    }

    @Test func weeklyFallsBackToWeeklyAllEntry() {
        let obj = json("""
        {"five_hour":null,"seven_day":null,
         "limits":[{"kind":"weekly_all","percent":42,"resets_at":"2026-11-07T05:00:00Z"}]}
        """)
        let l = ClaudeAPIService.parse(obj, source: "test")
        #expect(l.weeklyPct == 0.42)
        #expect(l.weeklyResetsAt == ISO8601DateFormatter().date(from: "2026-11-07T05:00:00Z"))
    }

    @Test func legacyResponseWithFiveHourStillParses() {
        let obj = json("""
        {"five_hour":{"utilization":9.0,"resets_at":"2026-11-05T03:00:00Z"},
         "seven_day":{"utilization":50.0,"resets_at":"2026-11-07T05:00:00Z"}}
        """)
        let l = ClaudeAPIService.parse(obj, source: "test")
        #expect(l.sessionPct == 0.09)
        #expect(l.sessionResetsAt != nil)
        #expect(l.weeklyPct == 0.5)
        #expect(l.fablePct == nil)
    }

    @Test func emptyResponseHasNoLimit() {
        let l = ClaudeAPIService.parse(json(#"{"five_hour":null,"seven_day":null}"#), source: "test")
        #expect(!l.hasAnyLimit)
    }
}
