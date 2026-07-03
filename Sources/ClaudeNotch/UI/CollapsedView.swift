import SwiftUI

enum Fmt {
    static func hm(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }
    static func pct(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
}

/// The pill row shared by the collapsed island and the top of the expanded island:
/// Clawd on the left, a gap for the physical notch, block-% + ring on the right.
struct IslandTopRow: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            AvatarView(style: AvatarStyle.selected, active: !model.isPaused)
                .onTapGesture { NotificationCenter.default.post(name: .clawdTapped, object: nil) }
            Spacer(minLength: 80)   // clears the physical notch in the center
            HStack(spacing: 8) {
                Text(model.snapshot.blockRemaining == nil
                     ? "—" : Fmt.pct(model.snapshot.blockFractionElapsed))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                Ring(fraction: model.snapshot.blockFractionElapsed,
                     state: model.snapshot.ringState)
                    .frame(width: 20, height: 20)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.isExpanded.toggle() }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

struct CollapsedView: View {
    let model: AppModel   // passed-in @Observable — plain property, NOT @State
    var body: some View { IslandTopRow(model: model) }
}

extension Notification.Name {
    static let clawdTapped = Notification.Name("clawdTapped")
    static let openSettings = Notification.Name("openSettings")
}
