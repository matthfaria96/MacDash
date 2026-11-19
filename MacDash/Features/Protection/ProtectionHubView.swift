import SwiftUI

/// The four Protection tabs.
enum ProtectionTab: String, CaseIterable, Identifiable {
    case permissions
    case security
    case wifi
    case extensions

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .security: return "Security"
        case .permissions: return "Permissions"
        case .extensions: return "Extensions"
        case .wifi: return "Wi-Fi"
        }
    }

    var icon: String {
        switch self {
        case .security: return "checkmark.shield"
        case .permissions: return "hand.raised"
        case .extensions: return "puzzlepiece.extension"
        case .wifi: return "wifi"
        }
    }
}

/// Protection hub: macOS safeguards, app permissions, browser extensions and
/// saved Wi-Fi networks — one screen, four tabs.
struct ProtectionHubView: View {
    @EnvironmentObject var appState: AppState
    /// Kept here so switching tabs never throws away a result.
    @StateObject private var audit = ProtectionAuditModel()
    @StateObject private var permissions = AppPermissionsModel()
    @StateObject private var extensions = BrowserExtensionsModel()
    @ObservedObject private var wifi = SavedWiFiModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let palette = SectionPalette.protection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubHeader(
                title: "Protection",
                subtitle: "Safeguards, app permissions, browser extensions and Wi-Fi networks.",
                icon: "hand.raised.fill",
                tint: palette.accent
            ) {
                PillTabBar(
                    tabs: ProtectionTab.allCases,
                    selection: $appState.protectionTab,
                    title: { $0.title },
                    icon: { $0.icon },
                    badge: { count(for: $0).map(String.init) }
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 14)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(appState.protectionTab)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appState.protectionTab)
        .task { audit.runIfNeeded() }
    }

    private func count(for tab: ProtectionTab) -> Int? {
        switch tab {
        case .security:
            return audit.attentionCount.flatMap { $0 > 0 ? $0 : nil }
        case .permissions:
            if case .loaded(let apps) = permissions.state { return apps.count }
            return nil
        case .extensions:
            if case .loaded(let scan) = extensions.state { return scan.records.count }
            return nil
        case .wifi:
            if case .loaded(let listing) = wifi.state, listing.hasWiFi { return listing.networks.count }
            return nil
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch appState.protectionTab {
        case .security:
            ProtectionView(model: audit)
        case .permissions:
            AppPermissionsView(model: permissions)
        case .extensions:
            BrowserExtensionsView(model: extensions)
        case .wifi:
            SavedWiFiView(model: wifi)
        }
    }
}

/// Compact header at the top of each Protection tab: what the tab covers,
/// plus its run controls.
struct ProtectionTabHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    var tint: Color = SectionPalette.protection.accent
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            PremiumIcon(systemName: icon, tint: tint, size: 46, style: .glass)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            accessory
        }
        .padding(18)
        .background(GlassPanelBackground(cornerRadius: 20))
    }
}

/// Scrolling page shared by the Protection tabs.
struct ProtectionTabPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A centered card for loading, empty and blocked states.
struct ProtectionStateCard<Actions: View>: View {
    let icon: String
    var tint: Color = SectionPalette.protection.accent
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var isLoading = false
    @ViewBuilder var actions: Actions

    var body: some View {
        CardSurface(padding: 28, elevation: .standard) {
            VStack(spacing: 14) {
                if isLoading {
                    ProgressView()
                        .controlSize(.regular)
                        .frame(height: 69)
                } else {
                    GlassOrbIcon(systemImage: icon, tint: tint, size: 69)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

extension ProtectionStateCard where Actions == EmptyView {
    init(icon: String, tint: Color = SectionPalette.protection.accent, title: LocalizedStringKey, message: LocalizedStringKey, isLoading: Bool = false) {
        self.init(icon: icon, tint: tint, title: title, message: message, isLoading: isLoading) { EmptyView() }
    }
}

/// A one-line footnote under a Protection list.
struct ProtectionFootnote: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}
