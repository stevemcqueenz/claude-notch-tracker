import Foundation

/// USD per 1M tokens, from Anthropic's published API list prices (checked 2026-10-04).
///
/// A Claude subscription doesn't bill per token, so this values logged usage at list price —
/// "what this would have cost on the API" — which is the only meaningful number to show.
///
/// Matching is version-aware and ordered most-specific-first, because rates differ *within* a
/// family: Opus 4.6 and later are $5/$25 while earlier Opus is $15/$75, and Sonnet 5 is $2/$10
/// while Sonnet 4.6 is $3/$15. A bare "opus"/"sonnet" substring match silently prices every
/// current model at a retired generation's rate.
enum PricingTable {
    struct Rate {
        let input, output, cacheRead: Double
        /// Cache writes are priced off the input rate by TTL: 1.25x for the 5-minute cache,
        /// 2x for the 1-hour one. Claude Code writes mostly 1-hour entries, so which one we
        /// charge is worth ~9% of the total.
        var cacheWrite5m: Double { input * 1.25 }
        var cacheWrite1h: Double { input * 2 }

        /// Cache reads are a tenth of the input rate on every model except Fable 5.1, which
        /// reads at a fortieth ($0.25/MTok).
        init(input: Double, output: Double, cacheReadMultiplier: Double = 0.1) {
            self.input = input
            self.output = output
            self.cacheRead = input * cacheReadMultiplier
        }
    }

    /// Ordered: the first match wins, so specific generations precede their family fallback.
    static let rates: [(match: String, rate: Rate)] = [
        ("fable-5-1",  Rate(input: 10, output: 50, cacheReadMultiplier: 0.025)),
        ("fable",      Rate(input: 10, output: 50)),
        // Mythos is Fable's Project Glasswing counterpart at the same per-token price. Its cache
        // read rate wasn't published alongside Fable 5.1's, so it keeps the standard tenth.
        ("mythos",     Rate(input: 10, output: 50)),
        ("opus-4-6",   Rate(input: 5,  output: 25)),
        ("opus-4-7",   Rate(input: 5,  output: 25)),
        ("opus-4-8",   Rate(input: 5,  output: 25)),
        ("opus-5-5",   Rate(input: 4,  output: 20, cacheReadMultiplier: 0.05)),
        ("opus-5",     Rate(input: 5,  output: 25)),
        ("opus",       Rate(input: 15, output: 75)),   // 4.5 and earlier
        ("sonnet-5",   Rate(input: 2,  output: 10)),
        ("sonnet",     Rate(input: 3,  output: 15)),   // 4.6 and earlier
        ("haiku-4-5",  Rate(input: 1,  output: 5)),
        ("haiku",      Rate(input: 0.80, output: 4)),  // 3.5 and earlier
    ]

    /// Used only for a model released after this table was written. Add new models above rather
    /// than relying on it: Fable used to land here and was billed at Sonnet's rate, understating
    /// it threefold. `everyModelSeenInTheWildMatchesAnEntry` guards the models we actually see.
    static let fallback = Rate(input: 3, output: 15)

    static func rate(for model: String) -> Rate {
        let m = model.lowercased()
        return rates.first { m.contains($0.match) }?.rate ?? fallback
    }

    static func cost(for e: UsageEvent) -> Double {
        let r = rate(for: e.model)
        // Older logs record only the total, with no TTL split; those bill at the 5-minute rate.
        let write1h = min(e.cacheCreation1hTokens, e.cacheCreationTokens)
        let write5m = e.cacheCreationTokens - write1h
        return (Double(e.inputTokens) * r.input
              + Double(e.outputTokens) * r.output
              + Double(write5m) * r.cacheWrite5m
              + Double(write1h) * r.cacheWrite1h
              + Double(e.cacheReadTokens) * r.cacheRead) / 1_000_000
    }
}
