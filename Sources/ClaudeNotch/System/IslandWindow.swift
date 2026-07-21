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
///
/// NOTE: that fall-through works because the window server click-throughs transparent pixels of a
/// borderless non-opaque window. NEVER set `panel.ignoresMouseEvents` explicitly (even to false):
/// doing so disables that per-pixel behavior for the whole frame, and every click in the top strip
/// gets routed to us and dies here — dead menu bar and title-bar buttons under the strip.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: CGRect = .zero
    /// Cleared while the pill is retracted for fullscreen so a hidden pill can never claim a click.
    var interactionEnabled = true
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactionEnabled, interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
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
    private let panelHeight: CGFloat = 300

    init(model: AppModel) {
        self.model = model
        hosting = PassthroughHostingView(rootView: IslandRootView(model: model))
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: panelHeight))
        panel.contentView = hosting
    }

    /// Resting frame: the full-width strip flush to the top of the notched screen (or main).
    private func restingFrame() -> NSRect? {
        guard let screen = NSScreen.island else { return nil }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - panelHeight,
                      width: screen.frame.width, height: panelHeight)
    }

    /// Position the full-width strip on the notched screen (or main), flush to its top.
    /// Called on launch and whenever the display configuration changes.
    ///
    /// Retract-aware: `sync()` also runs this on Claude launch/quit and screen-parameter changes,
    /// which can happen mid-fullscreen. A retracted pill must stay retracted, or an invisible
    /// (alpha-0) panel would be parked back over the fullscreen app until the next show().
    func relayout() {
        guard var frame = restingFrame() else { return }
        if isRetracted { frame.origin.y += slideDistance }
        panel.setFrame(frame, display: true)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        updateInteractiveZone()
    }

    /// Resize only the invisible click-catcher to the pill's current footprint — cheap, no
    /// window resize, so no animation jump.
    func updateInteractiveZone() {
        let closedH = max(model.topInset, 30)
        let dropH = model.expandedDropHeight
        let zoneW = model.notchWidth + 56 * 2 + 24 + 24    // wing+gap+wing + edge insets + margin
        let zoneH = (model.isExpanded ? closedH + dropH + 8 : closedH + 6)
        let w = hosting.bounds.width
        let h = hosting.bounds.height
        hosting.interactiveRect = CGRect(x: (w - zoneW) / 2, y: h - zoneH, width: zoneW, height: zoneH)
    }

    /// How far the pill travels up (into the notch) when hiding for fullscreen. Enough to clear the
    /// collapsed pill + Clawd; paired with a fade so the retract reads cleanly.
    private let slideDistance: CGFloat = 110

    /// True while the pill is retracted for fullscreen: slid up, alpha 0, but still in the window
    /// list (see hide() for why it's never ordered out). relayout() consults this.
    private(set) var isRetracted = false

    /// Slide the pill down out of the notch into its resting spot. Used when leaving fullscreen or
    /// turning the option off.
    func show() {
        isRetracted = false
        hosting.interactionEnabled = true                      // interactive again
        guard let rest = restingFrame() else { panel.orderFrontRegardless(); return }
        if !panel.isVisible {                                  // first appearance: start retracted
            var start = rest; start.origin.y += slideDistance
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(rest, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// Slide the pill up into the notch and fade it out. The panel is NOT ordered out — removing it
    /// from the window list while a fullscreen Space is active makes macOS drop its
    /// `.canJoinAllSpaces` membership, pinning it to one Space afterward. Staying in the list (just
    /// transparent + slid up) keeps it on every Space.
    ///
    /// While retracted, interaction is additionally gated off at the view level (see
    /// PassthroughHostingView.interactionEnabled) so a hidden pill can never claim a click even if
    /// something repositions it on-screen. Window-server click-through of transparent pixels stays
    /// untouched — `ignoresMouseEvents` must never be set explicitly (see the note on the view).
    func hide() {
        model.isExpanded = false                               // never slide away mid-expand
        isRetracted = true
        hosting.interactionEnabled = false                     // a hidden pill must never eat clicks
        guard let rest = restingFrame() else { return }
        var end = rest; end.origin.y += slideDistance
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }
    }
}
