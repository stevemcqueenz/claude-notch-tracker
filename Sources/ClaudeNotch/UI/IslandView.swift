import SwiftUI
import AppKit

/// Top-anchors the pill inside the fixed full-width window, horizontally centered on the notch.
struct IslandRootView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            IslandView(model: model, notchWidth: model.notchWidth, topInset: model.topInset)
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

    /// 5-Hour tile: false = show burn-rate ETA when available, true = always show reset.
    @State private var prefReset = false
    /// Expanded view is a two-page pager: 0 = limits, 1 = local detail. dragX tracks a live swipe.
    @State private var page = 0
    @State private var dragX: CGFloat = 0
    /// The sessions block flips between today's active sessions and all-time top projects on tap.
    @State private var showAllTime = false

    private let wing: CGFloat = 56
    private let iconSize: CGFloat = 18
    private let edgeInset: CGFloat = 12   // keeps content off the pill's flared edges
    private var dropHeight: CGFloat { model.expandedDropHeight }

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
        .contextMenu { menu }
        .animation(.spring(response: 0.6, dampingFraction: 1.0), value: expanded)
        .animation(.easeInOut(duration: 0.3), value: used)
    }

    // Right-click menu (replaces the menu-bar item).
    @ViewBuilder private var menu: some View {
        Menu("Icon") {
            ForEach(AvatarStyle.allCases) { style in
                Button {
                    model.setAvatar(style)
                } label: {
                    if model.avatarStyle == style {
                        Label(style.label, systemImage: "checkmark")
                    } else {
                        Text(style.label)
                    }
                }
            }
        }
        Button(model.isPaused ? "Resume tracking" : "Pause tracking") { model.togglePause() }
        Button((model.animateIcon ? "✓ " : "") + "Animate icon") { model.toggleAnimateIcon() }
        Button((model.hideInFullscreen ? "✓ " : "") + "Hide in full screen") { model.toggleHideInFullscreen() }
        Button((LoginItem.isEnabled ? "✓ " : "") + "Launch at Login") { LoginItem.toggle() }
        Divider()
        Button("Check for Updates…") { Updater.shared.checkForUpdates() }
        Divider()
        Button("Claude Notch v\(AppInfo.version) — \(AppInfo.tagline)") {}.disabled(true)
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }

    // MARK: closed row

    private var notchRow: some View {
        HStack(spacing: 0) {
            AvatarView(style: model.avatarStyle, active: model.animateIcon && !model.isPaused && !model.isAtLimit,
                       urgency: model.iconUrgency)
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
            .opacity(model.isStale ? 0.5 : 1)          // dim when data isn't fresh
            .contentShape(Rectangle())
            .onTapGesture { model.isExpanded.toggle() }
        }
        .padding(.horizontal, edgeInset)
    }

    // MARK: drop-down — two swipeable pages below the notch

    private var contentWidth: CGFloat { closedWidth - edgeInset * 2 }
    private var pagerHeight: CGFloat { dropHeight - 29 }   // leaves room for the dots + padding

    private var dropDown: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    pageLimits.frame(width: contentWidth, height: pagerHeight, alignment: .top)
                    pageLocal.frame(width: contentWidth, height: pagerHeight, alignment: .top)
                }
                .offset(x: -CGFloat(page) * contentWidth + dragX)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: page)
            }
            .frame(width: contentWidth, height: pagerHeight, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { dragX = $0.translation.width }
                    .onEnded { v in
                        if v.translation.width < -40 { page = min(1, page + 1) }
                        else if v.translation.width > 40 { page = max(0, page - 1) }
                        dragX = 0
                    }
            )
            pageDots
        }
        .padding(.horizontal, edgeInset).padding(.top, 6).padding(.bottom, 9)
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<2, id: \.self) { i in
                Circle().fill(.white.opacity(i == page ? 0.85 : 0.25))
                    .frame(width: 5, height: 5)
                    .onTapGesture { page = i }
            }
        }
        .frame(height: 8)
    }

    // Page 1 — account limits (these cover ALL usage, incl. cloud) + local "today" tiles.
    private var pageLimits: some View {
        let s = model.snapshot
        return VStack(spacing: 8) {
            LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
                limitTile("5-Hour", model.sessionUsage, resets: model.sessionResetsAt,
                          eta: prefReset ? nil : model.etaToLimit)
                    .contentShape(Rectangle())
                    .onTapGesture { if model.etaToLimit != nil { prefReset.toggle() } }
                limitTile("7-Day", model.weeklyUsage, resets: model.weeklyResetsAt)
                fableTile
                tile("cost today · local", s.isEmpty ? "—" : Fmt.usd(s.costToday), height: .compact,
                     sub: model.projectedCostToday.map { "~\(Fmt.usd($0)) by tonight" })
                tile("tokens today · local", s.isEmpty ? "—" : Fmt.tokens(s.tokensToday), height: .compact)
                tile("credits", model.creditsValue, height: .compact, sub: model.creditsSubtitle)
            }
            .opacity(model.isStale ? 0.55 : 1)         // dim live limits when not fresh
            if model.isStale {                          // only surface a problem, never chrome
                Spacer(minLength: 0)
                Text("reconnecting…").font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // Page 2 — local detail: today vs all-time spend, and the running conversations.
    private var pageLocal: some View {
        let s = model.snapshot
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                statTile("today", cost: s.costToday, tokens: s.tokensToday, dim: s.isEmpty)
                statTile("all-time", cost: model.lifetime.cost, tokens: model.lifetime.tokens,
                         dim: model.lifetime.tokens == 0)
            }
            sessionsBlock
            Spacer(minLength: 0)
        }
    }

    private func statTile(_ label: String, cost: Double, tokens: Int, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(dim ? "—" : Fmt.usd(cost)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(dim ? " " : Fmt.tokens(tokens)).font(.system(size: 9.5)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.45)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // Tap to flip between today's active conversations and the biggest projects of all time.
    private var sessionsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(showAllTime ? "all-time · top projects" : "active sessions")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                // Tap hint: shows the other view you'll switch to.
                HStack(spacing: 3) {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 8, weight: .semibold))
                    Text(showAllTime ? "active" : "all-time").font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.09))
                .clipShape(Capsule())
            }
            if showAllTime {
                let projects = Array(model.lifetime.projects.prefix(3))
                if projects.isEmpty {
                    Text("scanning…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .frame(minHeight: 20)
                } else {
                    ForEach(projects) { p in
                        sessionRow(p.name, cost: p.cost, tokens: p.tokens, muted: false, empty: false)
                    }
                }
            } else {
                let sessions = Array(model.sessionsToday.prefix(3))
                if sessions.isEmpty {
                    let s = model.snapshot
                    sessionRow("this session", cost: s.activeSessionCost, tokens: s.activeSessionTokens,
                               muted: true, empty: s.isEmpty)
                } else {
                    ForEach(sessions) { s in
                        sessionRow(s.name, cost: s.cost, tokens: s.tokens, muted: false, empty: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { showAllTime.toggle() }
        .help("Click to switch active sessions / all-time")
    }

    private var shortPlan: String {
        (model.planName ?? "Claude").replacingOccurrences(of: "Claude ", with: "")
    }

    // Fable's own weekly limit (the Desktop app shows it). Falls back to accumulated local usage
    // until the account's usage response actually carries the Fable weekly figure.
    @ViewBuilder private var fableTile: some View {
        if let pct = model.fableUsage {
            limitTile("Fable", pct, resets: model.fableResetsAt)
        } else {
            tile("Fable", model.lifetime.fableTokens == 0 ? "—" : Fmt.tokens(model.lifetime.fableTokens),
                 height: .compact, sub: "all-time")
        }
    }

    private func sessionRow(_ project: String, cost: Double, tokens: Int,
                            muted: Bool, empty: Bool) -> some View {
        HStack(spacing: 6) {
            Text(project).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(muted ? 0.5 : 0.85)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if empty {
                Text("—").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            } else {
                (Text(Fmt.usd(cost)).foregroundStyle(.white)
                    + Text("  ·  \(Fmt.tokens(tokens))").foregroundStyle(.white.opacity(0.45)))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(minHeight: 20)
    }

    // A limit tile: label, big colour-coded %, and a "resets in …" subline.
    private func limitTile(_ label: String, _ value: Double?, resets: Date?,
                           eta: TimeInterval? = nil) -> some View {
        tileBox {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(value.map(Fmt.pct) ?? "—")
                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(barColor(value ?? 0))
            if let eta {
                Text("~\(Fmt.dur(eta)) to limit")
                    .font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
            } else {
                Text(resets.map { "resets in \(Fmt.until($0))" } ?? "resets —")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        }
    }

    enum TileHeight { case compact, tall
        var minHeight: CGFloat { self == .compact ? 54 : 54 }   // page-1 tiles are uniform, compact
        var valueSize: CGFloat { self == .compact ? 15 : 17 }
    }

    // A plain value tile, with an optional muted subline (e.g. a projection).
    private func tile(_ label: String, _ value: String, height: TileHeight, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: height.valueSize, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            if let sub {
                Text(sub).font(.system(size: 9.5)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height.minHeight, alignment: .topLeading)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func tileBox<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 1, content: content)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            .padding(.horizontal, 10).padding(.vertical, 5)
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
