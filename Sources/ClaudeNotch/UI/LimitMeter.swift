import SwiftUI

/// One limit as a meter row: label, reset countdown and percent on one line, a thin bar below
/// with a tick where an even pace would be. Usage past the tick means the limit runs out before
/// it resets, which a bare percent can't say.
struct LimitMeterRow: View {
    let metric: UsageLimitMetric

    private static let amber = Color(red: 0.96, green: 0.70, blue: 0.20)
    private static let red = Color(red: 0.92, green: 0.34, blue: 0.34)

    var body: some View {
        let used = metric.usedFraction
        let elapsed = metric.elapsedFraction()
        // A 10-point margin so a limit barely past the tick doesn't nag.
        let ahead = used.flatMap { u in elapsed.map { u > $0 + 0.1 } } ?? false
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(detail(ahead: ahead))
                    .font(.system(size: 9.5)).monospacedDigit()
                    .foregroundStyle(ahead ? Self.amber : .white.opacity(0.4))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(used.map(Fmt.pct) ?? "—")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Self.color(used ?? 0))
                    .layoutPriority(2)
            }
            bar(used: used, elapsed: elapsed)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.label)
        .accessibilityValue(spokenValue(ahead: ahead))
    }

    /// The muted half of the line: the absolute spend when known (opencode-go), then the reset.
    private func detail(ahead: Bool) -> String {
        let reset = metric.resetsAt.map { "resets in \(Fmt.until($0))" } ?? "resets —"
        return ([ahead ? "ahead of pace" : nil, metric.subtitle, reset] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func bar(used: Double?, elapsed: Double?) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = CGFloat(used ?? 0)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(height: 4)
                // Never thinner than its own height, so 1 % still reads as a dot, not a sliver.
                Capsule().fill(Self.color(used ?? 0))
                    .frame(width: fill > 0 ? max(4, w * fill) : 0, height: 4)
                if let elapsed {
                    // A black notch behind the tick keeps it readable on a white fill too.
                    ZStack {
                        Rectangle().fill(.black).frame(width: 3.5, height: 4)
                        Capsule().fill(.white.opacity(0.55)).frame(width: 1.5, height: 9)
                    }
                    .offset(x: min(max(0, w * CGFloat(elapsed) - 1.75), w - 3.5))
                }
            }
            .frame(width: w, height: geo.size.height)
            .animation(.easeInOut(duration: 0.5), value: used)
        }
        .frame(height: 9)
    }

    /// "42 percent used, resets in 2 hours, 18 minutes, ahead of pace".
    private func spokenValue(ahead: Bool) -> String {
        var parts = [metric.usedFraction.map { "\(Int(($0 * 100).rounded())) percent used" }
                     ?? "unknown"]
        if let subtitle = metric.subtitle { parts.append(subtitle) }
        if let resetsAt = metric.resetsAt {
            let f = DateComponentsFormatter()
            f.unitsStyle = .full
            f.allowedUnits = [.day, .hour, .minute]
            f.maximumUnitCount = 2
            if let s = f.string(from: max(0, resetsAt.timeIntervalSinceNow)) {
                parts.append("resets in \(s)")
            }
        }
        if ahead { parts.append("ahead of pace") }
        return parts.joined(separator: ", ")
    }

    /// White while fine: colour is saved for the two states that need attention.
    static func color(_ used: Double) -> Color {
        switch ringState(for: used) {
        case .ok: return .white
        case .warn: return amber
        case .critical: return red
        }
    }
}
