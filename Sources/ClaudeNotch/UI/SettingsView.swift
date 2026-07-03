import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var style = AvatarStyle.selected

    var body: some View {
        Form {
            Picker("Avatar", selection: $style) {
                ForEach(AvatarStyle.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: style) { _, new in
                AvatarStyle.selected = new
                if new == .custom { pickImage() }
                NotificationCenter.default.post(name: .avatarChanged, object: nil)
            }
            AvatarView(style: style, active: true).frame(width: 40, height: 40)
        }
        .padding(20).frame(width: 320, height: 160)
    }

    private func pickImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .image]
        if p.runModal() == .OK, let url = p.url {
            AvatarStyle.customImagePath = url.path
            NotificationCenter.default.post(name: .avatarChanged, object: nil)
        }
    }
}

extension Notification.Name { static let avatarChanged = Notification.Name("avatarChanged") }
