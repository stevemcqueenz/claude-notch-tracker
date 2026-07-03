import SwiftUI

enum Fmt {
    static func hm(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }
    static func pct(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
}

/// Ring colour thresholds for a usage fraction (0…1 consumed).
func ringState(for used: Double) -> RingState {
    switch used {
    case ..<0.66: return .ok
    case ..<0.85: return .warn
    default:      return .critical
    }
}
