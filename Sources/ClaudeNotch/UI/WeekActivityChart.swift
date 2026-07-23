import SwiftUI

/// Seven-day account-activity bar chart for the limits page: one bar per calendar day, today
/// highlighted, the peak day labeled with its count, and the week total in the header. Fills
/// whatever height the page gives it, so it works as the page's centerpiece tile.
struct WeekActivityChart: View {
    let series: [DailyUsagePoint]   // oldest first, today last
    var title = "last 7 days"

    /// Dollar mode when any point carries a cost (Claude's local logs); token mode otherwise.
    private var usesCost: Bool { series.contains { ($0.cost ?? 0) > 0 } }
    private func value(_ point: DailyUsagePoint) -> Double {
        usesCost ? (point.cost ?? 0) : Double(point.tokens)
    }
    private func label(_ value: Double) -> String {
        usesCost ? Fmt.usd(value) : Fmt.tokens(Int(value))
    }
    private var total: Double { series.reduce(0) { $0 + value($1) } }
    private var maxValue: Double { series.map(value).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if total > 0 {
                    Text(label(total)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if maxValue == 0 {
                Spacer(minLength: 0)
                Text("no activity this week")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(series) { point in
                            bar(point, available: geo.size.height)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                }
            }
            HStack(spacing: 6) {
                ForEach(series) { point in
                    Text(dayLetter(point.date))
                        .font(.system(size: 8.5, weight: isToday(point.date) ? .bold : .regular))
                        .foregroundStyle(.white.opacity(isToday(point.date) ? 0.85 : 0.4))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func bar(_ point: DailyUsagePoint, available: CGFloat) -> some View {
        let v = value(point)
        let fraction = maxValue > 0 ? v / maxValue : 0
        let isPeak = v == maxValue && v > 0
        // ~12pt stays reserved for the peak label so the tallest bar never collides with it.
        let barHeight = max(3, (available - 14) * fraction)
        return VStack(spacing: 2) {
            Spacer(minLength: 0)
            if isPeak {
                Text(label(v))
                    .font(.system(size: 8.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1).fixedSize()
            }
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.white.opacity(v == 0 ? 0.12 : (isToday(point.date) ? 0.9 : 0.4)))
                .frame(height: barHeight)
        }
        .frame(maxWidth: .infinity)
    }

    private func isToday(_ date: Date) -> Bool { Calendar.current.isDateInToday(date) }

    private func dayLetter(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"   // narrow weekday, e.g. "M"
        return f.string(from: date)
    }
}
