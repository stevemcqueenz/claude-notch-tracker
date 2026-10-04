import SwiftUI

enum Fmt {
    static func hm(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }
    static func pct(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
    /// "40m" / "1h 10m" / "4d 17h" — time remaining. Under an hour it drops the hours entirely:
    /// a limit tile showing "resets in 0h 40m" wastes its width on a zero.
    static func until(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(m)m"
    }
    /// "35m" / "1h 05m" — a duration.
    static func dur(_ t: TimeInterval) -> String {
        let m = max(0, Int(t) / 60)
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }
    /// "4s" / "2m" / "1h" / "2d" — compact age of a timestamp.
    static func ago(_ date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSinceNow))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
    /// "11,592.36": thousands separators, always en_US so the figure reads the same everywhere.
    private static func grouped(_ v: Double) -> String {
        v.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(2)))
    }
    static func usd(_ v: Double) -> String { "$" + grouped(v) }

    /// Money in a snapshot's own currency; nil is USD, which is what every pre-DeepSeek figure is.
    static func money(_ v: Double, currency: String?) -> String {
        guard let currency, currency != "USD" else { return usd(v) }
        return symbol(currency) + grouped(v)
    }

    /// Fits the closed pill's wing: "12.4K" from a thousand up, whole units from 100, one decimal
    /// place below that.
    static func compactMoney(_ v: Double, currency: String?) -> String {
        let s = symbol(currency ?? "USD")
        if v >= 1_000 { return s + String(format: "%.1fK", v / 1_000) }
        if v >= 100 { return s + String(Int(v.rounded())) }
        return s + String(format: "%.1f", v)
    }

    private static func symbol(_ currency: String) -> String {
        switch currency {
        case "USD": "$"
        case "CNY": "¥"
        default: currency + " "
        }
    }

    /// Money from API minor units + ISO currency code, e.g. (4251, "EUR") -> "€42.51".
    /// Assumes 2 decimal places, which matches every currency claude.ai bills in.
    static func money(minor: Int, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: "en_US")   // stable symbol-first formatting: €42.51, $42.51
        return f.string(from: NSNumber(value: Double(minor) / 100)) ?? String(format: "%.2f %@", Double(minor) / 100, currency)
    }

    /// "default_claude_max_5x" -> "Claude Max 5x"; "…_pro" -> "Claude Pro".
    static func planLabel(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "default_", with: "")
                   .replacingOccurrences(of: "claude_", with: "")
        if s.hasPrefix("max_") {
            s = s.replacingOccurrences(of: "max_", with: "")
            return "Claude Max \(s)"          // "5x"
        }
        return "Claude " + s.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Ring colour thresholds for a usage fraction (0…1 consumed).
func ringState(for used: Double) -> RingState {
    switch used {
    case ..<0.66: return .ok
    case ..<0.85: return .warn
    default:      return .critical
    }
}
