import AppKit
import SwiftUI

@MainActor
final class AppPermissionsModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded([PermissionApp])
        case needsFullDiskAccess
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheckedAt: Date?

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    func loadIfNeeded() {
        if case .idle = state { load() }
    }

    func load() {
        guard !isLoading else { return }
        state = .loading
        Task {
            let result = await Task.detached(priority: .userInitiated) { AppPermissionsReader.read() }.value
            switch result {
            case .loaded(let apps):
                state = .loaded(apps)
            case .needsFullDiskAccess:
                state = .needsFullDiskAccess
            }
            lastCheckedAt = Date()
        }
    }
}

/// Protection › Permissions: which apps hold which privacy permissions,
/// app by app — the overview System Settings doesn't offer.
struct AppPermissionsView: View {
    @ObservedObject var model: AppPermissionsModel

    var body: some View {
        ProtectionTabPage {
            ProtectionTabHeader(
                title: "App Permissions",
                subtitle: "Which apps can read your files, see your screen, use the camera and microphone, or control other apps.",
                icon: "person.badge.key.fill"
            ) {
                if let date = model.lastCheckedAt, !model.isLoading {
                    LastCheckedLabel(date: date)
                }
            }
            content
        }
        .task { model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProtectionStateCard(
                icon: "hand.raised",
                title: "Reading permissions",
                message: "Looking at what macOS has allowed each app to do.",
                isLoading: true
            )
        case .needsFullDiskAccess:
            ProtectionStateCard(
                icon: "lock.shield",
                tint: Tint.orange,
                title: "Full Disk Access needed",
                message: "macOS keeps its permission list in a protected database. Give MacFresh Full Disk Access, then check again."
            ) {
                HStack(spacing: 10) {
                    Button("Open Full Disk Access") {
                        NSWorkspace.shared.open(PrivacyPermission.fullDiskAccess.settingsURL)
                    }
                    .buttonStyle(GlassProminentButtonStyle(large: true))
                    Button("Check Again") { model.load() }
                        .buttonStyle(GlassButtonStyle())
                        .controlSize(.large)
                }
            }
        case .loaded(let apps):
            ForEach(Self.groups(apps)) { group in
                PermissionGroupCard(group: group)
            }
            ProtectionFootnote(
                icon: "info.circle",
                text: "macOS doesn't let other apps change these permissions. Turn one off in System Settings › Privacy & Security; the app asks again the next time it needs it."
            )
        }
    }

    // MARK: Groups

    /// Apps that hold exactly the same permissions, so each set's tags and
    /// actions appear once. Powerful sets come first, then larger ones.
    static func groups(_ apps: [PermissionApp]) -> [PermissionGroup] {
        let grouped = Dictionary(grouping: apps) { $0.permissions }
        return grouped.map { permissions, members in
            PermissionGroup(
                permissions: permissions,
                apps: members.sorted {
                    if $0.isApplication != $1.isApplication { return $0.isApplication }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            )
        }
        .sorted {
            let lhs = $0.permissions.filter(\.isSensitive).count, rhs = $1.permissions.filter(\.isSensitive).count
            if lhs != rhs { return lhs > rhs }
            if $0.permissions.count != $1.permissions.count { return $0.permissions.count > $1.permissions.count }
            if $0.apps.count != $1.apps.count { return $0.apps.count > $1.apps.count }
            return $0.id < $1.id
        }
    }
}

struct PermissionGroup: Identifiable {
    let permissions: [PrivacyPermission]
    let apps: [PermissionApp]
    var id: String { permissions.map(\.rawValue).joined(separator: "+") }
}

/// One set of permissions: its tags and the System Settings action once in
/// the header, then the apps holding it in two columns.
private struct PermissionGroupCard: View {
    let group: PermissionGroup

