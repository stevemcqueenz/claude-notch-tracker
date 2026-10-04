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
/// grows taller (never wider), dropping limit meters and tiles below the notch. The NotchShape's
/// radii animate, so it morphs like the notch itself growing.
struct IslandView: View {
    let model: AppModel
    let notchWidth: CGFloat
    let topInset: CGFloat

    /// Expanded view is a two-page pager: 0 = limits, 1 = activity. dragX tracks a live swipe.
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
    /// Loaded once each — these are read on every render of the closed row, and hitting the disk
    /// per frame during animations would be pure waste. MainActor because NSImage isn't Sendable.
    @MainActor private static let codexIcon: NSImage? = mark(named: "codex")
    @MainActor private static let antigravityIcon: NSImage? = mark(named: "antigravity")
    @MainActor private static let deepseekIcon: NSImage? = mark(named: "deepseek")
    @MainActor private static let opencodegoIcon: NSImage? = mark(named: "opencodego")

    /// Resolves a bundled provider mark, preferring the packaged .app layout over SwiftPM's.
    private static func mark(named name: String) -> NSImage? {
        if let resourcesURL = Bundle.main.resourceURL,
           let packagedBundle = Bundle(
               url: resourcesURL.appendingPathComponent("ClaudeNotch_ClaudeNotch.bundle")
           ),
           let url = packagedBundle.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    @MainActor private static func mark(for provider: UsageProviderID) -> NSImage? {
        switch provider {
        case .claude: nil               // Claude draws an animated avatar instead of a mark.
        case .codex: codexIcon
        case .antigravity: antigravityIcon
        case .deepseek: deepseekIcon
        case .opencodeGo: opencodegoIcon
        }
    }

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
        .animation(.easeInOut(duration: 0.35), value: model.selectedProvider)
    }

