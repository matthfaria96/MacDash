import AppKit
import SwiftUI

/// The three ways Space Lens shows one scan.
enum SpaceLensTab: String, CaseIterable, Identifiable {
    case treemap, rings, apps

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .treemap: return "Treemap"
        case .rings: return "Rings"
        case .apps: return "Applications"
        }
    }

    var icon: String {
        switch self {
        case .treemap: return "square.grid.3x3.square"
        case .rings: return "circle.circle"
        case .apps: return "square.stack.3d.up.fill"
        }
    }
}

/// Keeps a Space Lens scan, the folder being viewed and the selection while
/// the user visits other screens.
@MainActor
final class SpaceLensModel: ObservableObject {
    static let shared = SpaceLensModel()

    enum Phase {
        case idle
        case scanning
        case results
    }

    /// Something picked for the Trash, with the folders above it so sizes can
    /// be corrected after it's gone.
    struct Pick {
        let node: SpaceNode
        let url: URL
        let ancestors: [SpaceNode]
    }

    @Published var location: ScanLocation = .startupDisk
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = SpaceLensProgress()
    /// The map as it forms during the scan.
    @Published private(set) var partial: SpaceLensPartial?
    @Published private(set) var path: [SpaceNode] = []
    @Published private(set) var rootURL: URL?
    @Published private(set) var picks: [ObjectIdentifier: Pick] = [:]
    @Published var hovered: SpaceNode?
    @Published private(set) var isTrashing = false
    @Published var notice: (text: String, isError: Bool)?
    @Published var tab: SpaceLensTab = .treemap
    /// Capacity and free space, when the scan covered a whole volume.
    @Published private(set) var volume: (total: Int64, free: Int64)?

    var volumeFree: Int64? { volume?.free }

    enum AppsState {
        case idle
        case loading(done: Int, total: Int, name: String)
        case loaded([AppFootprint])
    }

    @Published private(set) var apps: AppsState = .idle

    private var task: Task<Void, Never>?
    private var appsTask: Task<Void, Never>?

    var current: SpaceNode? { path.last }
    var root: SpaceNode? { path.first }

    var currentURL: URL? {
        guard let rootURL, path.allSatisfy(\.isOnDisk) else { return nil }
        return path.dropFirst().reduce(rootURL) { $0.appendingPathComponent($1.name) }
    }

    func url(of child: SpaceNode) -> URL? {
        guard child.isOnDisk else { return nil }
        return currentURL?.appendingPathComponent(child.name)
    }

    /// The scanned node at `url`, with the folders leading to it.
    func nodes(at url: URL) -> [SpaceNode]? {
        guard let root, let rootURL else { return nil }
        return Self.nodes(at: url.path, root: root, rootPath: rootURL.path)
    }

    nonisolated static func nodes(at path: String, root: SpaceNode, rootPath: String) -> [SpaceNode]? {
        let base = (rootPath as NSString).standardizingPath
        let target = (path as NSString).standardizingPath
        let relative: String
        if target == base {
            relative = ""
        } else if base == "/" {
            relative = String(target.dropFirst())
        } else if target.hasPrefix(base + "/") {
            relative = String(target.dropFirst(base.count + 1))
        } else {
            return nil
        }
        var chain = [root]
        for component in relative.split(separator: "/") where !component.isEmpty {
            guard let next = chain.last?.children.first(where: { $0.name == component && $0.isOnDisk }) else { return nil }
            chain.append(next)
        }
        return chain
    }

    /// Opens the folder holding `url` in the treemap with the item highlighted.
    func showInTreemap(_ url: URL) {
        guard let chain = nodes(at: url), chain.count > 1 else { return }
        let target = chain.last!
        withAnimation(MotionTokens.snappy) {
            path = target.canOpen ? chain : Array(chain.dropLast())
            tab = .treemap
        }
        hovered = target.canOpen ? nil : target
    }

    var selectedSize: Int64 { picks.values.reduce(0) { $0 + $1.node.size } }

    // MARK: Scan

