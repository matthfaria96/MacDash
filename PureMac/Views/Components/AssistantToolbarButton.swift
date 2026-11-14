import SwiftUI

/// The toolbar button that opens the Assistant screen.
struct AssistantToolbarButton: View {
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: AssistantView.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text("Assistant")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
        }
        .help("Find what is using space and what is worth cleaning.")
        .accessibilityLabel("Assistant")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
