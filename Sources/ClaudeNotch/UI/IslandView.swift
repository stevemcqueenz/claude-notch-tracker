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
    private var provider: ProviderUsageSnapshot { model.activeProviderSnapshot }
    private var used: Double { provider.primaryUsage ?? 0 }
    /// Loaded once — this is read on every render of the closed row, and hitting the disk per
    /// frame during animations would be pure waste. MainActor because NSImage isn't Sendable.
    @MainActor private static let codexIcon: NSImage? = {
        if let resourcesURL = Bundle.main.resourceURL,
           let packagedBundle = Bundle(
               url: resourcesURL.appendingPathComponent("ClaudeNotch_ClaudeNotch.bundle")
           ),
           let url = packagedBundle.url(forResource: "codex", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        guard let url = Bundle.module.url(forResource: "codex", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

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
        .onChange(of: model.selectedProvider) { _, _ in
            showAllTime = false
            page = 0
        }
        .animation(.spring(response: 0.6, dampingFraction: 1.0), value: expanded)
        .animation(.easeInOut(duration: 0.3), value: used)
    }

    // Right-click menu (replaces the menu-bar item).
    @ViewBuilder private var menu: some View {
        Menu("Provider") {
            ForEach(UsageProviderID.allCases) { provider in
                Button {
                    model.selectProvider(provider)
                } label: {
                    if model.selectedProvider == provider {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
        }
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
            providerIcon
                .frame(width: iconSize, height: iconSize)
                .frame(width: wing, height: closedH)
                .contentShape(Rectangle())
                // Tap switches provider (Claude ⇄ Codex); the Claude icon style is picked from
                // the right-click Icon menu.
                .onTapGesture { model.cycleProvider() }
                .help("Click to switch provider")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Switch provider")
                .accessibilityValue(model.selectedProvider.displayName)
                .accessibilityHint("Switches between Claude and Codex")
                .accessibilityAddTraits(.isButton)
                .accessibilityInputLabels(["Switch provider", model.selectedProvider.displayName])

            Color.clear.frame(width: gap, height: closedH)

            HStack(spacing: 5) {
                Text(provider.primaryUsage.map(Fmt.pct) ?? "—")
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

    @ViewBuilder private var providerIcon: some View {
        if model.selectedProvider == .claude {
            AvatarView(style: model.avatarStyle,
                       active: model.animateIcon && !model.isPaused && !model.isAtLimit,
                       urgency: model.iconUrgency)
        } else if let icon = Self.codexIcon {
            CodexIconView(
                image: icon,
                active: model.animateIcon && !model.isPaused && !model.isAtLimit,
                urgency: model.iconUrgency
            )
            .opacity(model.isPaused ? 0.45 : 0.9)
        } else if let symbol = NSImage(
            systemSymbolName: model.selectedProvider.systemImage,
            accessibilityDescription: model.selectedProvider.displayName
        ) {
            Image(nsImage: symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(model.isPaused ? 0.45 : 0.9))
        } else {
            Text("C")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(model.isPaused ? 0.45 : 0.9))
        }
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

    // Page 1 — provider-defined account limits and summary metrics.
    private var pageLimits: some View {
        let snapshot = provider
        // With a daily feed, the page is limits + the week chart as centerpiece; the plain
        // six-tile grid remains for providers/accounts without one (API-key Codex) and for
        // providers that keep the chart on the detail page (Claude, whose limit tiles fill this
        // one). More than two limit windows also falls back — the windows outrank the chart.
        let chartLayout = chartOnLimitsPage
        let gridSlots = chartLayout ? 2 : 6
        let remainingSlots = max(0, gridSlots - snapshot.limits.count)
        return VStack(spacing: 8) {
            LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Array(snapshot.limits.prefix(gridSlots))) { metric in
                    providerLimitTile(metric)
                }
                ForEach(Array(snapshot.stats.prefix(remainingSlots))) { metric in
                    tile(metric.label, metric.value, height: .compact, sub: metric.subtitle)
                }
            }
            .opacity(model.isStale ? 0.55 : 1)         // dim live limits when not fresh
            if chartLayout {
                WeekActivityChart(series: snapshot.dailySeries, title: snapshot.chartTitle)
                    .opacity(model.isStale ? 0.55 : 1)
            }
            if let message = snapshot.statusMessage {
                Spacer(minLength: 0)
                Text(message).font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1).truncationMode(.tail)
            } else if model.isStale {                   // only surface a problem, never chrome
                Spacer(minLength: 0)
                Text("reconnecting…").font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// True when the limits page hosts the week chart (Codex-style); the detail page then keeps
    /// its stat tiles. When false and a series exists (Claude), the chart lives on the detail page.
    private var chartOnLimitsPage: Bool {
        let s = provider
        return !s.dailySeries.isEmpty && !s.chartOnDetailPage && s.limits.count <= 2
    }

    // Page 2 — provider detail: the week chart (when page 1 is full of limit tiles) or the
    // today/all-time totals, above recent sessions/tasks.
    private var pageLocal: some View {
        let snapshot = provider
        let chartHere = !snapshot.dailySeries.isEmpty && !chartOnLimitsPage
        // A bare "today: —" tile is dead weight. When the provider has no today figure but does
        // have a daily feed, show the week total instead — always a real number.
        let showWeek = snapshot.todayCost == nil && snapshot.todayTokens == nil
            && snapshot.weekTokens != nil
        // "peak 501.5M" beats the word "tokens" under the all-time figure, when known.
        let peakDetail = snapshot.stats.first(where: { $0.id == "peak-day" })
            .map { "peak \($0.value)" }
        return VStack(spacing: 8) {
            if chartHere {
                WeekActivityChart(series: snapshot.dailySeries, title: snapshot.chartTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    if showWeek {
                        statTile("this week · account", cost: nil, tokens: snapshot.weekTokens)
                    } else {
                        statTile("today", cost: snapshot.todayCost, tokens: snapshot.todayTokens)
                    }
                    statTile("all-time", cost: snapshot.lifetimeCost, tokens: snapshot.lifetimeTokens,
                             detail: peakDetail)
                }
            }
            sessionsBlock
            Spacer(minLength: 0)
        }
    }

    private func statTile(_ label: String, cost: Double?, tokens: Int?,
                          detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(summaryPrimary(cost: cost, tokens: tokens))
                .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(detail ?? summarySecondary(cost: cost, tokens: tokens))
                .font(.system(size: 9.5)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.45)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func summaryPrimary(cost: Double?, tokens: Int?) -> String {
        if let cost { return Fmt.usd(cost) }
        if let tokens { return Fmt.tokens(tokens) }
        return "—"
    }

    private func summarySecondary(cost: Double?, tokens: Int?) -> String {
        if cost != nil, let tokens { return Fmt.tokens(tokens) }
        if tokens != nil { return "tokens" }
        return " "
    }

    // Tap to flip between the provider's primary and alternate session lists when both exist.
    private var sessionsBlock: some View {
        let snapshot = provider
        let hasAlternate = snapshot.alternateSessionsTitle != nil
        let showingAlternate = showAllTime && hasAlternate
        let title = showingAlternate ? snapshot.alternateSessionsTitle! : snapshot.sessionsTitle
        let sessions = showingAlternate ? snapshot.alternateSessions : snapshot.sessions
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if hasAlternate {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 8, weight: .semibold))
                        Text(showingAlternate ? snapshot.sessionsTitle : snapshot.alternateSessionsTitle!)
                            .font(.system(size: 9, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.09))
                    .clipShape(Capsule())
                }
            }
            if sessions.isEmpty {
                sessionRow("No recent activity", cost: nil, tokens: nil, last: nil, muted: true)
            } else {
                ForEach(Array(sessions.prefix(3))) { session in
                    sessionRow(session.name, cost: session.cost, tokens: session.tokens,
                               last: session.last, muted: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { if hasAlternate { showAllTime.toggle() } }
        .help(hasAlternate ? "Click to switch session views" : "Recent provider activity")
    }

    private func sessionRow(_ project: String, cost: Double?, tokens: Int?, last: Date?,
                            muted: Bool) -> some View {
        HStack(spacing: 6) {
            Text(project).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(muted ? 0.5 : 0.85)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let cost, let tokens {
                (Text(Fmt.usd(cost)).foregroundStyle(.white)
                    + Text("  ·  \(Fmt.tokens(tokens))").foregroundStyle(.white.opacity(0.45)))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else if let tokens {
                Text(Fmt.tokens(tokens)).foregroundStyle(.white)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            } else if let cost {
                Text(Fmt.usd(cost)).foregroundStyle(.white)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            } else if let last {
                Text(Fmt.ago(last)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45)).monospacedDigit()
            } else {
                Text("—").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(minHeight: 20)
    }

    @ViewBuilder private func providerLimitTile(_ metric: UsageLimitMetric) -> some View {
        let isClaudeSession = metric.id == "claude-session"
        limitTile(metric.label, metric.usedFraction, resets: metric.resetsAt,
                  eta: isClaudeSession && !prefReset ? model.etaToLimit : nil)
            .contentShape(Rectangle())
            .onTapGesture {
                if isClaudeSession, model.etaToLimit != nil { prefReset.toggle() }
            }
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
