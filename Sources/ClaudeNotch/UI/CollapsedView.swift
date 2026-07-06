import SwiftUI

enum Fmt {
    static func hm(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }
    static func pct(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
    /// "1h 10m" (under a day) or "4d 17h" (a day or more).
    static func until(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d)d \(h)h" : "\(h)h \(String(format: "%02d", m))m"
    }
    /// "35m" / "1h 05m" — a duration.
    static func dur(_ t: TimeInterval) -> String {
        let m = max(0, Int(t) / 60)
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }
    /// "4s" / "2m" / "1h" — compact age of a timestamp.
    static func ago(_ date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSinceNow))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

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
