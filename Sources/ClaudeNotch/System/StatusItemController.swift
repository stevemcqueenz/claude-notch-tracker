import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "gauge.medium",
            accessibilityDescription: "Claude usage")
        let menu = NSMenu()
        menu.delegate = self          // rebuilt each time it opens (keeps checkmarks fresh)
        item.menu = menu
    }

    // Rebuild on open so avatar checkmarks / pause label reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let iconMenu = NSMenu()
        for style in AvatarStyle.allCases {
            let it = NSMenuItem(title: style.label, action: #selector(chooseAvatar(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = style.rawValue
            it.state = (model.avatarStyle == style) ? .on : .off
            iconMenu.addItem(it)
        }
        let iconItem = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        iconItem.submenu = iconMenu
        menu.addItem(iconItem)

        let pause = NSMenuItem(title: model.isPaused ? "Resume tracking" : "Pause tracking",
            action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())
        menu.addItem(disabled("Claude Notch v\(AppInfo.version)"))
        menu.addItem(disabled(AppInfo.tagline))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    @objc private func chooseAvatar(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let s = AvatarStyle(rawValue: raw) {
            model.setAvatar(s)
        }
    }
    @objc private func togglePause() { model.togglePause() }
    @objc private func quit() { NSApp.terminate(nil) }
}
