import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats at notch level.
@MainActor
final class IslandWindow {
    let panel: NSPanel
    private let hosting: NSHostingView<IslandView>
    private let width: CGFloat

    init(model: AppModel, notchWidth: CGFloat, topInset: CGFloat) {
        width = 56 + notchWidth + 56   // wing + camera gap + wing (matches IslandView)
        hosting = NSHostingView(rootView:
            IslandView(model: model, notchWidth: notchWidth, topInset: topInset))
        panel = NSPanel(contentRect: .init(x: 0, y: 0, width: width, height: max(topInset, 30)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.ignoresMouseEvents = false
    }

    /// Width is fixed; only the height (and top-anchored origin) changes, so the island
    /// grows straight down from the notch instead of resizing sideways.
    func reposition() {
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height     // top stays flush to the screen edge
        panel.setFrame(.init(x: x, y: y, width: width, height: height), display: true)
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}