    // Right-click menu (replaces the menu-bar item).
    @ViewBuilder private var menu: some View {
        Menu("Provider") {
            ForEach(UsageProviderID.allCases) { provider in
                Button {
                    model.selectProvider(provider)
                } label: {
                    // Undetected providers stay listed and selectable: hiding them would make the
                    // feature invisible to anyone who installs the tool later.
                    let name = ProviderAvailability.isAvailable(provider)
                        ? provider.displayName
                        : "\(provider.displayName) (not detected)"
                    if model.selectedProvider == provider {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        }
        // Every style here is a Claude mark, and Codex draws its own logo, so the picker would
        // have no effect on what's on screen.
        if model.selectedProvider == .claude {
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
        }
        Menu("Rotate providers") {
            ForEach(AppModel.rotationChoices, id: \.self) { seconds in
                let title = seconds == 0 ? "Off" : (seconds < 60 ? "Every \(seconds) s" : "Every \(seconds / 60) min")
                Button((model.rotationInterval == seconds ? "✓ " : "") + title) {
                    model.setRotationInterval(seconds)
                }
            }
        }
        Button(DeepSeekCredentials.isConfigured ? "DeepSeek API Key… ✓" : "DeepSeek API Key…") {
            DeepSeekKeyPrompt.run { model.deepSeekCredentialsChanged() }
        }
        Button("Refresh now") { model.refreshNow() }
        Button(model.isPaused ? "Resume tracking" : "Pause tracking") { model.togglePause() }
        Button((model.animateIcon ? "✓ " : "") + "Animate icon") { model.toggleAnimateIcon() }
        Button((model.hideInFullscreen ? "✓ " : "") + "Hide in full screen") { model.toggleHideInFullscreen() }
        Button((LoginItem.isEnabled ? "✓ " : "") + "Launch at Login") { LoginItem.toggle() }
        Divider()
        Button("Check for Updates…") { Updater.shared.checkForUpdates() }
        Button("GitHub Repository…") { NSWorkspace.shared.open(AppInfo.repository) }
        Divider()
        Button("Claude Notch v\(AppInfo.version) — \(AppInfo.tagline)") {}.disabled(true)
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }

    // MARK: closed row

    private var notchRow: some View {
        HStack(spacing: 0) {
            providerIcon
                .id(model.selectedProvider)          // cross-fades on a provider switch
                .transition(.opacity)
                .frame(width: iconSize, height: iconSize)
                .modifier(WhaleSpoutTrigger(
                    observedAt: model.selectedProvider == .deepseek ? provider.spendObservedAt : nil,
                    active: model.animateIcon && !model.isPaused,
                    iconSize: iconSize))
                .frame(width: wing, height: closedH)
                .contentShape(Rectangle())
                // Tap cycles the providers this Mac has. With only one it cycles Clawd's look
                // instead, which is what the click did before there was more than one provider.
                .onTapGesture { model.cycleProvider() }
                .help((model.iconClickSwitchesProvider
                       ? "Click to switch provider"
                       : "Click to change the icon")
                      + (model.selectedProvider == .deepseek ? " · spouts when your balance drops" : ""))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.iconClickSwitchesProvider ? "Switch provider" : "Change icon")
                .accessibilityValue(model.selectedProvider.displayName)
                .accessibilityHint(model.iconClickSwitchesProvider
                                   ? "Cycles the providers installed on this Mac"
                                   : "Cycles Clawd, mono and Spark")
                .accessibilityAddTraits(.isButton)
                .accessibilityInputLabels(["Switch provider", model.selectedProvider.displayName])

            Color.clear.frame(width: gap, height: closedH)

            Group {
                if let pill = provider.pill {
                    // No fraction to ring (DeepSeek): the value, and a dot in the ring's place.
                    HStack(spacing: 5) {
                        Text(pill.text)
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(pill.tint == .critical ? color(.critical) : .white)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Circle().fill(color(pill.tint)).frame(width: 7, height: 7)
                    }
                } else {
                    HStack(spacing: 5) {
                        Text(provider.primaryUsage.map(Fmt.pct) ?? "—")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.white)
                        Ring(fraction: used, state: ringState(for: used), lineWidth: 3)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .id(model.selectedProvider)
            .transition(.opacity)
            .frame(width: wing, height: closedH)
            .opacity(model.isStale ? 0.5 : 1)          // dim when data isn't fresh
            .contentShape(Rectangle())
            .onTapGesture { model.isExpanded.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.selectedProvider.displayName) usage")
            .accessibilityValue(pillSpokenValue)
            .accessibilityHint(model.isExpanded ? "Collapses the usage card" : "Expands the usage card")
            .accessibilityAddTraits(.isButton)
        }
        .padding(.horizontal, edgeInset)
    }

    /// "42%", or "100%, 7-Day limit" when a used-up limit has taken over from the first one.
    private var pillSpokenValue: String {
        if let pill = provider.pill { return pill.text }
        guard let usage = provider.primaryUsage else { return "unknown" }
        guard let binding = provider.bindingLimit, binding.id != provider.limits.first?.id
        else { return Fmt.pct(usage) }
        return "\(Fmt.pct(usage)), \(binding.label) limit"
    }

    @ViewBuilder private var providerIcon: some View {
        if model.selectedProvider == .claude {
            AvatarView(style: model.avatarStyle,
                       active: model.animateIcon && !model.isPaused && !model.isAtLimit,
                       urgency: model.iconUrgency)
        } else if let icon = Self.mark(for: model.selectedProvider) {
            ProviderMarkView(
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
                    .onEnded { endSwipe($0.translation.width) }
            )
            .background(TrackpadSwipeReader(onChange: { dragX = $0 }, onEnd: endSwipe))
            pageDots
        }
        .padding(.horizontal, edgeInset).padding(.top, 6).padding(.bottom, 9)
    }

    /// Settles a click-drag or trackpad swipe: past 40pt flips the page, otherwise snaps back.
    private func endSwipe(_ translation: CGFloat) {
        if translation < -40 { page = min(1, page + 1) }
        else if translation > 40 { page = max(0, page - 1) }
        dragX = 0
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<2, id: \.self) { i in
                Circle().fill(.white.opacity(i == page ? 0.85 : 0.25))
                    .frame(width: 5, height: 5)
                    .onTapGesture { page = i }
                    .accessibilityLabel(i == 0 ? "Limits page" : "Detail page")
                    .accessibilityAddTraits(i == page ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(height: 8)
    }

    // Page 1 — provider-defined account limits and summary metrics.
    /// Nothing to render at all: a provider that isn't set up yet, or one whose first fetch
    /// hasn't landed. Centred and calm, because this is a setup state rather than a failure.
    /// The bottom warning line is for problems with data we *do* have (stale, spend capped).
    private var providerPlaceholder: some View {
        VStack(spacing: 5) {
            Spacer(minLength: 0)
            Text(provider.provider.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(provider.statusMessage ?? "Waiting for the first reading")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 14)
    }

    /// True when the page would otherwise be an empty grid with a lone warning line at the floor.
    private var providerHasNothingToShow: Bool {
        let s = provider
        return s.limits.isEmpty && s.stats.isEmpty && s.dailySeries.isEmpty && s.sessions.isEmpty
    }

    private static let amber = Color(red: 0.96, green: 0.70, blue: 0.20)

    /// Account-wide limits first, then per-model ones; three meters keep the page breathing.
    private var meterLimits: [UsageLimitMetric] {
        let limits = provider.limits
        return Array((limits.filter { !$0.scoped } + limits.filter(\.scoped)).prefix(3))
    }

    private var pageLimits: some View {
        let snapshot = provider
        return VStack(spacing: 8) {
            if providerHasNothingToShow {
                providerPlaceholder
            } else {
                if snapshot.limits.isEmpty {
                    // Nothing to meter (DeepSeek): the stat tiles are the page.
                    LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(Array(snapshot.stats.prefix(6))) { metric in
                            tile(metric.label, metric.value, height: .compact, sub: metric.subtitle,
                                 tint: metric.tint)
                        }
                    }
                    .opacity(model.isStale ? 0.55 : 1)      // dim live numbers when not fresh
                } else {
                    VStack(spacing: 10) {
                        ForEach(meterLimits) { metric in
                            // Claude only: the 5-hour trend says the limit lands before the reset.
                            LimitMeterRow(metric: metric,
                                          note: metric.id == "claude-session"
                                              ? model.etaToLimit.map { "~\(Fmt.dur($0)) to limit" } : nil)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .opacity(model.isStale ? 0.55 : 1)
                    // A problem replaces the stats rather than squeezing in below them.
                    if snapshot.statusMessage == nil, !model.isStale, !snapshot.stats.isEmpty {
                        statStrip(Array(snapshot.stats.prefix(3)))
                    }
                }
                // A frame, not a Spacer: a Spacer would cost two stack gaps of the page's height.
                statusLine.frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// A problem in amber when there is one, and nothing otherwise: only surface a problem, never chrome.
    @ViewBuilder private var statusLine: some View {
        let snapshot = provider
        if let message = snapshot.statusMessage {
            Text(message).font(.system(size: 10))
                .foregroundStyle(Self.amber)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1).truncationMode(.tail)
        } else if model.isStale {
            Text("reconnecting…").font(.system(size: 10))
                .foregroundStyle(Self.amber)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Up to three figures in one quiet card: label over value, the value's note beneath.
    private func statStrip(_ stats: [UsageStatMetric]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1).padding(.vertical, 2)
                        .padding(.horizontal, 10)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.label).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5))
                    Text(metric.value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(metric.tint.map(color) ?? .white)
                    if let sub = metric.subtitle {
                        Text(sub).font(.system(size: 9)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(model.isStale ? 0.55 : 1)
    }

    // Page 2 — activity, the same for every provider: the week chart (or, without a daily feed,
    // the today/all-time totals) above recent sessions/tasks.
    private var pageLocal: some View {
        let snapshot = provider
        // A bare "today: —" tile is dead weight. When the provider has no today figure but does
        // have a daily feed, show the week total instead — always a real number.
        let showWeek = snapshot.todayCost == nil && snapshot.todayTokens == nil
            && snapshot.weekTokens != nil
        // "peak 501.5M" beats the word "tokens" under the all-time figure, when known.
        let peakDetail = snapshot.stats.first(where: { $0.id == "peak-day" })
            .map { "peak \($0.value)" }
        return VStack(spacing: 8) {
            if providerHasNothingToShow {
                providerPlaceholder
            } else if !snapshot.dailySeries.isEmpty {
                WeekActivityChart(series: snapshot.dailySeries, title: snapshot.chartTitle,
                                  currency: snapshot.currency)
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
        if let cost { return Fmt.money(cost, currency: provider.currency) }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(hasAlternate
            ? "Switches to \(showingAlternate ? snapshot.sessionsTitle : (snapshot.alternateSessionsTitle ?? ""))"
            : "")
        .accessibilityAddTraits(hasAlternate ? .isButton : [])
        .help(hasAlternate ? "Click to switch session views" : "Recent provider activity")
    }

    private func sessionRow(_ project: String, cost: Double?, tokens: Int?, last: Date?,
                            muted: Bool) -> some View {
        HStack(spacing: 6) {
            Text(project).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(muted ? 0.5 : 0.85)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let cost, let tokens {
                (Text(Fmt.money(cost, currency: provider.currency)).foregroundStyle(.white)
                    + Text("  ·  \(Fmt.tokens(tokens))").foregroundStyle(.white.opacity(0.45)))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else if let tokens {
                Text(Fmt.tokens(tokens)).foregroundStyle(.white)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            } else if let cost {
                Text(Fmt.money(cost, currency: provider.currency)).foregroundStyle(.white)
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

    enum TileHeight { case compact, tall
        var minHeight: CGFloat { self == .compact ? 54 : 54 }   // page-1 tiles are uniform, compact
        var valueSize: CGFloat { self == .compact ? 15 : 17 }
    }

    // A plain value tile, with an optional muted subline (e.g. a projection).
    private func tile(_ label: String, _ value: String, height: TileHeight, sub: String? = nil,
                      tint: UsageTint? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(value).font(.system(size: height.valueSize, weight: .medium)).monospacedDigit()
                .foregroundStyle(tint.map(color) ?? .white).lineLimit(1).minimumScaleFactor(0.7)
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

    /// A state colour: the warn/critical of the limit tiles, and green for a good state, since
    /// white — "fine" for a percent — says nothing next to a status dot.
    private func color(_ tint: UsageTint) -> Color {
        switch tint {
        case .ok: return Color(red: 0.36, green: 0.80, blue: 0.48)
        case .warn: return Color(red: 0.96, green: 0.70, blue: 0.20)
        case .critical: return Color(red: 0.92, green: 0.34, blue: 0.34)
        }
    }
}
