import SwiftUI

struct ExpandedView: View {
    let model: AppModel   // passed-in @Observable — plain property, NOT @State

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AvatarView(style: AvatarStyle.selected, active: !model.isPaused)
                Text("Usage").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                Spacer()
                if let end = model.snapshot.blockEnd {
                    Text("resets \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
            HStack(spacing: 14) {
                Ring(fraction: model.snapshot.blockFractionElapsed,
                     state: model.snapshot.ringState, lineWidth: 3.5)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.snapshot.blockRemaining.map { Fmt.hm($0) + " left" } ?? "No active block")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    Text("in current 5-hour block")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
            .padding(12).background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            let s = model.snapshot
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                metric("tokens today", Fmt.tokens(s.tokensToday))
                metric("est. cost today", Fmt.usd(s.costToday))
                metric("active session", Fmt.tokens(s.activeSessionTokens))
                metric("top model", s.topModel ?? "—")
            }
            HStack(spacing: 8) {
                pill("History") { NotificationCenter.default.post(name: .openHistory, object: nil) }
                pill("Settings") { NotificationCenter.default.post(name: .openSettings, object: nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(white: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 16, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let openHistory = Notification.Name("openHistory")
    static let openSettings = Notification.Name("openSettings")
}
