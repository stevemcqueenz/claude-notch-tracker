import AppKit

/// The island's right-click menu, built in AppKit.
///
/// SwiftUI's `.contextMenu` never presents from this pill. The island lives in a borderless
/// `.nonactivatingPanel` that returns false from `canBecomeKey`, and SwiftUI only shows a context
/// menu for a key window — so the right-click landed on the view and nothing appeared. Popping an
/// `NSMenu` up by hand carries no such requirement, so the menu is built here and shown from
/// `PassthroughHostingView.rightMouseDown`.
@MainActor
final class IslandMenuController: NSObject {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(providerItem())
        menu.addItem(iconItem())
        menu.addItem(item("Refresh now", #selector(refreshNow)))
        menu.addItem(item(model.isPaused ? "Resume tracking" : "Pause tracking", #selector(togglePause)))
        menu.addItem(item("Animate icon", #selector(toggleAnimateIcon), checked: model.animateIcon))
        menu.addItem(item("Hide in full screen", #selector(toggleHideInFullscreen),
                          checked: model.hideInFullscreen))
        menu.addItem(item("Launch at Login", #selector(toggleLoginItem), checked: LoginItem.isEnabled))
        menu.addItem(.separator())
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "Claude Notch v\(AppInfo.version) — \(AppInfo.tagline)",
                                 action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit)))
        return menu
    }

    // MARK: item builders

    private func item(_ title: String,
                      _ action: Selector,
                      checked: Bool = false,
                      represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.state = checked ? .on : .off
        item.representedObject = represented
        return item
    }

    private func providerItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for provider in UsageProviderID.allCases {
            submenu.addItem(item(provider.displayName, #selector(pickProvider(_:)),
                                 checked: model.selectedProvider == provider,
                                 represented: provider.rawValue))
        }
        let parent = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func iconItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for style in AvatarStyle.allCases {
            submenu.addItem(item(style.label, #selector(pickAvatar(_:)),
                                 checked: model.avatarStyle == style,
                                 represented: style.rawValue))
        }
        let parent = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    // MARK: actions

    @objc private func pickProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = UsageProviderID(rawValue: raw) else { return }
        model.selectProvider(provider)
    }

    @objc private func pickAvatar(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = AvatarStyle(rawValue: raw) else { return }
        model.setAvatar(style)
    }

    @objc private func refreshNow() { model.refreshNow() }
    @objc private func togglePause() { model.togglePause() }
    @objc private func toggleAnimateIcon() { model.toggleAnimateIcon() }
    @objc private func toggleHideInFullscreen() { model.toggleHideInFullscreen() }
    @objc private func toggleLoginItem() { LoginItem.toggle() }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}