    var body: some View {
        CardSurface(padding: 16, elevation: .standard, tint: group.permissions.contains(where: \.isSensitive) ? Tint.orange : nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        TagFlow(spacing: 6) {
                            ForEach(group.permissions) { PermissionTag(permission: $0) }
                        }
                        Text(verbatim: summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(group.apps.count == 1 ? "1 app" : "\(group.apps.count) apps")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                    settingsButton
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(group.apps) { app in
                        PermissionAppTile(app: app)
                    }
                }
            }
        }
    }

    /// What the set allows, in one line: the permission's own sentence when
    /// there's one, otherwise the names together.
    private var summary: String {
        if group.permissions.count == 1 { return group.permissions[0].detail }
        return group.permissions.map(\.detail).joined(separator: " ")
    }

    @ViewBuilder
    private var settingsButton: some View {
        if group.permissions.count == 1 {
            Button {
                NSWorkspace.shared.open(group.permissions[0].settingsURL)
            } label: {
                Label("Manage", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(GlassButtonStyle())
            .help("Open the matching pane in System Settings")
        } else {
            Menu {
                ForEach(group.permissions) { permission in
                    Button(permission.title) { NSWorkspace.shared.open(permission.settingsURL) }
                }
            } label: {
                Label("Manage", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(GlassButtonStyle())
            .fixedSize()
            .help("Open the matching pane in System Settings")
        }
    }
}

/// A permission as a tag: its symbol in a small tinted disc, then its name.
private struct PermissionTag: View {
    let permission: PrivacyPermission

    var body: some View {
        let tint = permission.tagTint
        HStack(spacing: 6) {
            Image(systemName: permission.icon)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(tint.opacity(0.85)))
            Text(verbatim: permission.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.12)], startPoint: .leading, endPoint: .trailing))
        )
        .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 0.7))
        .help(permission.detail)
    }
}

private extension PrivacyPermission {
    /// Warm colors for the powerful permissions, cool ones for the rest.
    var tagTint: Color {
        switch self {
        case .fullDiskAccess: return Tint.red
        case .accessibility: return Tint.orange
        case .screenRecording: return Tint.yellow
        case .camera: return Tint.pink
        case .microphone: return Color(red: 0.75, green: 0.45, blue: 1.0)
        case .automation: return Color(red: 0.35, green: 0.7, blue: 1.0)
        }
    }
}

/// One app in a group: icon, name and what's particular to it. Show in
/// Finder appears on hover.
private struct PermissionAppTile: View {
    let app: PermissionApp
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            appIcon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if let note {
                    Text(verbatim: note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(note)
                }
            }
            Spacer(minLength: 4)
            if let url = app.appURL, hovering {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(hovering ? 0.08 : 0.045)))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// Automation targets, limited access, or what kind of program it is.
    private var note: String? {
        var parts: [String] = []
        if !app.automationTargets.isEmpty {
            parts.append(String(format: String(localized: "Can control: %@"), app.automationTargets.formatted(.list(type: .and))))
        }
        let limited = app.grants.filter(\.isLimited).map(\.permission.title)
        if !limited.isEmpty {
            parts.append(String(format: String(localized: "%@ (limited)"), limited.formatted(.list(type: .and))))
        }
        if app.appURL == nil && !app.clientIsPath {
            // macOS keeps the permission after the app is deleted.
            parts.append(String(localized: "App no longer installed"))
        } else if !app.isApplication {
            parts.append(String(localized: "Command-line tool or background program"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var appIcon: some View {
        if let url = app.appURL {
            Image(nsImage: IconCache.icon(forFile: url.path))
                .resizable()
                .accessibilityHidden(true)
        } else {
            PremiumIcon(systemName: app.clientIsPath ? "terminal.fill" : "app.dashed", tint: Color(red: 0.55, green: 0.6, blue: 0.75), size: 26)
        }
    }
}

/// Lays tags out left to right and wraps them onto new lines.
private struct TagFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// "Last checked" with a relative time, used in tab headers.
struct LastCheckedLabel: View {
    let date: Date

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Last checked")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Text(date, style: .relative)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}
