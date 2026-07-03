import SwiftUI
import AppKit

/// Top-anchors the pill inside the fixed full-width window, horizontally centered on the notch.
struct IslandRootView: View {
    let model: AppModel
    let notchWidth: CGFloat
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            IslandView(model: model, notchWidth: notchWidth, topInset: topInset)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The notch-fused black island. Closed: Clawd + session-% flanking the camera. Expanded: it
/// grows taller (never wider), dropping a tile grid below the notch. The NotchShape's radii
/// animate, so it morphs like the notch itself growing.
struct IslandView: View {
    let model: AppModel
    let notchWidth: CGFloat
    let topInset: CGFloat

    private let wing: CGFloat = 56
    private let iconSize: CGFloat = 18
    private let edgeInset: CGFloat = 12   // keeps content off the pill's flared edges
    private let dropHeight: CGFloat = 172

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

    // MARK: drop-down — tile grid below the notch

    private var dropDown: some View {
        let s = model.snapshot
        return VStack(spacing: 8) {
            LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
                limitTile("5-Hour", model.sessionUsage, resets: model.sessionResetsAt)
                limitTile("7-Day", model.weeklyUsage, resets: model.weeklyResetsAt)
                tile("credits", model.limits?.creditsPct.map { Fmt.pct($0) + " used" } ?? "none", height: .compact)
                tile("cost today", s.isEmpty ? "—" : Fmt.usd(s.costToday), height: .compact)
                tile("tokens today", s.isEmpty ? "—" : Fmt.tokens(s.tokensToday), height: .compact)
                tile("plan", shortPlan, height: .compact)
            }
            HStack {
                Text(model.lastFetch.map { "Updated \(Fmt.ago($0)) ago" } ?? "token estimate")
                Spacer()
                Text(model.usageSource)
            }
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 9)
    }

    private var shortPlan: String {
        (model.planName ?? "Claude").replacingOccurrences(of: "Claude ", with: "")
    }

    // A limit tile: label, big colour-coded %, and a "resets in …" subline.
    private func limitTile(_ label: String, _ value: Double?, resets: Date?) -> some View {
        tileBox {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(value.map(Fmt.pct) ?? "—")
                .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                .foregroundStyle(barColor(value ?? 0))
            Text(resets.map { "resets in \(Fmt.until($0))" } ?? "resets —")
                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }
    }

    enum TileHeight { case compact, tall
        var minHeight: CGFloat { self == .compact ? 34 : 54 }
        var valueSize: CGFloat { self == .compact ? 13 : 17 }
    }

    // A plain value tile.
    private func tile(_ label: String, _ value: String, height: TileHeight) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: height.valueSize, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: height.minHeight, alignment: .topLeading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func tileBox<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2, content: content)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func barColor(_ used: Double) -> Color {
        switch ringState(for: used) {
        case .ok: return .white
        case .warn: return Color(red: 0.96, green: 0.70, blue: 0.20)
        case .critical: return Color(red: 0.92, green: 0.34, blue: 0.34)
        }
    }
}
