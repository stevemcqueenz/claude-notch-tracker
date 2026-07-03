import SwiftUI
import AppKit

/// Decodes the bundled base64 PNG animation frames (MIT, see Assets/*.swift headers).
enum AvatarFrames {
    static let crab: [NSImage] = decode(clawdCrabFramePNGs)    // walking Clawd, full color
    static let spark: [NSImage] = decode(claudeSparkFramePNGs) // alpha masks, tinted at runtime

    private static func decode(_ b64s: [String]) -> [NSImage] {
        b64s.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }
}

struct AvatarView: View {
    var style: AvatarStyle
    var active: Bool
    private let fps = 10.0

    private var clay: Color { Color(red: 0.85, green: 0.47, blue: 0.34) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / fps,
                                paused: !active || style == .custom)) { timeline in
            frame(at: timeline.date)
        }
        .frame(height: 24)
    }

    @ViewBuilder private func frame(at date: Date) -> some View {
        switch style {
        case .clawd: raster(AvatarFrames.crab, at: date, tinted: false)
        case .spark: raster(AvatarFrames.spark, at: date, tinted: true)
        case .custom: customImage
        }
    }

    @ViewBuilder private func raster(_ frames: [NSImage], at date: Date, tinted: Bool) -> some View {
        if frames.isEmpty {
            Image(systemName: "sparkle").resizable().scaledToFit().foregroundStyle(clay)
        } else {
            let idx = active ? Int(date.timeIntervalSinceReferenceDate * fps) % frames.count : 0
            let base = Image(nsImage: frames[idx])
            (tinted ? base.renderingMode(.template) : base)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .foregroundStyle(clay)   // tints only template (spark); ignored for color crab
        }
    }

    @ViewBuilder private var customImage: some View {
        if let p = AvatarStyle.customImagePath, let img = NSImage(contentsOfFile: p) {
            Image(nsImage: img).resizable().scaledToFit()
        } else {
            raster(AvatarFrames.crab, at: .distantPast, tinted: false)
        }
    }
}
