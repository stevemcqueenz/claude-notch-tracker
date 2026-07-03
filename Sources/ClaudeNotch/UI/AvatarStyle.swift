import SwiftUI

enum AvatarStyle: String, CaseIterable, Identifiable {
    case clawd, spark, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clawd: "Clawd"
        case .spark: "Spark mark"
        case .custom: "Custom image"
        }
    }

    private static let key = "avatarStyle"
    private static let customKey = "avatarCustomPath"

    static var selected: AvatarStyle {
        get { AvatarStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .clawd }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
    static var customImagePath: String? {
        get { UserDefaults.standard.string(forKey: customKey) }
        set { UserDefaults.standard.set(newValue, forKey: customKey) }
    }
}
