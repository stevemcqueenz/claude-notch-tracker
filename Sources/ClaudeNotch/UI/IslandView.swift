import SwiftUI
import AppKit

/// The notch-fused black island. Closed: Clawd + session-% flanking the camera. Expanded: it
/// grows taller (never wider), dropping a usage panel below the notch. The NotchShape's radii
/// animate, so it morphs like the notch itself growing.
struct IslandView: View {
    let model: AppModel
    let notchWidth: CGFloat
    let topInset: CGFloat

    private let wing: CGFloat = 56
    private let iconSize: CGFloat = 18
    private let edgeInset: CGFloat = 12   // keeps content off the pill's flared edges
    private let dropHeight: CGFloat = 176

    private var expanded: Bool { model.isExpanded }
    private var closedH: CGFloat { max(topInset, 30) }
    private var gap: CGFloat { notchWidth }
    private var closedWidth: CGFloat { wing + gap + wing + edgeInset * 2 }
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

    // MARK: closed row

    private var notchRow: some View {
        HStack(spacing: 0) {
            AvatarView(style: model.avatarStyle, active: !model.isPaused)
                .frame(width: iconSize, height: iconSize)
                .frame(width: wing, height: closedH)
                .onTapGesture { model.cycleAvatar() }
                .help("Click to change the icon")

            Color.clear.frame(width: gap, height: closedH)

            HStack(spacing: 5) {
                Text(model.sessionUsage.map(Fmt.pct) ?? "—")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                Ring(fraction: used, state: ringState(for: used), lineWidth: 3)
                    .frame(width: 14, height: 14)
            }
            .frame(width: wing, height: closedH)
            .contentShape(Rectangle())
            .onTapGesture { model.isExpanded.toggle() }
        }
        .padding(.horizontal, edgeInset)
    }

    // MARK: drop-down — usage panel below the notch

    private var dropDown: some View {
        VStack(alignment: .leading, spacing: 12) {
            usageBlock("clock", "5-Hour Session", model.sessionUsage, resets: model.sessionResetsAt)
            usageBlock("calendar", "7-Day Weekly", model.weeklyUsage, resets: model.weeklyResetsAt)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)

            HStack(spacing: 6) {
                if let f = model.lastFetch {
                    Text("Updated \(Fmt.ago(f)) ago")
                } else {
                    Text("token estimate")
                }
                Spacer()
                if !model.snapshot.isEmpty {
                    Text("\(Fmt.usd(model.snapshot.costToday)) today")
                }
            }
            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
    }

    private func usageBlock(_ icon: String, _ title: String,
                            _ value: Double?, resets: Date?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Text(value.map(Fmt.pct) ?? "—")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
            }
            UsageBar(fraction: value ?? 0)
            Text(resets.map { "Resets in \(Fmt.until($0))" } ?? "Resets —")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// A slim usage bar: grey normally, amber as it fills, red at the limit.
struct UsageBar: View {
    var fraction: Double

    private var color: Color {
        switch ringState(for: fraction) {
        case .ok: return Color.white.opacity(0.75)
        case .warn: return Color(red: 0.94, green: 0.62, blue: 0.15)
        case .critical: return Color(red: 0.89, green: 0.29, blue: 0.29)
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(color)
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                    .animation(.easeInOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 5)
    }
}
