import AppKit
import SwiftUI

@MainActor
final class BrowserExtensionsModel: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(BrowserExtensionScan)
    }

    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    @Published private(set) var state: State = .idle
    @Published var browserFilter: BrowserKind?
    @Published private(set) var removingID: String?
    @Published var notice: Notice?

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
            let scan = await BrowserExtensionsScanner.scan()
            state = .loaded(scan)
            if let filter = browserFilter, !scan.records.contains(where: { $0.browser == filter }) {
                browserFilter = nil
            }
        }
    }

    func remove(_ record: BrowserExtensionRecord) {
        guard removingID == nil else { return }
        removingID = record.id
        Task {
            let outcome = await BrowserExtensionsScanner.remove(record)
            removingID = nil
            notice = Self.notice(for: outcome, record: record)
            if outcome == .trashed, case .loaded(let scan) = state {
                withAnimation(MotionTokens.gentle) {
                    state = .loaded(BrowserExtensionScan(
                        records: scan.records.filter { $0.id != record.id },
                        installedBrowsers: scan.installedBrowsers
                    ))
                }
            }
        }
    }

    private static func notice(for outcome: BrowserExtensionsScanner.RemovalOutcome, record: BrowserExtensionRecord) -> Notice {
        switch outcome {
        case .trashed:
            return Notice(text: String(format: String(localized: "“%@” was moved to the Trash."), record.name), isError: false)
        case .removeInBrowser(let browser):
            return Notice(
                text: String(format: String(localized: "%@ is open, so nothing was deleted. Remove the extension in %@ from %@, or quit it and try again."), browser.label, browser.label, browser.extensionsMenuPath),
                isError: true
            )
        case .managedByPolicy(let browser):
            return Notice(
                text: String(format: String(localized: "This extension was installed by a management policy, so %@ would reinstall it. If you don't recognize it, look for unknown profiles in System Settings › General › Device Management."), browser.label),
                isError: true
            )
        case .builtIn(let browser):
            return Notice(text: String(format: String(localized: "This extension is built into %@ and can't be removed."), browser.label), isError: true)
        case .openedSafariSettings:
            return Notice(text: String(localized: "Safari extensions come with apps and are managed by macOS. Turn them off in Safari › Settings › Extensions, or uninstall the app that added them."), isError: false)
        case .refused:
            return Notice(text: String(localized: "MacDash couldn't confirm this extension's folder is safe to remove, so nothing was deleted."), isError: true)
        case .failed(let message):
            return Notice(text: String(format: String(localized: "Couldn't move it to the Trash: %@"), message), isError: true)
        }
    }
}

/// Protection › Extensions: extensions installed in Safari, Chrome, Brave,
/// Edge, Arc and Firefox, with adware-looking names flagged.
struct BrowserExtensionsView: View {
    @ObservedObject var model: BrowserExtensionsModel
    @State private var pendingRemoval: BrowserExtensionRecord?

