import SwiftUI

/// The first-run permissions screen: progress at the top, the one required
/// permission as a featured card with its steps, then the optional ones in
/// two columns. Every status is read live from macOS, and a card turns
/// green the moment its permission is on.
struct PermissionsChecklist: View {
    @ObservedObject private var permissions = MacTidyPermissions.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let required = MacTidyPermissions.Item.allCases.filter(\.isRequired)
    private let optional = MacTidyPermissions.Item.allCases.filter { !$0.isRequired }

    var body: some View {
        VStack(spacing: 18) {
            header
                .staggered(0, baseDelay: 0.05)

            ForEach(required) { item in
                RequiredPermissionCard(item: item, status: permissions.status(item), isRequesting: permissions.requesting == item) {
                    permissions.request(item)
                }
                .staggered(1, baseDelay: 0.05)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Optional")
                        .font(.system(size: 11, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Each one turns on one more feature. Skip any of them.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.horizontal, 4)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Array(optional.enumerated()), id: \.element) { index, item in
                        OptionalPermissionCard(item: item, status: permissions.status(item), isRequesting: permissions.requesting == item) {
                            permissions.request(item)
                        }
                        .staggered(index + 2, baseDelay: 0.05)
                    }
                }
            }
        }
        .frame(maxWidth: 720)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: permissions.statuses)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private var header: some View {
        let total = MacTidyPermissions.Item.allCases.count
        let granted = permissions.grantedCount
        let tint = permissions.allRequiredGranted ? Tint.green : Tint.orange
        return HStack(spacing: 18) {
            ZStack {
                Circle().fill(RadialGradient(colors: [tint.opacity(0.25), tint.opacity(0.03)], center: .center, startRadius: 2, endRadius: 40))
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(granted) / CGFloat(max(total, 1)))
                    .stroke(
                        AngularGradient(colors: [tint.opacity(0.5), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.6), radius: 6)
                VStack(spacing: -2) {
                    Text(verbatim: "\(granted)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .numericTransition()
                    Text(verbatim: "/\(total)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white)
            }
            .frame(width: 66, height: 66)
            .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8), value: granted)

            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(permissions.allRequiredGranted ? "You're all set" : "Allow what MacDash needs"))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
                Text("Each line is checked with macOS as you go. You can change any of this later in Settings › Permissions.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Cards

/// The required permission: larger, with the two steps it takes, and the
/// main button until macOS reports it on.
private struct RequiredPermissionCard: View {
    let item: MacTidyPermissions.Item
    let status: MacTidyPermissions.Status
    let isRequesting: Bool
    let action: () -> Void

    private var granted: Bool { status == .granted }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let tint = granted ? Tint.green : Tint.orange
        HStack(alignment: .center, spacing: 16) {
            CategoryBadge(systemName: item.icon, tint: tint, size: 50)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    PermissionPill(text: String(localized: "Required"), tint: tint)
                }
                Text(item.purpose)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    HStack(spacing: 14) {
                        step(1, String(localized: "Open System Settings"))
                        step(2, String(localized: "Turn on MacDash in the list"))
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                }
            }
            Spacer(minLength: 8)
            Group {
                if granted {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Tint.green)
                            .shadow(color: Tint.green.opacity(0.6), radius: 8)
                        Text("Allowed")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Tint.green)
                    }
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else if status == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: action) {
                        Label("Open Settings", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(GlassProminentButtonStyle(large: true))
                    .transition(.opacity)
                }
            }
            .frame(minWidth: 120)
        }
        .padding(18)
        .background {
            shape.fill(Color.white.opacity(0.06))
            shape.fill(LinearGradient(colors: [tint.opacity(granted ? 0.2 : 0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(shape.strokeBorder(tint.opacity(granted ? 0.55 : 0.4), lineWidth: 1))
        .shadow(color: tint.opacity(0.18), radius: 18, y: 6)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(0.85)))
            Text(verbatim: text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// An optional permission: what it turns on, and one small action. Turns
/// green, with a check, when macOS reports it on.
private struct OptionalPermissionCard: View {
    let item: MacTidyPermissions.Item
    let status: MacTidyPermissions.Status
    let isRequesting: Bool
    let action: () -> Void
    @State private var hovering = false

    private var granted: Bool { status == .granted }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        // The action shares the title's line, so the explanation keeps the
        // card's full width.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                CategoryBadge(systemName: item.icon, tint: granted ? Tint.green : Tint.blue, size: 30)
                    .saturation(granted ? 1 : 0.85)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                trailing
            }
            Text(item.purpose)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(item.purpose)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background {
            shape.fill(Color.white.opacity(hovering ? 0.08 : 0.055))
            if granted {
                shape.fill(LinearGradient(colors: [Tint.green.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay(shape.strokeBorder(granted ? Tint.green.opacity(0.45) : Color.white.opacity(0.08), lineWidth: granted ? 1 : 0.6))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Tint.green)
                .shadow(color: Tint.green.opacity(0.5), radius: 5)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .help("Allowed")
        case .needsFullDiskAccess:
            Text("After Full Disk Access")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.trailing)
                .frame(width: 80, alignment: .trailing)
        case .notAsked, .denied:
            Button(action: action) {
                if isRequesting {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(buttonTitle)
                }
            }
            .buttonStyle(RowActionButtonStyle())
            .fixedSize()
            .disabled(isRequesting)
            .help(status == .denied ? String(localized: "Opens the matching page of System Settings") : "")
            .transition(.opacity)
        }
    }

    private var buttonTitle: String {
        switch (item, status) {
        case (.notifications, .notAsked), (.automation, .notAsked), (.bluetooth, .notAsked), (.location, .notAsked):
            return String(localized: "Allow")
        default:
            return String(localized: "Open Settings")
        }
    }
}

private struct PermissionPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.16)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 0.6))
    }
}
