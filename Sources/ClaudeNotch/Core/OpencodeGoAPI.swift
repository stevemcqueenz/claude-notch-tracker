import Foundation

enum OpencodeGoAPIError: LocalizedError {
    case invalidCredentials
    case noSubscription
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "opencode-go session is invalid or expired"
        case .noSubscription: "No opencode-go subscription is available"
        case .apiError(let message): "opencode-go API error: \(message)"
        case .parseFailed(let message): "opencode-go parse error: \(message)"
        }
    }
}

/// How a web/API attempt ended, so the provider can tell "use local history" from "keep the last
/// good numbers": `.unavailable` means there is no usable browser/API credential, `.failed` means
/// we had one but the round trip (network, parse) didn't produce a snapshot.
enum OpencodeGoWebFetch: Sendable {
    case usage(ProviderUsageSnapshot)
    case unavailable
    case failed
    /// `OPENCODE_API_KEY` is set and the server refused it (401/403), and no browser session
    /// stood in for it.
    case keyRejected
}

/// opencode-go's server meters.
///
/// The Go plan's real 5-hour / weekly / monthly windows live behind opencode.ai's console, not in
/// the local opencode.db (which only has spend). This reads them two ways: a cookie-authenticated
/// console call that mirrors a signed-in browser, or the public usage API with an
/// `OPENCODE_API_KEY`. Local history stays the fallback when neither is available.
actor OpencodeGoAPI {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    static let timeout: TimeInterval = 15
    static let apiKeyEnvironmentKey = "OPENCODE_API_KEY"
    private static let host = "opencode.ai"

    static let consoleWorkspacesURL = URL(string: "https://opencode.ai/console/api/orgs")!
    static let consoleGoStatusURL = URL(string: "https://opencode.ai/console/api/go/status")!
    static let consoleBillingStatusURL = URL(string: "https://opencode.ai/console/api/billing/status")!
    static let usageAPIURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    private let cookieReader = BrowserCookieReader.shared
    /// The working browser session, reused without touching the cookie store or Keychain.
    private var sessionCache: (cookieHeader: String, workspaceID: String, source: String, at: Date)?
    private let sessionTTL: TimeInterval = 1800      // 30 min, then re-read to pick up a re-login
    /// Sources that just failed (no cookies, denied Keychain, logged out): skipped until this date.
    private var backoffUntil: [String: Date] = [:]
    private let backoff: TimeInterval = 900          // 15 min
    private let lastGoodKey = "opencodeGoLastGoodCookieSource"

    static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let raw = environment[apiKeyEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// The best snapshot the web can offer this cycle: API key first, then the browser console.
    func fetch(now: Date = Date(),
               environment: [String: String] = ProcessInfo.processInfo.environment) async -> OpencodeGoWebFetch {
        var apiOutcome: OpencodeGoWebFetch?
        if let key = Self.apiKey(environment: environment) {
            do {
                return .usage(try await Self.fetchAPIUsage(apiKey: key, now: now))
            } catch OpencodeGoAPIError.invalidCredentials {
                apiOutcome = .keyRejected
            } catch {
                apiOutcome = .failed   // transient: the provider keeps the last good reading
            }
        }
        let web = await fetchWeb(now: now)
        // A browser session beats a failed key; otherwise report why the key didn't work.
        if case .usage = web { return web }
        return apiOutcome ?? web
    }

    // MARK: - browser console

    private func fetchWeb(now: Date) async -> OpencodeGoWebFetch {
        // 1. Reuse the known-good session: no Keychain, no SQLite read.
        if let s = sessionCache, now.timeIntervalSince(s.at) < sessionTTL {
            switch await request(cookieHeader: s.cookieHeader, workspaceID: s.workspaceID, now: now) {
            case .ok(let snapshot, _): return .usage(snapshot)
            case .offline: return .failed            // keep the cache, retry next tick
            case .rejected: sessionCache = nil       // really dead: re-read the store once
            }
        }
        // 2. Try stores, the last known-good one first, so a healthy setup touches one Keychain item.
        for source in await orderedSources() {
            if let until = backoffUntil[source.name], until > now { continue }
            guard let jar = await cookieReader.readCookies(from: source, host: Self.host) else {
                backoffUntil[source.name] = now.addingTimeInterval(backoff)
                continue
            }
            let header = Self.cookieHeader(from: jar)
            guard !header.isEmpty else {
                backoffUntil[source.name] = now.addingTimeInterval(backoff)
                continue
            }
            switch await request(cookieHeader: header, workspaceID: nil, now: now) {
            case .ok(let snapshot, let workspaceID):
                sessionCache = (header, workspaceID, source.name, now)
                backoffUntil[source.name] = nil
                UserDefaults.standard.set(source.name, forKey: lastGoodKey)
                return .usage(snapshot)
            case .offline:
                return .failed   // don't blame the source, don't probe the others (no new prompts)
            case .rejected:
                backoffUntil[source.name] = now.addingTimeInterval(backoff)
            }
        }
        return .unavailable
    }

    /// Candidate stores with the last known-good one moved to the front.
    private func orderedSources() async -> [BrowserCookieReader.Source] {
        let all = await cookieReader.sources()
        guard let last = UserDefaults.standard.string(forKey: lastGoodKey),
              let i = all.firstIndex(where: { $0.name == last }) else { return all }
        var out = all
        out.insert(out.remove(at: i), at: 0)
        return out
    }

    private enum Outcome {
        case ok(ProviderUsageSnapshot, workspaceID: String)
        case rejected      // reached the server, it refused: session really is dead
        case offline       // never reached the server, or the payload didn't parse
    }

    private func request(cookieHeader: String, workspaceID: String?, now: Date) async -> Outcome {
        do {
            let workspace: String
            if let workspaceID {
                workspace = workspaceID
            } else {
                workspace = try await Self.fetchWorkspaceID(cookieHeader: cookieHeader)
            }
            var snapshot = try await Self.fetchConsoleGoStatus(
                cookieHeader: cookieHeader, workspaceID: workspace, now: now)
            if let balance = await Self.fetchZenBalance(cookieHeader: cookieHeader, workspaceID: workspace) {
                snapshot.stats.append(UsageStatMetric(
                    id: "zen-balance", label: "zen balance", value: Fmt.usd(balance), subtitle: nil))
            }
            return .ok(snapshot, workspaceID: workspace)
        } catch OpencodeGoAPIError.invalidCredentials {
            return .rejected
        } catch {
            return .offline
        }
    }

    // MARK: - network

    private static func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpencodeGoAPIError.apiError("no HTTP response")
        }
        return (data, http)
    }

    private static func fetchWorkspaceID(cookieHeader: String) async throws -> String {
        let (data, http) = try await get(consoleWorkspacesURL, headers: cookieHeaders(cookieHeader))
        try check(http)
        guard let text = String(data: data, encoding: .utf8),
              let id = workspaceID(fromConsoleOrgs: text) else {
            throw OpencodeGoAPIError.parseFailed("Missing workspace id.")
        }
        return id
    }

    private static func fetchConsoleGoStatus(cookieHeader: String, workspaceID: String,
                                             now: Date) async throws -> ProviderUsageSnapshot {
        var headers = cookieHeaders(cookieHeader)
        headers["x-org-id"] = workspaceID
        let (data, http) = try await get(consoleGoStatusURL, headers: headers)
        try check(http)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpencodeGoAPIError.parseFailed("Response was not UTF-8.")
        }
        return try parseConsoleGoStatus(text: text, now: now)
    }

    static func fetchAPIUsage(apiKey: String, now: Date) async throws -> ProviderUsageSnapshot {
        let (data, http) = try await get(usageAPIURL, headers: [
            "Authorization": "Bearer \(apiKey)",
            "Accept": "application/json",
            "User-Agent": userAgent,
        ])
        if http.statusCode == 401 || http.statusCode == 403 { throw OpencodeGoAPIError.invalidCredentials }
        guard http.statusCode == 200 else { throw OpencodeGoAPIError.apiError("HTTP \(http.statusCode)") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpencodeGoAPIError.parseFailed("Response was not UTF-8.")
        }
        return try parseAPIUsage(text: text, now: now)
    }

    /// Best-effort balance: a missing/unsupported billing payload never blocks the meters.
    private static func fetchZenBalance(cookieHeader: String, workspaceID: String) async -> Double? {
        var headers = cookieHeaders(cookieHeader)
        headers["x-org-id"] = workspaceID
        guard let (data, http) = try? await get(consoleBillingStatusURL, headers: headers),
              http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parseZenBalance(text: text)
    }

    private static func cookieHeaders(_ cookieHeader: String) -> [String: String] {
        ["Cookie": cookieHeader, "Accept": "application/json", "User-Agent": userAgent]
    }

    private static func check(_ http: HTTPURLResponse) throws {
        if http.statusCode == 401 { throw OpencodeGoAPIError.invalidCredentials }
        guard http.statusCode == 200 else { throw OpencodeGoAPIError.apiError("HTTP \(http.statusCode)") }
    }

    static func cookieHeader(from jar: [String: String]) -> String {
        jar.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - parsing

    /// First console workspace ID from `GET /console/api/orgs` (a JSON array of `{ id, name }`).
    static func workspaceID(fromConsoleOrgs text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { $0["id"] as? String }
            .first { $0.range(of: #"^(?:wrk_|org_)[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil }
    }

    /// `GET /console/api/go/status`. `access` null means the workspace has no Go subscription.
    /// The month meter carries no reset timestamp, so the billing period end stands in for it.
    static func parseConsoleGoStatus(text: String, now: Date) throws -> ProviderUsageSnapshot {
        guard let data = text.data(using: .utf8) else {
            throw OpencodeGoAPIError.parseFailed("Response was not UTF-8.")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw OpencodeGoAPIError.parseFailed("Invalid Console usage payload.")
        }
        if object is NSNull { throw OpencodeGoAPIError.noSubscription }
        guard let root = object as? [String: Any], let accessValue = root["access"] else {
            throw OpencodeGoAPIError.parseFailed("Invalid Console usage payload.")
        }
        if accessValue is NSNull { throw OpencodeGoAPIError.noSubscription }
        guard let access = accessValue as? [String: Any],
              let meters = access["meters"] as? [String: Any],
              let fiveHour = meters["fiveHour"] as? [String: Any],
              meter(from: fiveHour).percent != nil else {
            throw OpencodeGoAPIError.parseFailed("Invalid Console usage payload.")
        }
        let endsAt = date(from: access["endsAt"])
        var month = (meters["month"] ?? meters["monthly"]) as? [String: Any]
        // Assign the raw ISO value (not the parsed Date) so `resetDate` can read it back.
        if let rawEndsAt = access["endsAt"], date(from: month?["resetsAt"]) == nil {
            month?["resetsAt"] = rawEndsAt
        }
        return makeSnapshot(
            session: fiveHour,
            weekly: (meters["week"] ?? meters["weekly"]) as? [String: Any],
            monthly: month,
            renewsAt: endsAt,
            source: "opencode.ai",
            now: now)
    }

    /// `GET /zen/go/v1/usage` with a Bearer key. Percents are already 0...100.
    static func parseAPIUsage(text: String, now: Date) throws -> ProviderUsageSnapshot {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any],
              let rolling = usage["rolling"] as? [String: Any],
              meter(from: rolling).percent != nil else {
            throw OpencodeGoAPIError.parseFailed("Missing usage fields.")
        }
        let renewsAt = date(from: usage["renewsAt"]) ?? date(from: usage["renewAt"])
            ?? date(from: root["renewsAt"]) ?? date(from: root["renewAt"])
        return makeSnapshot(
            session: rolling,
            weekly: usage["weekly"] as? [String: Any],
            monthly: usage["monthly"] as? [String: Any],
            renewsAt: renewsAt,
            source: "API",
            now: now)
    }

    /// The console prepaid balance, in USD. Only a prepaid pay-as-you-go account has one.
    static func parseZenBalance(text: String) -> Double? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["billingMode"] as? String) == "prepaid",
              (root["mode"] as? String) == "pay-as-you-go" else { return nil }
        return double(root["balanceMicroCents"]).map { $0 / 100_000_000 }
    }

    private static func makeSnapshot(session: [String: Any], weekly: [String: Any]?,
                                     monthly: [String: Any]?, renewsAt: Date?,
                                     source: String, now: Date) -> ProviderUsageSnapshot {
        let sessionMeter = meter(from: session)
        let weeklyMeter = meter(from: weekly)
        let monthlyMeter = meter(from: monthly)
        var stats: [UsageStatMetric] = []
        if let renewsAt {
            stats.append(UsageStatMetric(id: "renews", label: "Renews",
                                         value: Fmt.until(renewsAt), subtitle: nil))
        }
        return ProviderUsageSnapshot(
            provider: .opencodeGo,
            limits: [
                UsageLimitMetric(id: "opencode-session", label: "5-Hour",
                                 usedFraction: fraction(sessionMeter.percent),
                                 resetsAt: resetDate(from: session, now: now),
                                 subtitle: spendSubtitle(sessionMeter), window: 5 * 3600),
                UsageLimitMetric(id: "opencode-weekly", label: "7-Day",
                                 usedFraction: fraction(weeklyMeter.percent),
                                 resetsAt: resetDate(from: weekly, now: now),
                                 subtitle: spendSubtitle(weeklyMeter), window: 7 * 86_400),
                UsageLimitMetric(id: "opencode-monthly", label: "Monthly",
                                 usedFraction: fraction(monthlyMeter.percent),
                                 resetsAt: resetDate(from: monthly, now: now),
                                 subtitle: spendSubtitle(monthlyMeter), window: 30 * 86_400),
            ],
            stats: stats,
            renewsAt: renewsAt,
            source: source,
            fetchedAt: now)
    }

    /// A window's used / limit in dollars, e.g. "$3.00 of $12.00"; nil when only a percent is known.
    private static func spendSubtitle(_ meter: ParsedMeter) -> String? {
        guard let used = meter.used, let limit = meter.limit else { return nil }
        return "\(Fmt.usd(used)) of \(Fmt.usd(limit))"
    }

    /// A meter's percent plus, when the console sends micro-cent amounts, the dollars behind it.
    private struct ParsedMeter {
        let percent: Double?
        let used: Double?      // USD
        let limit: Double?     // USD
    }

    private static func meter(from raw: [String: Any]?) -> ParsedMeter {
        guard let raw else { return ParsedMeter(percent: nil, used: nil, limit: nil) }
        var percent: Double?
        for key in ["usagePercent", "usedPercent", "percentUsed", "percent",
                    "usage_percent", "used_percent", "utilizationPercent", "utilization"] {
            if let value = double(raw[key]) { percent = min(100, max(0, value)); break }
        }
        let used = double(raw["usedMicroCents"]).map { $0 / 100_000_000 }
        let limit = double(raw["limitMicroCents"]).map { $0 / 100_000_000 }
        // The console's micro-cent meters: usage / limit as a percentage.
        if percent == nil, let used, let limit, limit > 0 {
            percent = min(100, max(0, used / limit * 100))
        }
        return ParsedMeter(percent: percent, used: used, limit: limit)
    }

    private static func fraction(_ percent: Double?) -> Double? { percent.map { $0 / 100 } }

    private static func resetDate(from meter: [String: Any]?, now: Date) -> Date? {
        guard let meter else { return nil }
        for key in ["resetsAt", "resetAt", "resets_at", "reset_at", "nextReset", "renewAt", "renew_at"] {
            if let date = date(from: meter[key]) { return date }
        }
        for key in ["resetInSec", "resetInSeconds", "resetSeconds", "reset_in_sec", "resetSec", "resetIn"] {
            if let seconds = double(meter[key]) { return now.addingTimeInterval(seconds) }
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let d as Double: number = d
        case let n as NSNumber: number = n.doubleValue
        case let s as String: number = Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func date(from value: Any?) -> Date? {
        guard let value else { return nil }
        if let date = value as? Date { return date }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if let date = iso8601(trimmed) { return date }
            return double(trimmed).flatMap(epoch)
        }
        return double(value).flatMap(epoch)
    }

    private static func iso8601(_ string: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    private static func epoch(_ value: Double) -> Date? {
        if value > 1_000_000_000_000 { return Date(timeIntervalSince1970: value / 1000) }
        if value > 1_000_000_000 { return Date(timeIntervalSince1970: value) }
        return nil
    }
}
