import Foundation

/// Ollama Cloud through `GET ollama.com/api/usage`: the 5-hour and 7-day limits as used
/// fractions, the 4-week spend, and per-model request counts. The API reports no reset times
/// and no balance.
actor OllamaCloudUsageProvider {
    static let usageURL = URL(string: "https://ollama.com/api/usage")!

    /// Read once: a Keychain read per poll would be a prompt per poll on an ad-hoc build.
    private var cachedKey: String?
    /// Set by a 401: the Keychain is not re-read (a prompt per poll) until the key is changed.
    private var keyRejected = false

    /// The user set or removed the key.
    func resetCredentials() {
        cachedKey = nil
        keyRejected = false
    }

    /// A failed poll returns no limits, so `keepingLastGoodReading` keeps the last good ones
    /// on screen, dimmed by their age, with the reason.
    func fetch(now: Date = Date()) async -> ProviderUsageSnapshot {
        if cachedKey == nil, !keyRejected { cachedKey = APIKeyCredentials.ollama.read() }
        guard cachedKey != nil || keyRejected else {
            return .unavailable(.ollamaCloud, message: UsageProviderID.ollamaCloud.setupHint)
        }
        do {
            guard let key = cachedKey else { throw OllamaCloudUsage.Failure.unauthorized }
            return OllamaCloudSnapshotMapper.make(usage: try await Self.requestUsage(key: key), now: now)
        } catch OllamaCloudUsage.Failure.unauthorized {
            cachedKey = nil
            keyRejected = true
            return .unavailable(.ollamaCloud, message: "Ollama rejected the API key")
        } catch {
            // Static text on purpose, as for DeepSeek: raw errors could carry payloads into the pill.
            return .unavailable(.ollamaCloud, message: "Ollama unreachable")
        }
    }

    private static func requestUsage(key: String) async throws -> OllamaCloudUsage {
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw OllamaCloudUsage.Failure.unauthorized }
        guard status == 200 else { throw OllamaCloudUsage.Failure.http(status) }
        return try OllamaCloudUsage.parse(data)
    }
}

/// `GET /api/usage`, with every field optional: the shape is observed, not documented.
struct OllamaCloudUsage: Equatable, Sendable {
    struct ModelRequests: Equatable, Sendable {
        let name: String
        let requests: Int
    }

    /// The response carries `limits.session` or `limits.weekly` at all, even at 0.
    var reportsLimits = false
    var sessionUsage: Double?
    var weeklyUsage: Double?
    var weeklyModels: [ModelRequests] = []
    /// Spend over the last 4 weeks as Ollama formats it, e.g. "$12.34".
    var cost: String?

    enum Failure: Error {
        case unauthorized, http(Int), malformed
    }

    /// The cost string as a number, tolerant of "$", thousands separators and junk.
    var costValue: Double? {
        cost.flatMap { Double($0.filter { $0.isNumber || $0 == "." }) }
    }

    static func parse(_ data: Data) throws -> OllamaCloudUsage {
        struct Wire: Decodable {
            struct Activity: Decodable { let cost: String? }
            struct Limit: Decodable {
                let usage: Double?
                let models: Models?
            }
            struct Limits: Decodable {
                let session: Limit?
                let weekly: Limit?
            }
            /// Reported both as `[{name, request_count}]` and as `{"<model>": {request_count}}`.
            struct Models: Decodable {
                let list: [ModelRequests]
                init(from decoder: any Decoder) throws {
                    struct Named: Decodable { let name: String; let request_count: Int? }
                    struct Count: Decodable { let request_count: Int? }
                    let container = try decoder.singleValueContainer()
                    if let named = try? container.decode([Named].self) {
                        list = named.map { ModelRequests(name: $0.name, requests: $0.request_count ?? 0) }
                    } else {
                        list = try container.decode([String: Count].self)
                            .map { ModelRequests(name: $0.key, requests: $0.value.request_count ?? 0) }
                    }
                }
            }
            let activity: Activity?
            let limits: Limits?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { throw Failure.malformed }
        return OllamaCloudUsage(reportsLimits: wire.limits?.session != nil || wire.limits?.weekly != nil,
                                sessionUsage: wire.limits?.session?.usage,
                                weeklyUsage: wire.limits?.weekly?.usage,
                                weeklyModels: wire.limits?.weekly?.models?.list ?? [],
                                cost: wire.activity?.cost)
    }
}

/// Pure snapshot assembly, so the tiles can be tested without a network or a Keychain.
enum OllamaCloudSnapshotMapper {
    static func make(usage: OllamaCloudUsage, now: Date) -> ProviderUsageSnapshot {
        let stats = usage.cost.map {
            [UsageStatMetric(id: "ollama-cost", label: "last 4 weeks", value: $0, subtitle: nil)]
        } ?? []
        var snapshot = ProviderUsageSnapshot(
            provider: .ollamaCloud,
            stats: stats,
            sessionsTitle: "models this week · requests",
            sessions: usage.weeklyModels
                .sorted { $0.requests != $1.requests ? $0.requests > $1.requests : $0.name < $1.name }
                .map { UsageSessionMetric(id: "ollama-model-\($0.name)", name: $0.name,
                                          cost: nil, tokens: $0.requests, last: now) },
            source: "ollama.com",
            fetchedAt: now
        )
        // Plans from 2026-08-31 on bill against a monthly credit pool instead of the 5-hour and
        // 7-day limits. Zero limits are not a sign of one: a legacy plan unused this week reads 0
        // too. So any `limits.session`/`limits.weekly` gets meters, even at 0 %, and only a
        // response without either is treated as a credit plan, whose pill shows the 4-week spend.
        if !usage.reportsLimits {
            snapshot.pill = usage.costValue.map { UsagePill(text: Fmt.compactMoney($0, currency: nil), tint: .ok) }
        } else {
            snapshot.limits = [
                UsageLimitMetric(id: "ollama-session", label: "5-Hour", usedFraction: usage.sessionUsage,
                                 resetsAt: nil, window: 5 * 3600),
                UsageLimitMetric(id: "ollama-weekly", label: "7-Day", usedFraction: usage.weeklyUsage,
                                 resetsAt: nil, window: 7 * 86_400),
            ]
        }
        return snapshot
    }
}
