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
    private var clickMonitor: Any?
    private var fullscreenTimer: Timer?
    private var islandHidden = true   // start "hidden" so the first pass actually shows it

    func applicationDidFinishLaunching(_ note: Notification) {
        model.start()
        Updater.shared.start()                          // Sparkle auto-updates
        window = IslandWindow(model: model)
        monitor.start { [weak self] in self?.sync() }   // fires on display / Claude changes
        observeExpansion()
        sync()
        // Hide-in-fullscreen: react to Space changes, re-arm on the toggle, and poll (for
        // in-window fullscreen like browser video, which doesn't switch Spaces).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(fullscreenMaybeChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        observeHideInFullscreen()
        refreshFullscreenTimer()
    }

    @objc private func fullscreenMaybeChanged() { updateVisibility() }

    /// The island should hide only when the user opted in *and* a fullscreen app owns the island's
    /// screen. Acts only on a change, so it's cheap to call often.
    private func updateVisibility() {
        guard window != nil else { return }
        setHidden(model.hideInFullscreen && Self.fullscreenPresent())
    }

    /// Apply a visibility change once (animated slide), skipping no-ops.
    private func setHidden(_ hide: Bool) {
        guard let window, hide != islandHidden else { return }
        islandHidden = hide
        if hide { window.hide() } else { window.show() }
    }

    /// True when a fullscreen app owns the island's display.
    ///
    /// Asks the WindowServer whether the display's active Space is a fullscreen Space (via the
    /// private SkyLight API in `SpaceInfo`). That's a definitive signal, unlike sniffing window
    /// bounds, which can't tell native fullscreen from a maximized/zoomed window and breaks on
    /// notch geometry. Permission-free (no Accessibility or Screen Recording).
    private static func fullscreenPresent() -> Bool {
        guard let screen = NSScreen.island else { return false }
        return SpaceInfo.fullscreenSpaceActive(on: screen)
    }

    /// Arm a slow safety-net poll only while the option is on; the real trigger is the Space-change
    /// notification, so this just covers any missed notification.
    private func refreshFullscreenTimer() {
        fullscreenTimer?.invalidate()
        fullscreenTimer = nil
        if model.hideInFullscreen {
            // activeSpaceDidChangeNotification is the primary trigger; this slow poll is just a
            // safety net for any missed notification. Cheap (only while the option is on).
            fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateVisibility() }
            }
        }
        updateVisibility()
    }

    private func observeHideInFullscreen() {
        withObservationTracking { _ = model.hideInFullscreen } onChange: { [weak self] in
            Task { @MainActor in self?.refreshFullscreenTimer(); self?.observeHideInFullscreen() }
        }
    }

    /// Push current notch geometry into the model and reposition the island to the notched
    /// screen. Runs on launch and on every display-configuration change.
    private func sync() {
        guard let window else { return }   // monitor.start() can fire before window exists
        model.notchWidth = monitor.notchWidth > 0 ? monitor.notchWidth : 190   // synthetic on non-notch
        model.topInset = monitor.notchHeight > 0 ? monitor.notchHeight : 32
        window.relayout()
        updateVisibility()
    }

    /// withObservationTracking fires once, so re-arm after each change to keep tracking
    /// isExpanded. Only the invisible click-zone is resized here — the window and the pill
    /// animation are untouched, so nothing jumps.
    private func observeExpansion() {
        withObservationTracking {
            _ = model.isExpanded
            _ = model.expandedDropHeight   // re-sync the click-zone when the session count changes
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
}
