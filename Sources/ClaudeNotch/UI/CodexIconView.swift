import AppKit
import SwiftUI

/// Gives the supplied Codex mark a calm floating motion while tracking is active.
struct CodexIconView: View {
    let image: NSImage
    var active: Bool
    var urgency: Double

    private var cyclesPerSecond: Double {
        0.45 + min(1, max(0, urgency)) * 0.55
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * cyclesPerSecond * 2 * Double.pi
            let wave = active ? sin(phase) : 0
            let drift = active ? sin(phase * 0.5 + 0.8) : 0

            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .scaleEffect(1 + wave * 0.045)
                .offset(y: wave * 0.8)
                .rotationEffect(.degrees(drift * 1.4))
        }
        .frame(height: 24)
    }
}