    var body: some View {
        ProtectionTabPage {
            ProtectionTabHeader(
                title: "Browser Extensions",
                subtitle: "Extensions in Safari, Chrome, Brave, Edge, Arc and Firefox. Names that match known adware are marked Suspicious.",
                icon: "puzzlepiece.extension.fill"
            ) {
                EmptyView()
            }
            if let notice = model.notice {
                NoticeBanner(text: notice.text, isError: notice.isError) { model.notice = nil }
            }
            content
        }
        .task { model.loadIfNeeded() }
        .alert(
            pendingRemoval.map { String(format: String(localized: "Move “%@” to the Trash?"), $0.name) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { record in
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.remove(record) }
        } message: { record in
            Text(String(format: String(localized: "If %@ is closed, the extension's folder moves to the Trash. If it's open, nothing is deleted and %@ opens so you can remove it there. Browser sync may install it again."), record.browser.label, record.browser.label))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProtectionStateCard(
                icon: "puzzlepiece.extension",
                title: "Looking for extensions",
                message: "Reading the extensions folder of each browser profile.",
                isLoading: true
            )
        case .loaded(let scan):
            if scan.records.isEmpty {
                ProtectionStateCard(
                    icon: "checkmark.seal",
                    tint: Tint.green,
                    title: "No extensions found",
                    message: "Nothing is installed in Safari, Chrome, Brave, Edge, Arc or Firefox."
                )
            } else {
                summary(scan)
                filterBar(scan)
                list(scan)
                ProtectionFootnote(
                    icon: "info.circle",
                    text: "Remove moves the extension's folder to the Trash only while its browser is closed. Extensions added by a management profile or built into the browser can't be removed here."
                )
            }
        }
    }

    // MARK: Summary and filters

    /// Only speaks up when something looks wrong; "all clear" needs no card.
    @ViewBuilder
    private func summary(_ scan: BrowserExtensionScan) -> some View {
        let suspicious = scan.records.filter(\.isSuspicious).count
        if suspicious > 0 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tint.red)
                Text(String(format: String(localized: "%lld suspicious extensions"), Int64(suspicious)))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(GlassPanelBackground(cornerRadius: 12))
        }
    }

    private func filterBar(_ scan: BrowserExtensionScan) -> some View {
        let browsers = BrowserKind.allCases.filter { browser in scan.records.contains { $0.browser == browser } }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterCapsule(title: String(localized: "All"), count: scan.records.count, icon: nil, isSelected: model.browserFilter == nil) {
                    model.browserFilter = nil
                }
                ForEach(browsers) { browser in
                    FilterCapsule(
                        title: browser.label,
                        count: scan.records.filter { $0.browser == browser }.count,
                        icon: BrowserIcon.image(for: browser),
                        isSelected: model.browserFilter == browser
                    ) {
                        model.browserFilter = browser
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: List

    @ViewBuilder
    private func list(_ scan: BrowserExtensionScan) -> some View {
        let visible = model.browserFilter.map { filter in scan.records.filter { $0.browser == filter } } ?? scan.records
        CardSurface(padding: 0, elevation: .standard) {
            LazyVStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, record in
                    ExtensionRow(
                        record: record,
                        isRemoving: model.removingID == record.id,
                        onRemove: { pendingRemoval = record },
                        onSafari: { model.remove(record) }
                    )
                    if index < visible.count - 1 {
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
    }
}

private enum BrowserIcon {
    @MainActor private static var paths: [BrowserKind: String?] = [:]

    /// The browser's own icon; the app lookup happens once per browser.
    @MainActor
    static func image(for browser: BrowserKind) -> NSImage? {
        if paths[browser] == nil {
            paths[browser] = .some(NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.primaryBundleIdentifier)?.path)
        }
        guard let path = paths[browser] ?? nil else { return nil }
        return IconCache.icon(forFile: path)
    }
}

private struct FilterCapsule: View {
    let title: String
    let count: Int
    let icon: NSImage?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(isSelected ? Color.black.opacity(0.12) : Color.white.opacity(0.12)))
            }
            .foregroundStyle(isSelected ? Color.black.opacity(0.82) : Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(isSelected ? AnyShapeStyle(Color.white.opacity(0.92)) : AnyShapeStyle(Color.white.opacity(hovering ? 0.12 : 0.06)))
            }
            .overlay(Capsule().strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ExtensionRow: View {
    let record: BrowserExtensionRecord
    let isRemoving: Bool
    let onRemove: () -> Void
    let onSafari: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = BrowserIcon.image(for: record.browser) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    if record.isSuspicious {
                        StatusChip(label: String(localized: "Suspicious"), systemImage: "exclamationmark.triangle.fill", tint: Tint.red)
                            .help("The name matches a known adware family. This is a hint, not a confirmed detection.")
                    }
                    switch record.origin {
                    case .policy:
                        StatusChip(label: String(localized: "Managed"), systemImage: "lock.fill", tint: Tint.orange)
                    case .component:
                        StatusChip(label: String(localized: "Built in"), systemImage: "shippingbox.fill", tint: Tint.blue)
                    case .user, .safariApp:
                        EmptyView()
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(GlassIconButtonStyle())
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")

            action
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var action: some View {
        if isRemoving {
            ProgressView().controlSize(.small)
        } else {
            switch record.origin {
            case .user:
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(GlassButtonStyle())
            case .safariApp:
                Button("Manage", action: onSafari)
                    .buttonStyle(GlassButtonStyle())
                    .help("Safari extensions are turned off in Safari › Settings › Extensions")
            case .policy, .component:
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
                    .help(record.origin == .policy
                          ? "Installed by a management profile; the browser would reinstall it."
                          : "Built into the browser; it can't be removed.")
            }
        }
    }

    private var subtitle: String {
        var parts = [record.browser.label]
        if !record.profile.isEmpty { parts.append(record.profile) }
        if let date = record.updatedAt {
            parts.append(String(format: String(localized: "Updated %@"), date.formatted(date: .abbreviated, time: .omitted)))
        }
        return parts.joined(separator: " · ")
    }
}
