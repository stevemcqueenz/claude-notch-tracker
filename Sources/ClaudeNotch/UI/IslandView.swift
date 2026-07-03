import SwiftUI
import AppKit

/// The notch-fused black island. Closed: Clawd + block-% flanking the camera. Expanded: it grows
/// taller (never wider), dropping a detail panel below the notch. The NotchShape's radii animate,
/// so the whole thing morphs like the notch itself growing.
struct IslandView: View {
    let model: AppModel
    let notchWidth: CGFloat
    let topInset: CGFloat

    private let wing: CGFloat = 56
    private let iconSize: CGFloat = 18
    private let dropHeight: CGFloat = 178
    private let wingInset: CGFloat = 4    // nudge content toward the notch (past the top flare)

    private var expanded: Bool { model.isExpanded }
    private var closedH: CGFloat { max(topInset, 30) }
    private var gap: CGFloat { notchWidth }
    private var closedWidth: CGFloat { wing + gap + wing }
    private var used: Double { model.sessionUsage ?? 0 }

    var body: some View {
        let shape = NotchShape(topRadius: 8,
                               bottomRadius: expanded ? 22 : max(10, closedH * 0.40))
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            VStack(spacing: 0) {
                notchRow.frame(width: closedWidth, height: closedH)
                dropDown
                    .frame(width: closedWidth, height: dropHeight, alignment: .top)
                    .opacity(expanded ? 1 : 0)
            }
        }
        .frame(width: closedWidth,
               height: expanded ? closedH + dropHeight : closedH,
               alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .animation(.spring(response: 0.6, dampingFraction: 1.0), value: expanded)
        .animation(.easeInOut(duration: 0.3), value: used)
    }

    // MARK: closed row — balanced wings centered on the camera

    private var notchRow: some View {
        HStack(spacing: 0) {
            AvatarView(style: AvatarStyle.selected, active: !model.isPaused)
                .frame(width: iconSize, height: iconSize)
                .frame(width: wing, height: closedH)
                .offset(x: wingInset)
                .onTapGesture { NotificationCenter.default.post(name: .clawdTapped, object: nil) }

            Color.clear.frame(width: gap, height: closedH)

            HStack(spacing: 5) {
                Text(model.sessionUsage.map(Fmt.pct) ?? "—")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                Ring(fraction: used, state: ringState(for: used), lineWidth: 3)
                    .frame(width: 14, height: 14)
            }
            .frame(width: wing, height: closedH)
            .offset(x: -wingInset)
            .contentShape(Rectangle())
            .onTapGesture { model.isExpanded.toggle() }
        }
    }

    // MARK: drop-down — detail below the notch

    private var dropDown: some View {
        let s = model.snapshot
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.sessionUsage.map { "Session \(Fmt.pct($0)) used" } ?? "Session usage —")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if let ctx = model.contextRemaining {
                    Text("ctx \(Fmt.pct(ctx)) left")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                }
            }

            if s.isEmpty {
                Text("No usage yet — start a Claude session")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            } else {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 6) {
                    metric("tokens today", Fmt.tokens(s.tokensToday))
                    metric("cost today", Fmt.usd(s.costToday))
                    metric("session", Fmt.tokens(s.activeSessionTokens))
                    metric("top model", s.topModel ?? "—")
                }
            }

            HStack(spacing: 6) {
                pill("Settings") { NotificationCenter.default.post(name: .openSettings, object: nil) }
                pill("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}
