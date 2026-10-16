import SwiftUI

struct EmptyStateView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: LocalizedStringKey
    var action: (() -> Void)?
    var actionLabel: LocalizedStringKey?
    /// Halo/icon tint — positive states pass a color (e.g. green for "All
    /// Clean"); neutral states keep the secondary look.
    var tint: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: LocalizedStringKey, systemImage: String, description: LocalizedStringKey,
         action: (() -> Void)? = nil, actionLabel: LocalizedStringKey? = nil, tint: Color? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.action = action
        self.actionLabel = actionLabel
        self.tint = tint
    }

    /// Neutral states get a calm periwinkle icon instead of a gray one.
    private var iconTint: Color { tint ?? Color(red: 0.52, green: 0.58, blue: 1.0) }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            PremiumHeroIcon(systemName: systemImage, tint: iconTint, size: 110)

            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .staggered(0, baseDelay: 0.08)
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .staggered(1, baseDelay: 0.08)
            if let action, let label = actionLabel {
                Button(action: action) { Text(label) }
                    .buttonStyle(GlassProminentButtonStyle(large: true))
                    .tint(tint)
                    .padding(.top, 6)
                    .staggered(2, baseDelay: 0.08)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
