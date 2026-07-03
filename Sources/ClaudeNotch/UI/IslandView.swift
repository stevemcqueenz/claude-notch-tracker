import SwiftUI

struct IslandView: View {
    let model: AppModel   // passed-in @Observable — plain property, NOT @State
    let width: CGFloat

    var body: some View {
        Group {
            if model.isExpanded {
                ExpandedView(model: model)
            } else {
                CollapsedView(model: model)
            }
        }
        .frame(width: width)                 // constant width: only height changes
        .background(Color.black)
        .clipShape(.rect(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.isExpanded)
    }
}
