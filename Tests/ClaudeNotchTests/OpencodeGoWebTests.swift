import Foundation
import Testing
@testable import ClaudeNotch

/// The opencode-go web/API mappers. These pin the console `go/status` and public `zen/go/v1/usage`
/// payloads against the fractions the snapshot expects, plus the month-reset fallback that keeps
/// the monthly window aligned with CodexBar.
@Suite struct OpencodeGoWebTests {
    private let now = Date(timeIntervalSince1970: 1_789_862_400)

    @Test func consoleMetersBecomeFractionsAndResets() throws {
        let text = """
        {"access":{"endsAt":"2026-10-19T00:00:00Z","meters":{
          "fiveHour":{"usagePercent":25,"resetsAt":"2026-09-20T03:00:00Z"},
          "week":{"usagePercent":40,"resetsAt":"2026-09-21T00:00:00Z"},
          "month":{"usagePercent":10}}}}
        """
        let snapshot = try OpencodeGoAPI.parseConsoleGoStatus(text: text, now: now)

        #expect(snapshot.provider == .opencodeGo)
        #expect(snapshot.source == "opencode.ai")
        #expect(snapshot.limits.map(\.label) == ["5-Hour", "7-Day", "Monthly"])
        #expect(snapshot.limits.map(\.window) == [18_000.0, 604_800.0, 2_592_000.0] as [TimeInterval?])
        #expect(abs((snapshot.limits[0].usedFraction ?? 0) - 0.25) < 0.0001)
        #expect(abs((snapshot.limits[1].usedFraction ?? 0) - 0.40) < 0.0001)
        #expect(abs((snapshot.limits[2].usedFraction ?? 0) - 0.10) < 0.0001)
        #expect(snapshot.limits[0].resetsAt == Self.iso("2026-09-20T03:00:00Z"))
        #expect(snapshot.renewsAt == Self.iso("2026-10-19T00:00:00Z"))
        #expect(snapshot.fetchedAt == now)
    }

    @Test func monthlyResetFallsBackToBillingPeriodEnd() throws {
        let endsAt = Self.iso("2026-10-19T00:00:00Z")
        let text = """
        {"access":{"endsAt":"2026-10-19T00:00:00Z","meters":{
          "fiveHour":{"usagePercent":25,"resetsAt":null},
          "week":{"usagePercent":40},
          "month":{"usagePercent":10,"resetsAt":null}}}}
        """
        let snapshot = try OpencodeGoAPI.parseConsoleGoStatus(text: text, now: now)

        #expect(snapshot.renewsAt == endsAt)
        #expect(snapshot.limits[2].resetsAt == endsAt)
        #expect(snapshot.limits[0].resetsAt == nil)
    }

    @Test func consoleMicroCentMetersAlsoMap() throws {
        let text = """
        {"access":{"meters":{"fiveHour":{
          "limitMicroCents":"1200000000","usedMicroCents":"300000000"}}}}
        """
        let snapshot = try OpencodeGoAPI.parseConsoleGoStatus(text: text, now: now)
        #expect(abs((snapshot.limits[0].usedFraction ?? 0) - 0.25) < 0.0001)
    }

