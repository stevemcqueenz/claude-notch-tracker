import SwiftUI
import AppKit

struct AvatarView: View {
    var style: AvatarStyle
    var active: Bool
    @State private var wiggle = false

    var body: some View {
        Group {
            switch style {
            case .clawd:  clawd
            case .spark:  spark
            case .custom: custom
            }
        }
        .frame(width: 24, height: 24)
        .rotationEffect(.degrees(active && wiggle ? 6 : -6))
        .animation(active ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                          : .default, value: wiggle)
        .onAppear { wiggle = active }
        .onChange(of: active) { _, now in wiggle = now }
    }

    private var clawd: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.85, green: 0.47, blue: 0.34))
            HStack(spacing: 4) {
                Circle().fill(.white).frame(width: 4, height: 4)
                Circle().fill(.white).frame(width: 4, height: 4)
            }.offset(y: -1)
        }
    }

    private var spark: some View {
        Image(systemName: "sparkle")
            .resizable().scaledToFit()
            .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
    }

    private var custom: some View {
        Group {
            if let p = AvatarStyle.customImagePath, let img = NSImage(contentsOfFile: p) {
                Image(nsImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else { clawd }
        }
    }
}
