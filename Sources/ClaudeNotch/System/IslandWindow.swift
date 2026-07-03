import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats at notch level.
@MainActor
final class IslandWindow {
    let panel: NSPanel
    private let hosting: NSHostingView<IslandView>

    init(model: AppModel) {
        hosting = NSHostingView(rootView: IslandView(model: model))
        panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 420, height: 40),
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

    /// Size the panel to its SwiftUI content and pin it centered at the top.
    func reposition(notchWidth: CGFloat) {
        let fitting = hosting.fittingSize
        let width = max(fitting.width, notchWidth > 0 ? notchWidth + 200 : 320)
        let height = fitting.height
        panel.setContentSize(.init(width: width, height: height))
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height     // flush to the top edge
        panel.setFrameOrigin(.init(x: x, y: y))
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}
