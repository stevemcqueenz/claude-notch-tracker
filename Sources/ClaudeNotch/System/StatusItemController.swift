import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let model: AppModel
    private var settingsWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.medium",
            accessibilityDescription: "Claude usage")
        rebuildMenu()
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil,
            queue: .main) { [weak self] _ in Task { @MainActor in self?.openSettings() } }
        NotificationCenter.default.addObserver(forName: .clawdTapped, object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor in self?.item.button?.performClick(nil) } }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let pause = NSMenuItem(title: model.isPaused ? "Resume tracking" : "Pause tracking",
            action: #selector(togglePause), keyEquivalent: "")
        pause.target = self; menu.addItem(pause)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings),
            keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
    }

    @objc private func togglePause() { model.togglePause(); rebuildMenu() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 160),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Claude Notch"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center(); w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
