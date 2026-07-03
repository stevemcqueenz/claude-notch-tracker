import SwiftUI

enum Fmt {
    static func hm(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
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

struct CollapsedView: View {
    let model: AppModel   // passed-in @Observable — plain property, NOT @State

    var body: some View {
        HStack {
            AvatarView(style: AvatarStyle.selected, active: !model.isPaused)
                .onTapGesture { NotificationCenter.default.post(name: .clawdTapped, object: nil) }
            Spacer(minLength: 60)   // gap over the physical notch
            HStack(spacing: 8) {
                Text(model.snapshot.blockRemaining.map(Fmt.hm) ?? "—")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white)
                Ring(fraction: model.snapshot.blockFractionElapsed,
                     state: model.snapshot.ringState)
                    .frame(width: 20, height: 20)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.isExpanded = true }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

extension Notification.Name { static let clawdTapped = Notification.Name("clawdTapped") }
