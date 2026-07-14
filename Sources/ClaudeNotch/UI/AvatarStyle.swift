import SwiftUI
import ServiceManagement

enum AppInfo {
    static let version = "0.1.8"
    static let tagline = "Made with Claude"
}

/// Launch-at-login toggle (only effective when running as a bundled .app).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func toggle() {
        do {
            if isEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("ClaudeNotch login item error: \(error.localizedDescription)")
        }
    }
}

enum AvatarStyle: String, CaseIterable, Identifiable {
    case clawd, clawdWhite, spark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .clawd:      "Clawd"
        case .clawdWhite: "Clawd (mono)"
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
