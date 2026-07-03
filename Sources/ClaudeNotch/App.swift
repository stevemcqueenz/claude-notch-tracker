import AppKit
import SwiftUI

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let monitor = AppMonitor()
    var window: IslandWindow!
    var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ note: Notification) {
        model.start()
        window = IslandWindow(model: model)
        statusItem = StatusItemController(model: model)

        monitor.start { [weak self] in self?.sync() }
        observeExpansion()

        NotificationCenter.default.addObserver(forName: .avatarChanged, object: nil,
            queue: .main) { [weak self] _ in Task { @MainActor in
                self?.window.reposition(notchWidth: self?.monitor.notchWidth ?? 0) } }

        sync()
    }

    /// withObservationTracking fires once, so re-arm after each change to keep
    /// tracking isExpanded. Reposition on the next runloop so SwiftUI applies the
    /// new content size before we read fittingSize.
    private func observeExpansion() {
        withObservationTracking {
            _ = model.isExpanded
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.window.reposition(notchWidth: self.monitor.notchWidth)
                self.observeExpansion()
            }
        }
    }

    private func sync() {
        model.claudeRunning = monitor.claudeRunning
        window.reposition(notchWidth: monitor.notchWidth)
        if monitor.claudeRunning { window.show() } else { window.hide() }
    }
}