    @Test(arguments: ["null", #"{"access":null}"#])
    func accessNullIsNoSubscription(body: String) {
        #expect(throws: OpencodeGoAPIError.self) {
            try OpencodeGoAPI.parseConsoleGoStatus(text: body, now: now)
        }
    }

    @Test func malformedConsolePayloadIsNotNoSubscription() {
        do {
            _ = try OpencodeGoAPI.parseConsoleGoStatus(text: #"{"access":{}}"#, now: now)
            Issue.record("Expected a parse failure for an empty access object")
        } catch OpencodeGoAPIError.parseFailed {
            // Expected.
        } catch {
            Issue.record("Expected parseFailed, got \(error)")
        }
    }

    @Test func apiUsagePercentMapsToFraction() throws {
        let text = """
        {"usage":{"rolling":{"percent":3,"resetInSec":18100},
                  "weekly":{"percent":12,"resetInSec":1000},
                  "monthly":{"percent":64,"resetsAt":"2026-09-01T00:00:00Z"}}}
        """
        let snapshot = try OpencodeGoAPI.parseAPIUsage(text: text, now: now)

        #expect(snapshot.source == "API")
        #expect(abs((snapshot.limits[0].usedFraction ?? 0) - 0.03) < 0.0001)
        #expect(abs((snapshot.limits[1].usedFraction ?? 0) - 0.12) < 0.0001)
        #expect(abs((snapshot.limits[2].usedFraction ?? 0) - 0.64) < 0.0001)
        #expect(snapshot.limits[0].resetsAt == now.addingTimeInterval(18100))
        #expect(snapshot.limits[2].resetsAt == Self.iso("2026-09-01T00:00:00Z"))
    }

    @Test func workspaceIDUsesFirstValidConsoleRow() {
        let text = #"[{"id":"wrk_TEST123","name":"Default"},{"id":"wrk_OTHER456"}]"#
        #expect(OpencodeGoAPI.workspaceID(fromConsoleOrgs: text) == "wrk_TEST123")
        #expect(OpencodeGoAPI.workspaceID(fromConsoleOrgs: #"{"error":"nope"}"#) == nil)
        #expect(OpencodeGoAPI.workspaceID(fromConsoleOrgs: #"[{"id":"acc_TEST"}]"#) == nil)
    }

    @Test func zenBalanceOnlyForPrepaidPayAsYouGo() {
        let text = #"{"billingMode":"prepaid","mode":"pay-as-you-go","balanceMicroCents":"1234567890"}"#
        #expect(OpencodeGoAPI.parseZenBalance(text: text) == 12.3456789)
        #expect(OpencodeGoAPI.parseZenBalance(
            text: #"{"billingMode":"credit","mode":"invoiceable","balanceMicroCents":"1"}"#) == nil)
        #expect(OpencodeGoAPI.parseZenBalance(
            text: #"{"billingMode":"prepaid","mode":"pay-as-you-go"}"#) == nil)
    }

    @Test func apiKeyComesFromTheEnvironmentOnly() {
        #expect(OpencodeGoAPI.apiKey(environment: ["OPENCODE_API_KEY": "go_secret"]) == "go_secret")
        #expect(OpencodeGoAPI.apiKey(environment: ["OPENCODE_API_KEY": "   "]) == nil)
        #expect(OpencodeGoAPI.apiKey(environment: [:]) == nil)
    }

    @Test func consoleRenewsTileCarriesTheBillingEnd() throws {
        let text = """
        {"access":{"endsAt":"2026-10-19T00:00:00Z","meters":{
          "fiveHour":{"usagePercent":25}}}}
        """
        let snapshot = try OpencodeGoAPI.parseConsoleGoStatus(text: text, now: now)
        let renews = snapshot.stats.first { $0.id == "renews" }
        #expect(renews?.label == "Renews")
        #expect(renews?.value == Fmt.until(Self.iso("2026-10-19T00:00:00Z")!))
        #expect(renews?.subtitle == nil)
    }

    @Test func apiRenewsTileCarriesTheBillingEnd() throws {
        let text = """
        {"usage":{"rolling":{"percent":3,"resetInSec":18100},
                  "renewsAt":"2026-10-19T00:00:00Z"}}
        """
        let snapshot = try OpencodeGoAPI.parseAPIUsage(text: text, now: now)
        #expect(snapshot.stats.first { $0.id == "renews" }?.value
            == Fmt.until(Self.iso("2026-10-19T00:00:00Z")!))
    }

    @Test func noRenewsTileWithoutAnEndDate() throws {
        let text = #"{"usage":{"rolling":{"percent":3,"resetInSec":18100}}}"#
        let snapshot = try OpencodeGoAPI.parseAPIUsage(text: text, now: now)
        #expect(snapshot.stats.contains { $0.id == "renews" } == false)
    }

    @Test func microCentMetersGetAnAbsoluteSubtitle() throws {
        let text = """
        {"access":{"meters":{"fiveHour":{
          "limitMicroCents":"1200000000","usedMicroCents":"300000000"}}}}
        """
        let snapshot = try OpencodeGoAPI.parseConsoleGoStatus(text: text, now: now)
        #expect(snapshot.limits[0].subtitle == "$3.00 of $12.00")
    }

    @Test func barePercentHasNoSubtitle() throws {
        let text = """
        {"access":{"meters":{"fiveHour":{"usagePercent":25}}}}
        """
        let snapshot = try OpencodeGoAPI.parseConsoleGoStatus(text: text, now: now)
        #expect(snapshot.limits[0].subtitle == nil)
    }

    @Test func attachingLocalSeriesKeepsTheWebNumbers() throws {
        let text = """
        {"access":{"endsAt":"2026-10-19T00:00:00Z","meters":{
          "fiveHour":{"usagePercent":25},
          "week":{"usagePercent":40},
          "month":{"usagePercent":10}}}}
        """
        let web = try OpencodeGoAPI.parseConsoleGoStatus(text: text, now: now)
        let series = OpencodeGoLocalUsage.dailySeries(
            rows: [OpencodeGoLocalUsage.Row(at: now.addingTimeInterval(-60), cost: 6)], now: now)
        let merged = OpencodeGoUsageProvider.attachingSeries(series, to: web)

        #expect(merged.limits == web.limits)
        #expect(merged.stats == web.stats)
        #expect(merged.source == "opencode.ai")
        #expect(merged.renewsAt == web.renewsAt)
        #expect(merged.dailySeries == series)
        #expect(merged.chartTitle == "last 7 days · local")
    }

    @Test func anEmptyLocalSeriesLeavesTheWebSnapshotAlone() throws {
        let text = """
        {"access":{"meters":{"fiveHour":{"usagePercent":25}}}}
        """
        let web = try OpencodeGoAPI.parseConsoleGoStatus(text: text, now: now)
        #expect(OpencodeGoUsageProvider.attachingSeries([], to: web) == web)
    }

    private static func iso(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}
