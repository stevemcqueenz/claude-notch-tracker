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
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ note: Notification) {
        model.start()
        monitor.start { [weak self] in self?.sync() }   // computes notch geometry first

        let notchW = monitor.notchWidth > 0 ? monitor.notchWidth : 190   // synthetic on non-notch
        let topInset = monitor.notchHeight > 0 ? monitor.notchHeight : 32
        window = IslandWindow(model: model, notchWidth: notchW, topInset: topInset)
        statusItem = StatusItemController(model: model)

        observeExpansion()
        sync()
    }

    /// withObservationTracking fires once, so re-arm after each change to keep tracking
    /// isExpanded. Only the invisible click-zone is resized here — the window and the pill
    /// animation are untouched, so nothing jumps.
    private func observeExpansion() {
        withObservationTracking {
            _ = model.isExpanded
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.window.updateInteractiveZone()
                self.updateClickMonitor()
                self.observeExpansion()
            }
        }
    }

    /// While expanded, any click outside the island collapses it.
    private func updateClickMonitor() {
        if model.isExpanded, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    Task { @MainActor in self?.model.isExpanded = false }
                }
        } else if !model.isExpanded, let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    private func sync() {
        // monitor.start() fires this callback during start(), before `window` exists.
        guard let window else { return }
        model.claudeRunning = monitor.claudeRunning
        window.updateInteractiveZone()
        if monitor.claudeRunning { window.show() } else { window.hide() }
    }
}