    func start() {
        guard phase != .scanning else { return }
        let root = location.url
        phase = .scanning
        progress = SpaceLensProgress()
        partial = nil
        picks = [:]
        notice = nil
        appsTask?.cancel()
        apps = .idle
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                await SpaceLensScanner.scan(root: root, onProgress: { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.phase == .scanning else { return }
                        self.progress = update
                    }
                }, onPartial: { partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.phase == .scanning else { return }
                        self.partial = partial
                    }
                })
            }.value
            guard let self, !Task.isCancelled, self.phase == .scanning else { return }
            guard let result else {
                self.phase = .idle
                return
            }
            self.rootURL = root
            self.path = [result.root]
            self.volume = result.volume
            UsageStats.shared.recordScan(.spaceLens, filesChecked: self.progress.items)
            withAnimation(MotionTokens.gentle) { self.phase = .results }
            self.loadApps()
        }
    }

    /// Works out each app's footprint, reusing the sizes this scan measured.
    func loadApps() {
        appsTask?.cancel()
        let tree = root
        let treePath = rootURL?.path ?? "/"
        apps = .loading(done: 0, total: 0, name: "")
        appsTask = Task { [weak self] in
            let list = await Task.detached(priority: .utility) {
                AppFootprintScanner.scan(knownSize: { path in
                    guard let tree else { return nil }
                    return Self.nodes(at: path, root: tree, rootPath: treePath)?.last?.size
                }, onProgress: { done, total, name in
                    Task { @MainActor [weak self] in
                        guard let self, case .loading = self.apps else { return }
                        self.apps = .loading(done: done, total: total, name: name)
                    }
                })
            }.value
            guard let self, !Task.isCancelled else { return }
            withAnimation(MotionTokens.gentle) { self.apps = .loaded(list) }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        appsTask?.cancel()
        withAnimation(MotionTokens.gentle) { phase = .idle }
    }

    func startOver() {
        task?.cancel()
        task = nil
        appsTask?.cancel()
        apps = .idle
        volume = nil
        path = []
        rootURL = nil
        picks = [:]
        hovered = nil
        notice = nil
        withAnimation(MotionTokens.gentle) { phase = .idle }
    }

    // MARK: Navigation

    func open(_ node: SpaceNode) {
        guard node.canOpen else { return }
        hovered = nil
        withAnimation(MotionTokens.snappy) { path.append(node) }
    }

    /// Opens a folder several levels down: `trail` runs from a child of the
    /// current folder to the folder to open.
    func open(trail: [SpaceNode]) {
        guard let last = trail.last, last.canOpen else { return }
        hovered = nil
        withAnimation(MotionTokens.snappy) { path.append(contentsOf: trail) }
    }

    func goUp() {
        guard path.count > 1 else { return }
        hovered = nil
        withAnimation(MotionTokens.snappy) { _ = path.popLast() }
    }

    func go(toLevel index: Int) {
        guard index < path.count - 1 else { return }
        hovered = nil
        withAnimation(MotionTokens.snappy) { path = Array(path.prefix(index + 1)) }
    }

    // MARK: Selection

    func canPick(_ node: SpaceNode) -> Bool {
        guard node.kind != .smallerFiles, let url = url(of: node) else { return false }
        return SpaceLensScanner.canMoveToTrash(url)
    }

    func isPicked(_ node: SpaceNode) -> Bool { picks[ObjectIdentifier(node)] != nil }

    func togglePick(_ node: SpaceNode) {
        let id = ObjectIdentifier(node)
        if picks[id] != nil {
            picks[id] = nil
        } else if canPick(node), let url = url(of: node) {
            picks[id] = Pick(node: node, url: url, ancestors: path)
        }
    }

    func clearPicks() { picks = [:] }

    /// Moves the picked items to the Trash and takes them out of the map.
    func trashPicks() {
        guard !isTrashing, !picks.isEmpty else { return }
        // An item inside a picked folder goes with the folder.
        let pickedIDs = Set(picks.keys)
        let targets = picks.values.filter { pick in
            !pick.ancestors.contains { pickedIDs.contains(ObjectIdentifier($0)) }
        }
        isTrashing = true
        Task {
            let urls = targets.map(\.url)
            let failures = await Task.detached(priority: .userInitiated) { () -> [URL: String] in
                var failed: [URL: String] = [:]
                for url in urls {
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    } catch {
                        failed[url] = error.localizedDescription
                    }
                }
                return failed
            }.value

            var freed: Int64 = 0
            for pick in targets where failures[pick.url] == nil {
                guard let parent = pick.ancestors.last else { continue }
                let items = pick.node.kind == .folder ? pick.node.itemCount : max(pick.node.itemCount, 1)
                parent.removeChild(pick.node)
                for ancestor in pick.ancestors.dropLast() {
                    ancestor.shrink(by: pick.node.size, items: items)
                }
                freed += pick.node.size
            }
            picks = [:]
            hovered = nil
            isTrashing = false
            if freed > 0 { UsageStats.shared.recordCleanup(.spaceLens, bytes: freed) }
            // Leave folders that no longer exist.
            while let last = path.last, path.count > 1, !(path[path.count - 2].children.contains { $0 === last }) {
                path.removeLast()
            }
            objectWillChange.send()

            let size = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
            if failures.isEmpty {
                notice = (String(format: String(localized: "%@ moved to the Trash."), size), false)
            } else {
                notice = (String(format: String(localized: "%@ moved to the Trash. %lld items couldn't be moved."), size, Int64(failures.count)), true)
            }
        }
    }
}

