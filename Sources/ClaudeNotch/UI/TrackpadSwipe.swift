import SwiftUI
import AppKit

/// Reports two-finger horizontal trackpad swipes over its frame, shaped like a DragGesture:
/// `onChange` gets the running finger translation, `onEnd` the final one (0 when cancelled).
/// DragGesture only sees click-drags; trackpad swipes arrive as scroll-wheel events, which a
/// local monitor catches even though the panel never becomes key.
struct TrackpadSwipeReader: NSViewRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> SwipeView { SwipeView() }

    func updateNSView(_ view: SwipeView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
    }

    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.stopMonitoring() }

    final class SwipeView: NSView {
        var onChange: (CGFloat) -> Void = { _ in }
        var onEnd: (CGFloat) -> Void = { _ in }

        /// A gesture's axis is locked once it moves a few points, so vertical scrolls pass through.
        private enum Axis { case undecided, horizontal, ignored }
        private var axis = Axis.ignored
        private var dx: CGFloat = 0
        private var dy: CGFloat = 0
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steal clicks

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the event belongs to a horizontal swipe and should be swallowed.
        private func handle(_ event: NSEvent) -> Bool {
            // Momentum after lift-off: the page has already been decided, just keep it from leaking.
            if event.momentumPhase != [] { return axis == .horizontal }
            // No phase = a discrete mouse wheel, not a swipe.
            guard event.phase != [] else { return false }
            // Fingers merely resting on the pad (followed by .cancelled if they never move). The
            // axis may still be .horizontal from the last swipe, which would replay its stale dx.
            if event.phase.contains(.mayBegin) { axis = .ignored; return false }

            if event.phase.contains(.began) {
                let p = convert(event.locationInWindow, from: nil)
                axis = event.window === window && bounds.contains(p) ? .undecided : .ignored
                dx = 0
                dy = 0
            }
            guard axis != .ignored else { return false }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                guard axis == .horizontal else { axis = .ignored; return false }
                onEnd(event.phase.contains(.ended) ? dx : 0)
                return true   // axis stays horizontal so the momentum tail is swallowed too
            }

            // With natural scrolling the deltas already follow the fingers; otherwise flip them.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            dx += event.scrollingDeltaX * sign
            dy += event.scrollingDeltaY * sign
            if axis == .undecided, max(abs(dx), abs(dy)) > 4 {
                axis = abs(dx) > abs(dy) ? .horizontal : .ignored
            }
            guard axis == .horizontal else { return false }
            onChange(dx)
            return true
        }
    }
}
