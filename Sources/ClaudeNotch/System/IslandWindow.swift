import AppKit
import SwiftUI

/// Borderless floating panel that never becomes key (so it can't steal typing focus).
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Only claims mouse events inside `interactiveRect` (the pill's footprint). Everywhere else it
/// returns nil so clicks fall through to the menu bar / desktop / other apps.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: CGRect = .zero
    override func hitTest(_ point: NSPoint) -> NSView? {
        interactiveRect.contains(point) ? super.hitTest(point) : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A FIXED-size top-strip window. The pill animates its own height inside it — the window is
/// never resized, so expand/collapse can't jump or redraw the whole thing.
@MainActor
final class IslandWindow {
    private let panel: NotchPanel
    private let hosting: PassthroughHostingView<IslandRootView>
    private let model: AppModel
    private let notchWidth: CGFloat
    private let topInset: CGFloat
    private let panelHeight: CGFloat = 260

    init(model: AppModel, notchWidth: CGFloat, topInset: CGFloat) {
        self.model = model
        self.notchWidth = notchWidth
        self.topInset = topInset

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - panelHeight,
                           width: screen.frame.width, height: panelHeight)

        hosting = PassthroughHostingView(
            rootView: IslandRootView(model: model, notchWidth: notchWidth, topInset: topInset))
        hosting.frame = NSRect(origin: .zero, size: frame.size)

        panel = NotchPanel(contentRect: frame)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        updateInteractiveZone()
    }

    /// Resize only the invisible click-catcher to the pill's current footprint — cheap, no
    /// window resize, so no animation jump.
    func updateInteractiveZone() {
        let closedH = max(topInset, 30)
        let dropH: CGFloat = 198
        let zoneW = notchWidth + 56 * 2 + 24 + 24          // wing+gap+wing + edge insets + margin
        let zoneH = (model.isExpanded ? closedH + dropH + 8 : closedH + 6)
        let w = hosting.bounds.width
        let h = hosting.bounds.height
        hosting.interactiveRect = CGRect(x: (w - zoneW) / 2, y: h - zoneH, width: zoneW, height: zoneH)
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}
