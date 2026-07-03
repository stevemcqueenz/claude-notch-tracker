import SwiftUI

struct IslandView: View {
    let model: AppModel   // passed-in @Observable — plain property, NOT @State

    var body: some View {
        Group {
            if model.isExpanded {
                ExpandedView(model: model)
                    .onExitCommand { model.isExpanded = false }
            } else {
                CollapsedView(model: model)
                    .background(Color.black)
                    .clipShape(.rect(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.isExpanded)
    }
}
