import SwiftUI
import AppKit

/// Expanded island = the same pill row at the notch, with a detail card dropping
/// down BELOW it. Same width as collapsed; only the height grows.
struct ExpandedView: View {
    let model: AppModel   // passed-in @Observable — plain property, NOT @State

    var body: some View {
        VStack(spacing: 0) {
            IslandTopRow(model: model)   // stays at the notch line
            DetailCard(model: model)     // sits below the notch
        }
    }
}

private struct DetailCard: View {
    let model: AppModel

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.blockRemaining.map { Fmt.hm($0) + " left in 5-hour block" }
                     ?? "No active block")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Spacer()
                if let end = s.blockEnd {
                    Text("resets \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }

            if s.isEmpty {
                Text("No usage yet — start a Claude session")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                    metric("tokens today", Fmt.tokens(s.tokensToday))
                    metric("est. cost today", Fmt.usd(s.costToday))
                    metric("active session", Fmt.tokens(s.activeSessionTokens))
                    metric("top model", s.topModel ?? "—")
                }
            }

            HStack(spacing: 8) {
                pill("Settings") { NotificationCenter.default.post(name: .openSettings, object: nil) }
                pill("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 16, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}
