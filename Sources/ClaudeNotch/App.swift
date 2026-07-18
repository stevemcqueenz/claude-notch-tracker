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

    /// True when the frontmost app is running fullscreen on the island's display.
    ///
    /// Window bounds alone can't tell fullscreen from a maximized/zoomed window — on a notched Mac
    /// a settled fullscreen window sits at the same `y=menuBarHeight, height=contentHeight` a zoomed
    /// window does. The real signal is *Space isolation*: a fullscreen app lives on its own Space, so
    /// no **other** app's window is on-screen behind it. So: the frontmost app fills the whole content
    /// area, and no other app has a large window on this display. Permission-free (no Accessibility).
    private static func fullscreenPresent() -> Bool {
        guard let screen = NSScreen.island,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        let bounds = CGDisplayBounds(CGDirectDisplayID(num.uint32Value))   // global, top-left origin
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        let frontPID = NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) }
        // The menu bar occupies the top strip; a fullscreen window covers the rest (the whole
        // display minus that strip). Anything within ~40pt of full height counts as "fills content".
        let contentFillMinHeight = bounds.height - 40

        var frontFillsContent = false        // settled fullscreen: fills below-menu-bar content area
        var frontCoversDisplay = false       // transition / notch-covering: window reaches y=0 too
        var otherAppHasLargeWindow = false
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,               // ordinary app window
                  let pid = w[kCGWindowOwnerPID as String] as? Int, pid != mine,   // not our own panel
                  let bd = w[kCGWindowBounds as String],
                  let r = CGRect(dictionaryRepresentation: bd as! CFDictionary),
                  r.intersects(bounds)                                       // on the island's display
            else { continue }
            let fullWidth = abs(r.width - bounds.width) < 4 && abs(r.minX - bounds.minX) < 4
            // Fills the content area (top strip may be the menu bar): settled-fullscreen shape.
            let fillsContent = fullWidth && r.minY - bounds.minY < 40 && r.height >= contentFillMinHeight
            // Reaches the very top and covers the whole display — only happens in real fullscreen
            // (incl. the transition frame), never a maximized window (those start below the notch).
            let coversDisplay = fullWidth && r.minY - bounds.minY < 4 && r.height >= bounds.height - 4
            if pid == frontPID {
                if fillsContent { frontFillsContent = true }
                if coversDisplay { frontCoversDisplay = true }
            } else if r.width > bounds.width * 0.5 {   // some *other* app has a substantial window
                otherAppHasLargeWindow = true
            }
        }
        // Covers-the-whole-display fires immediately on the transition (before other windows clear);
        // fills-content + Space-isolation is the settled state once the fullscreen Space owns it.
        return frontCoversDisplay || (frontFillsContent && !otherAppHasLargeWindow)
    }

    /// Run a light poll only while the option is on (catches fullscreen that doesn't switch Spaces).
    private func refreshFullscreenTimer() {
        fullscreenTimer?.invalidate()
        fullscreenTimer = nil
        if model.hideInFullscreen {
            // Poll briskly (only while the option is on) so entering/leaving fullscreen is caught
            // near-instantly even when no Space-change notification fires (e.g. in-window video).
            fullscreenTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
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