/// Space Lens: a map of what takes up space on a disk or in a folder.
struct SpaceLensView: View {
    @ObservedObject private var model = SpaceLensModel.shared
    @State private var confirmingTrash = false

    private let palette = SectionPalette.spaceLens

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog(trashTitle, isPresented: $confirmingTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.trashPicks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can put them back from the Trash until you empty it.")
        }
    }

    private var trashTitle: String {
        let size = ByteCountFormatter.string(fromByteCount: model.selectedSize, countStyle: .file)
        return model.picks.count == 1
            ? String(format: String(localized: "Move 1 item (%@) to the Trash?"), size)
            : String(format: String(localized: "Move %lld items (%@) to the Trash?"), Int64(model.picks.count), size)
    }

    private var header: some View {
        FeaturePageHeader(
            title: Text("Space Lens"),
            systemImage: "chart.pie.fill",
            tint: palette.accent,
            detail: {
                Text(headerDetail)
                    .lineLimit(2)
                    .truncationMode(.middle)
            },
            accessory: {
                switch model.phase {
                case .idle:
                    EmptyView()
                case .scanning:
                    StopActionButton { model.stop() }
                case .results:
                    StartOverButton { model.startOver() }
                        .disabled(model.isTrashing)
                }
            }
        )
    }

    private var headerDetail: String {
        if model.phase == .results, let volume = model.volume, let url = model.rootURL {
            return String(format: String(localized: "%@ · %@ disk"),
                          FileManager.default.displayName(atPath: url.path),
                          ByteCountFormatter.string(fromByteCount: volume.total, countStyle: .file))
        }
        if model.phase == .results, let root = model.root, let url = model.rootURL {
            return String(format: String(localized: "%@ analyzed in %@"),
                          ByteCountFormatter.string(fromByteCount: root.size, countStyle: .file),
                          FileManager.default.displayName(atPath: url.path))
        }
        return String(localized: "See what takes up space, folder by folder, and clear what you don't need.")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idleCard
        case .scanning:
            scanningCard
        case .results:
            if let current = model.current {
                results(current)
            }
        }
    }

    // MARK: Idle

    private var idleCard: some View {
        CardSurface(padding: 0, elevation: .flat) {
            VStack(spacing: 15) {
                Spacer()
                GlassOrbIcon(systemImage: "scope", tint: palette.accent, size: 150)
                Text("See where your space goes")
                    .font(.system(size: 18, weight: .semibold))
                Text("Space Lens maps a disk or folder by size. Open folders to dig deeper, then pick what you no longer need. Nothing is removed without your confirmation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                ScanLocationPicker(selection: $model.location, tint: palette.accent)
                    .padding(.top, 6)
                Button {
                    model.start()
                } label: {
                    Label("Analyze", systemImage: "magnifyingglass")
                        .padding(.horizontal, 14)
                }
                .buttonStyle(GlassProminentButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 2)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Scanning

    /// While measuring: a slim progress line and the map taking shape.
    private var scanningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SpinningArc(tint: palette.accent)
                    .frame(width: 18, height: 18)
                    .scaleEffect(0.5)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: String(localized: "Measuring folders · %@ in %lld items"),
                                ByteCountFormatter.string(fromByteCount: model.progress.bytes, countStyle: .file),
                                Int64(model.progress.items)))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(model.progress.currentPath.isEmpty ? " " : model.progress.currentPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(GlassPanelBackground(cornerRadius: 16))

            CardSurface(padding: 8, elevation: .standard) {
                LiveSpaceMap(partial: model.partial)
            }
        }
    }

    // MARK: Results

    private func results(_ folder: SpaceNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = model.notice {
                NoticeBanner(text: notice.text, isError: notice.isError) { model.notice = nil }
            }
            HStack(spacing: 10) {
                PillTabBar(
                    tabs: SpaceLensTab.allCases,
                    selection: $model.tab,
                    title: { $0.title },
                    icon: { $0.icon },
                    badge: { tab in
                        guard tab == .apps, case .loaded(let apps) = model.apps else { return nil }
                        return "\(apps.count)"
                    }
                )
                Spacer(minLength: 12)
                if let volume = model.volume {
                    DiskCapacityBar(total: volume.total, free: volume.free)
                }
            }
            switch model.tab {
            case .treemap, .rings:
                BreadcrumbBar(model: model)
                HStack(alignment: .top, spacing: 14) {
                    SpaceLensList(model: model, folder: folder)
                        .frame(width: 330)
                    if model.tab == .treemap {
                        SpaceLensMap(model: model, folder: folder)
                    } else {
                        SpaceLensRings(model: model, folder: folder)
                    }
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity)
            case .apps:
                SpaceLensAppsView(model: model)
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
            }
            if !model.picks.isEmpty, model.tab != .apps {
                selectionBar
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(palette.accent)
            Text(String(format: String(localized: "%lld selected · %@"),
                        Int64(model.picks.count),
                        ByteCountFormatter.string(fromByteCount: model.selectedSize, countStyle: .file)))
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button("Clear") { model.clearPicks() }
                .buttonStyle(GlassButtonStyle())
                .disabled(model.isTrashing)
            Button {
                confirmingTrash = true
            } label: {
                if model.isTrashing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
            .buttonStyle(GlassProminentButtonStyle())
            .disabled(model.isTrashing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(GlassPanelBackground(cornerRadius: 18))
    }
}

// MARK: - Pieces

/// The whole disk at a glance, shown when a full volume was analyzed:
/// how big it is, how much is used and how much is free.
private struct DiskCapacityBar: View {
    let total: Int64
    let free: Int64

    private var used: Int64 { max(0, total - free) }
    private var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 6) {
                Text(String(format: String(localized: "%@ used of %@"),
                            ByteCountFormatter.string(fromByteCount: used, countStyle: .file),
                            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("·").foregroundStyle(.white.opacity(0.4))
                Text(String(format: String(localized: "%@ free"),
                            ByteCountFormatter.string(fromByteCount: free, countStyle: .file)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .monospacedDigit()
            .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(width: 260, height: 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(GlassPanelBackground(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
    }
}

private struct SpinningArc: View {
    let tint: Color
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

private struct BreadcrumbBar: View {
    @ObservedObject var model: SpaceLensModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(model.path.count < 2)
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .help("Back to the enclosing folder (⌘←)")
            .accessibilityLabel("Back")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.path.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        let isLast = index == model.path.count - 1
                        Button {
                            model.go(toLevel: index)
                        } label: {
                            Text(node.name)
                                .font(.system(size: 12.5, weight: isLast ? .semibold : .medium))
                                .foregroundStyle(.white.opacity(isLast ? 0.95 : 0.65))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLast)
                    }
                }
            }

            Spacer(minLength: 8)

            if let folder = model.current {
                Text(String(format: String(localized: "%@ · %lld items"),
                            ByteCountFormatter.string(fromByteCount: folder.size, countStyle: .file),
                            Int64(folder.itemCount)))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                if let url = model.currentURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(GlassIconButtonStyle())
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(GlassPanelBackground(cornerRadius: 16))
    }
}

extension SpaceCategory {
    var color: Color {
        switch self {
        case .folder: return SectionPalette.spaceLens.accent
        case .application: return Tint.blue
        case .package: return Tint.cyan
        case .video: return Tint.purple
        case .images: return Tint.green
        case .audio: return Tint.pink
        case .documents: return Tint.yellow
        case .archives: return Tint.orange
        case .code: return Tint.teal
        case .system: return Color(red: 0.52, green: 0.56, blue: 0.68)
        case .other: return Color(white: 0.66)
        }
    }

    var title: String {
        switch self {
        case .folder: return String(localized: "Folders")
        case .application: return String(localized: "Apps")
        case .package: return String(localized: "Packages")
        case .video: return String(localized: "Video")
        case .images: return String(localized: "Images")
        case .audio: return String(localized: "Audio")
        case .documents: return String(localized: "Documents")
        case .archives: return String(localized: "Archives & Disk Images")
        case .code: return String(localized: "Code & Data")
        case .system: return String(localized: "System & hidden data")
        case .other: return String(localized: "Other")
        }
    }
}

// MARK: - List

private struct SpaceLensList: View {
    @ObservedObject var model: SpaceLensModel
    let folder: SpaceNode

    var body: some View {
        CardSurface(padding: 0, elevation: .standard) {
            if folder.children.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: folder.isUnreadable ? "lock.fill" : "tray")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(folder.isUnreadable ? "MacFresh can't read this folder." : "This folder is empty.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(folder.children) { child in
                            SpaceLensRow(model: model, node: child, folderSize: folder.size)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

private struct SpaceLensRow: View {
    @ObservedObject var model: SpaceLensModel
    let node: SpaceNode
    let folderSize: Int64

    var body: some View {
        let canPick = model.canPick(node)
        let isHovered = model.hovered === node
        HStack(spacing: 10) {
            if canPick {
                Toggle("", isOn: Binding(get: { model.isPicked(node) }, set: { _ in model.togglePick(node) }))
                    .toggleStyle(AnimatedCheckboxStyle(tint: SectionPalette.spaceLens.accent))
                    .labelsHidden()
                    .disabled(model.isTrashing)
                    .accessibilityLabel(node.name)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 14)
                    .help(node.kind == .smallerFiles
                          ? "Open the folder in Finder to review these files one by one."
                          : node.kind == .hidden
                            ? "Used by macOS, not in any file you can open"
                            : "Protected: Space Lens only removes items in your own folders or on external disks.")
            }

            SpaceNodeIcon(node: node, url: model.url(of: node))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(node.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(node.category.color.opacity(0.85))
                            .frame(width: max(2, geometry.size.width * fraction))
                    }
                }
                .frame(height: 3)
            }

            Group {
                if node.canOpen {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.09 : 0))
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hovered = node } else if model.hovered === node { model.hovered = nil }
        }
        .onTapGesture {
            if node.canOpen { model.open(node) } else if canPick { model.togglePick(node) }
        }
        .contextMenu { SpaceNodeMenu(model: model, node: node) }
    }

    private var fraction: CGFloat {
        folderSize > 0 ? CGFloat(Double(node.size) / Double(folderSize)) : 0
    }
}

struct SpaceNodeIcon: View {
    let node: SpaceNode
    let url: URL?

    var body: some View {
        if node.kind == .smallerFiles {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
        } else if node.kind == .hidden {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 14))
                .foregroundStyle(SpaceCategory.system.color)
        } else if let url {
            FileIcon(path: url.path, size: 22)
        }
    }
}

struct SpaceNodeMenu: View {
    @ObservedObject var model: SpaceLensModel
    let node: SpaceNode

    var body: some View {
        if node.canOpen {
            Button("Open") { model.open(node) }
        }
        if let url = model.url(of: node) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if model.canPick(node) {
            Button(model.isPicked(node) ? "Deselect" : "Select for Removal") { model.togglePick(node) }
        }
    }
}

// MARK: - Map

private struct SpaceLensMap: View {
    @ObservedObject var model: SpaceLensModel
    let folder: SpaceNode

    /// The map shows the biggest items; the rest share one tile.
    private static let tileLimit = 48

    private struct Tile: Identifiable {
        let id: String
        let node: SpaceNode?
        let name: String
        let size: Int64
        let rank: Int
    }

    var body: some View {
        VStack(spacing: 10) {
            CardSurface(padding: 8, elevation: .standard) {
                GeometryReader { geometry in
                    let tiles = makeTiles()
                    let frames = SquarifiedTreemap.layout(tiles.map { Double($0.size) }, in: CGRect(origin: .zero, size: geometry.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                            tileView(tile, frame: frames[index])
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
                .overlay {
                    if folder.children.isEmpty {
                        Text(folder.isUnreadable ? "No access" : "Empty")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            infoBar
            legend
        }
    }

    private func makeTiles() -> [Tile] {
        let visible = folder.children.filter { $0.size > 0 }
        let shown = visible.prefix(Self.tileLimit)
        var tiles = shown.enumerated().map { index, node in
            Tile(id: "\(ObjectIdentifier(node).hashValue)", node: node, name: node.name, size: node.size, rank: index)
        }
        let rest = visible.dropFirst(Self.tileLimit)
        if !rest.isEmpty {
            let size = rest.reduce(Int64(0)) { $0 + $1.size }
            tiles.append(Tile(id: "rest", node: nil, name: String(format: String(localized: "%lld more items"), Int64(rest.count)), size: size, rank: tiles.count))
        }
        return tiles
    }

    @ViewBuilder
    private func tileView(_ tile: Tile, frame: CGRect) -> some View {
        let inset = frame.insetBy(dx: 1.5, dy: 1.5)
        if inset.width > 1, inset.height > 1 {
            SpaceTile(
                name: tile.name,
                size: tile.size,
                category: tile.node?.category ?? .other,
                rank: tile.rank,
                isFolder: tile.node?.canOpen ?? false,
                isHovered: tile.node != nil && model.hovered === tile.node,
                isPicked: tile.node.map(model.isPicked) ?? false,
                frameSize: inset.size,
                contents: tile.node?.canOpen == true ? tile.node?.children ?? [] : []
            )
            .frame(width: inset.width, height: inset.height)
            .offset(x: inset.minX, y: inset.minY)
            .onHover { inside in
                guard let node = tile.node else { return }
                if inside { model.hovered = node } else if model.hovered === node { model.hovered = nil }
            }
            .onTapGesture {
                guard let node = tile.node else { return }
                if node.canOpen { model.open(node) } else if model.canPick(node) { model.togglePick(node) }
            }
            .contextMenu {
                if let node = tile.node { SpaceNodeMenu(model: model, node: node) }
            }
        }
    }

    private var infoBar: some View { SpaceInfoBar(model: model, folder: folder) }

    private var legend: some View { SpaceLegend(folder: folder) }
}

/// What the pointer is over, or the folder itself. Shared by the treemap and
/// the rings.
struct SpaceInfoBar: View {
    @ObservedObject var model: SpaceLensModel
    let folder: SpaceNode

    var body: some View {
        let node = model.hovered ?? folder
        let isFolderSummary = model.hovered == nil
        let share = folder.size > 0 ? Double(node.size) / Double(folder.size) : 0
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(node.category.color)
                .frame(width: 10, height: 10)
            Text(node.name)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
            if !isFolderSummary {
                Text(share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0))))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            Spacer(minLength: 8)
            Text(detail(for: node, isFolderSummary: isFolderSummary))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(GlassPanelBackground(cornerRadius: 12))
    }

    private func detail(for node: SpaceNode, isFolderSummary: Bool) -> String {
        if node.kind == .hidden {
            return String(localized: "Used by macOS, not in any file you can open")
        }
        switch node.kind {
        case .folder:
            if isFolderSummary { return String(format: String(localized: "%lld items · Click a folder to open it"), Int64(node.itemCount)) }
            return String(format: String(localized: "Folder · %lld items"), Int64(node.itemCount))
        case .package:
            return String(format: String(localized: "%@ · %lld items"), node.category.title, Int64(node.itemCount))
        case .smallerFiles:
            return String(format: String(localized: "%lld files under 1 MB"), Int64(node.itemCount))
        case .file, .hidden:
            return node.category.title
        }
    }
}

/// The colors used in the current folder.
struct SpaceLegend: View {
    let folder: SpaceNode

    var body: some View {
        let present = SpaceCategory.allCases.filter { category in folder.children.contains { $0.category == category } }
        return HStack(spacing: 12) {
            ForEach(present, id: \.self) { category in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(category.color)
                        .frame(width: 9, height: 9)
                    Text(category.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }
}

private struct SpaceTile: View {
    let name: String
    let size: Int64
    let category: SpaceCategory
    let rank: Int
    let isFolder: Bool
    let isHovered: Bool
    let isPicked: Bool
    let frameSize: CGSize
    /// A folder's own items, drawn inside its tile when there's room.
    var contents: [SpaceNode] = []

    private var showsLabel: Bool { frameSize.width > 64 && frameSize.height > 34 }
    private var labelHeight: CGFloat { frameSize.height > 46 ? 38 : 24 }
    private var showsContents: Bool { !contents.isEmpty && frameSize.width > 110 && frameSize.height > labelHeight + 50 }

    var body: some View {
        let radius = min(10, min(frameSize.width, frameSize.height) / 4)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // Bigger items are brighter so the eye lands on them first.
        let strength = max(0.42, 0.95 - Double(min(rank, 12)) * 0.045)
        shape
            .fill(LinearGradient(
                colors: [category.color.opacity(strength), category.color.opacity(strength * 0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(shape.fill(Color.white.opacity(isHovered ? 0.18 : 0)))
            .overlay(shape.strokeBorder(isPicked ? Color.white : Color.white.opacity(isHovered ? 0.55 : 0.16), lineWidth: isPicked ? 2 : 0.8))
            .overlay(alignment: .topLeading) { label }
            .overlay {
                if showsContents {
                    NestedContents(nodes: Array(contents.prefix(30)))
                        .padding(.top, labelHeight)
                        .padding([.horizontal, .bottom], 6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isPicked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                }
            }
            .shadow(color: .black.opacity(isHovered ? 0.25 : 0), radius: 6, y: 2)
            .animation(MotionTokens.snappy, value: isHovered)
            .contentShape(shape)
    }

    @ViewBuilder
    private var label: some View {
        if showsLabel {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if isFolder, frameSize.width > 90 {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9.5))
                    }
                    Text(name)
                        .font(.system(size: frameSize.width > 160 ? 12.5 : 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if frameSize.height > 46 {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

/// The second level of the map: a folder's items drawn inside its tile.
private struct NestedContents: View {
    let nodes: [SpaceNode]

    var body: some View {
        Canvas { context, size in
            let values = nodes.map { Double(max($0.size, 0)) }
            let frames = SquarifiedTreemap.layout(values, in: CGRect(origin: .zero, size: size))
            for (index, frame) in frames.enumerated() {
                let rect = frame.insetBy(dx: 1, dy: 1)
                guard rect.width > 3, rect.height > 3 else { continue }
                let node = nodes[index]
                let path = Path(roundedRect: rect, cornerRadius: min(5, min(rect.width, rect.height) / 4), style: .continuous)
                let fill = node.category == .folder ? Color.black.opacity(0.16) : node.category.color.opacity(0.7)
                context.fill(path, with: .color(fill))
                context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: 0.6)
                if rect.width > 70, rect.height > 20 {
                    let text = Text(node.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    context.draw(text, in: rect.insetBy(dx: 5, dy: 3))
                }
            }
        }
    }
}

/// The top level of the map, drawn from what the scan has measured so far.
/// The folder being measured now grows in place, slightly dimmed.
private struct LiveSpaceMap: View {
    let partial: SpaceLensPartial?

    private struct Tile: Identifiable {
        let id: String
        let name: String
        let size: Int64
        let category: SpaceCategory
        let isCurrent: Bool
        let node: SpaceNode?
    }

    var body: some View {
        GeometryReader { geometry in
            let tiles = makeTiles()
            if tiles.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("The map appears as folders are measured.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                let frames = SquarifiedTreemap.layout(tiles.map { Double(max($0.size, 1)) }, in: CGRect(origin: .zero, size: geometry.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        let inset = frames[index].insetBy(dx: 1.5, dy: 1.5)
                        if inset.width > 1, inset.height > 1 {
                            SpaceTile(
                                name: tile.name,
                                size: tile.size,
                                category: tile.category,
                                rank: index,
                                isFolder: tile.category == .folder,
                                isHovered: false,
                                isPicked: false,
                                frameSize: inset.size,
                                contents: tile.node?.canOpen == true ? tile.node?.children ?? [] : []
                            )
                            .opacity(tile.isCurrent ? 0.72 : 1)
                            .overlay(alignment: .bottomTrailing) {
                                if tile.isCurrent, inset.width > 40, inset.height > 30 {
                                    ProgressView().controlSize(.small).padding(6)
                                }
                            }
                            .frame(width: inset.width, height: inset.height)
                            .offset(x: inset.minX, y: inset.minY)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .animation(.easeInOut(duration: 0.35), value: tiles.map(\.size))
            }
        }
    }

    private func makeTiles() -> [Tile] {
        guard let partial else { return [] }
        let tiles = partial.tops
            .filter { $0.bytes > 0 }
            .map { top in
                Tile(id: "t:\(top.name)", name: top.name, size: top.bytes, category: top.category, isCurrent: !top.isDone, node: nil)
            }
            .sorted { $0.size > $1.size }
        return Array(tiles.prefix(48))
    }
}
