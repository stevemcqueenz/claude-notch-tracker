import SwiftUI

enum AppInfo {
    static let version = "0.1.0"
    static let tagline = "Made with Claude"
}

enum AvatarStyle: String, CaseIterable, Identifiable {
    case clawd, clawdWhite, spark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .clawd:      "Clawd"
        case .clawdWhite: "Clawd (white)"
        case .spark:      "Spark"
        }
    }
    /// Next style in the cycle (used by the click-to-swap on the avatar).
    var next: AvatarStyle {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    private static let key = "avatarStyle"
    static var selected: AvatarStyle {
        get { AvatarStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .clawd }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
