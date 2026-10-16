import SwiftUI

/// First launch: what MacFresh does, the permissions it needs (checked live
/// with macOS), then straight into the app. Skipping is always possible;
/// everything here can be done later in Settings › Permissions.
struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var page: Page = .welcome
    /// +1 going forward, -1 going back, so pages slide the right way.
    @State private var direction = 1
    @ObservedObject private var permissions = MacTidyPermissions.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Page: Int, CaseIterable {
        case welcome, tour, permissions, ready
    }

    private var palette: SectionPalette {
        switch page {
        case .welcome: return .smartCare
        case .tour: return .apps
        case .permissions: return .protection
        case .ready: return .cleanup
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: direction >= 0 ? 60 : -60).combined(with: .opacity).combined(with: .scale(scale: 0.98)),
            removal: .offset(x: direction >= 0 ? -60 : 60).combined(with: .opacity)
        )
    }

    var body: some View {
        ZStack {
            AmbientBackdrop(palette: palette)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: page)

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 44)
                    .padding(.top, 40)
                    .id(page)
                    .transition(pageTransition)
                bottomBar
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 620, idealHeight: 660)
        .environment(\.themeTint, palette.accent)
        .onAppear {
            FullDiskAccessManager.shared.triggerRegistration()
            permissions.refresh()
            #if DEBUG
            if let raw = UserDefaults.standard.object(forKey: "DebugOnboardingPage") as? String, let index = Int(raw), let debugPage = Page(rawValue: index) {
                page = debugPage
            }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome: WelcomeScene()
        case .tour: TourScene()
        case .permissions: PermissionsScene()
        case .ready: ReadyScene(allSet: permissions.allRequiredGranted)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(page == .welcome ? String(localized: "Skip") : String(localized: "Back")) {
                if page == .welcome { isComplete = true } else { advance(by: -1) }
            }
            .buttonStyle(GlassButtonStyle())

            Spacer()

            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { item in
                    Capsule()
                        .fill(Color.white.opacity(item == page ? 0.9 : 0.25))
                        .frame(width: item == page ? 20 : 6, height: 6)
                }
            }
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: page)

            Spacer()

            if page == .ready {
                Button("Start using MacFresh") { isComplete = true }
                    .buttonStyle(GlassProminentButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(page == .permissions && !permissions.allRequiredGranted ? String(localized: "Later") : String(localized: "Continue")) {
                    advance(by: 1)
                }
                .buttonStyle(GlassProminentButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func advance(by delta: Int) {
        let target = max(0, min(Page.allCases.count - 1, page.rawValue + delta))
        guard target != page.rawValue else { return }
        Haptics.tap()
        direction = delta >= 0 ? 1 : -1
        withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86)) {
            page = Page(rawValue: target) ?? page
        }
    }
}

// MARK: - Scenes

private struct WelcomeScene: View {
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [SectionPalette.smartCare.accent.opacity(0.45), .clear], center: .center, startRadius: 10, endRadius: 150))
                    .frame(width: 300, height: 300)
                    .scaleEffect(breathe ? 1.08 : 0.94)
                    .opacity(breathe ? 1 : 0.7)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            }
            .frame(height: 220)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { breathe = true }
            }
            .staggered(0, baseDelay: 0.08)

            VStack(spacing: 10) {
                Text("Welcome to MacFresh")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                Text("Clean up junk, remove apps completely, keep an eye on privacy and see what's using your disk. Nothing is removed without your approval.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
            .staggered(1, baseDelay: 0.08)
            Spacer(minLength: 0)
        }
    }
}

private struct TourScene: View {
    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let palette: SectionPalette
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private let features = [
        Feature(icon: "desktopcomputer", palette: .smartCare, title: "Smart Care", detail: "One scan for caches, system junk, the Trash and Mail."),
        Feature(icon: "wand.and.stars", palette: .cleanup, title: "Advanced Cleanup", detail: "Large files, app leftovers and apps you no longer open."),
        Feature(icon: "square.grid.2x2.fill", palette: .apps, title: "Applications", detail: "Uninstall completely, manage startup items, update apps."),
        Feature(icon: "hand.raised.fill", palette: .protection, title: "Protection", detail: "App permissions, security checks, Wi-Fi and browser extensions."),
        Feature(icon: "waveform.path.ecg.rectangle.fill", palette: .processes, title: "Processes", detail: "What your open apps use right now, and free memory."),
        Feature(icon: "chart.pie.fill", palette: .spaceLens, title: "Space Lens", detail: "A live map of what fills your disk."),
        Feature(icon: "doc.on.doc.fill", palette: .duplicates, title: "Duplicate Finder", detail: "Identical files, checked byte by byte."),
        Feature(icon: "photo.stack.fill", palette: .photos, title: "Similar Photos", detail: "Near-identical shots grouped side by side."),
    ]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("Everything in one place")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Each area has its own color, so you always know where you are.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .staggered(0, baseDelay: 0.05)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                    HStack(alignment: .center, spacing: 12) {
                        CategoryBadge(systemName: feature.icon, tint: feature.palette.primary.mixedWithWhite(0.12), size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(feature.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(GlassPanelBackground(cornerRadius: 14))
                    .pressable(hoverScale: 1.015)
                    .staggered(index + 1, baseDelay: 0.04)
                }
            }
            .frame(maxWidth: 680)
            Spacer(minLength: 0)
        }
    }
}

private struct PermissionsScene: View {
    var body: some View {
        VStack {
            PermissionsChecklist()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ReadyScene: View {
    let allSet: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            GlassOrbIcon(systemImage: allSet ? "checkmark" : "hand.wave.fill", tint: allSet ? Tint.green : Tint.orange, size: 110)
                .scaleEffect(shown || reduceMotion ? 1 : 0.6)
                .opacity(shown || reduceMotion ? 1 : 0)
                .onAppear {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.6)) { shown = true }
                    Haptics.success()
                }
            VStack(spacing: 10) {
                Text(LocalizedStringKey(allSet ? "Ready to go" : "Ready when you are"))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(LocalizedStringKey(allSet
                     ? "Start with Smart Care: one scan, and you choose what goes."
                     : "Some areas will show less until Full Disk Access is on. You can allow it any time in Settings › Permissions."))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .staggered(1, baseDelay: 0.08)
            Spacer(minLength: 0)
        }
    }
}
