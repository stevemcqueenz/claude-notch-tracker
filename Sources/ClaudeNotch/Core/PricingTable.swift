import Foundation

/// USD per 1M tokens. Estimates for display only; tune as needed.
enum PricingTable {
    struct Rate { let input, output, cacheWrite, cacheRead: Double }

    static let rates: [(match: String, rate: Rate)] = [
        ("opus",   Rate(input: 15,   output: 75, cacheWrite: 18.75, cacheRead: 1.5)),
        ("sonnet", Rate(input: 3,    output: 15, cacheWrite: 3.75,  cacheRead: 0.30)),
        ("haiku",  Rate(input: 0.80, output: 4,  cacheWrite: 1.0,   cacheRead: 0.08)),
    ]
    static let fallback = Rate(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30)

    static func rate(for model: String) -> Rate {
        let m = model.lowercased()
        return rates.first { m.contains($0.match) }?.rate ?? fallback
    }

    static func cost(for e: UsageEvent) -> Double {
        let r = rate(for: e.model)
        return (Double(e.inputTokens) * r.input
              + Double(e.outputTokens) * r.output
              + Double(e.cacheCreationTokens) * r.cacheWrite
              + Double(e.cacheReadTokens) * r.cacheRead) / 1_000_000
    }
}
