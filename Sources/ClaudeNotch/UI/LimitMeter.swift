import SwiftUI

/// One limit as a meter: label and percent on top, a bar with a tick where an even pace would be,
/// and the reset (plus any note) underneath. Usage past the tick means the limit runs out before
/// it resets, which a bare percent can't say.
struct LimitMeterRow: View {
    let metric: UsageLimitMetric
    /// Replaces "ahead of pace" when the caller knows more (Claude's "~1h 20m to limit").
    var note: String? = nil

    private static let amber = Color(red: 0.96, green: 0.70, blue: 0.20)
    private static let red = Color(red: 0.92, green: 0.34, blue: 0.34)

    var body: some View {
        let used = metric.usedFraction
        let elapsed = metric.elapsedFraction()
        // A 10-point margin so a limit barely past the tick doesn't nag.
        let ahead = used.flatMap { u in elapsed.map { u > $0 + 0.1 } } ?? false
        let warning = note ?? (ahead ? "ahead of pace" : nil)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(used.map(Fmt.pct) ?? "—")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Self.color(used ?? 0))
            }
            bar(used: used, elapsed: elapsed)
                .padding(.top, 5).padding(.bottom, 4)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metric.resetsAt.map { "resets in \(Fmt.until($0))" } ?? "resets —")
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
                if let right = warning ?? metric.subtitle {
                    Text(right).foregroundStyle(warning != nil ? Self.amber : .white.opacity(0.4))
                }
            }
            .font(.system(size: 9.5)).monospacedDigit()
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.label)
        .accessibilityValue(spokenValue(warning: warning))
    }

    private func bar(used: Double?, elapsed: Double?) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = CGFloat(used ?? 0)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(height: 5)
                // Never thinner than its own height, so 1 % still reads as a dot, not a sliver.
                Capsule().fill(Self.color(used ?? 0))
                    .frame(width: fill > 0 ? max(5, w * fill) : 0, height: 5)
                if let elapsed {
                    // A dark notch behind the tick keeps it readable on a white fill too.
                    ZStack {
                        Rectangle().fill(Color(white: 0.07)).frame(width: 3.5, height: 5)
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
    private func spokenValue(warning: String?) -> String {
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
        if let warning { parts.append(warning) }
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
