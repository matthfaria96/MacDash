import AppKit
import SwiftUI

/// Where a Duplicates or Similar Photos scan looks: a whole disk, the user's
/// home folder, or any folder the user picked.
enum ScanLocation: Hashable, Identifiable {
    case startupDisk
    case volume(URL)
    case home
    case custom(URL)

    var id: String {
        switch self {
        case .startupDisk: return "startup"
        case .volume(let url): return "volume:\(url.path)"
        case .home: return "home"
        case .custom(let url): return "custom:\(url.path)"
        }
    }

    /// The folder handed to the scanner.
    var url: URL {
        switch self {
        case .startupDisk: return URL(fileURLWithPath: "/")
        case .volume(let url), .custom(let url): return url
        case .home: return FileManager.default.homeDirectoryForCurrentUser
        }
    }

    /// Disks show a used/free bar; folders show a line of text instead.
    var isDisk: Bool {
        switch self {
        case .startupDisk, .volume: return true
        case .home, .custom: return false
        }
    }
}

/// Free and total space of a disk, for the used/free bar.
struct DiskCapacity: Equatable {
    let total: Int64
    let free: Int64
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func read(at url: URL) -> DiskCapacity? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]), let total = values.volumeTotalCapacity else { return nil }
        // "Important usage" reads 0 on some external volumes; fall back to plain free space.
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let free = important > 0 ? important : Int64(values.volumeAvailableCapacity ?? 0)
        return DiskCapacity(total: Int64(total), free: free)
    }
}

/// Lists the disks that are mounted right now and keeps the list current as
/// drives are connected or ejected.
@MainActor
final class ScanLocationCatalog: ObservableObject {
    struct Volume: Identifiable, Hashable {
        let url: URL
        let name: String
        var id: String { url.path }
    }

    @Published private(set) var externalVolumes: [Volume] = []
    @Published private(set) var startupName: String = String(localized: "Macintosh HD")

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var external: [Volume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsRootFileSystem == true {
                if let name = values.volumeLocalizedName, !name.isEmpty { startupName = name }
                continue
            }
            guard values.volumeIsBrowsable != false, url.path.hasPrefix("/Volumes/") else { continue }
            external.append(Volume(url: url, name: values.volumeLocalizedName ?? url.lastPathComponent))
        }
        externalVolumes = external.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func title(for location: ScanLocation) -> String {
        switch location {
        case .startupDisk: return startupName
        case .volume(let url): return externalVolumes.first { $0.url == url }?.name ?? url.lastPathComponent
        case .home: return String(localized: "User Folder")
        case .custom(let url): return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }
    }

    static func icon(for location: ScanLocation) -> String {
        switch location {
        case .startupDisk: return "internaldrive.fill"
        case .volume: return "externaldrive.fill"
        case .home: return "person.crop.circle.fill"
        case .custom: return "folder.fill"
        }
    }
}

/// Premium location chooser: a glass field showing the current location (disk
/// space, or the folder's path) that opens a list of disks, the user folder
/// and "Choose Folder…".
struct ScanLocationPicker: View {
    @Binding var selection: ScanLocation
    var tint: Color = Tint.accent
    var isDisabled = false

    @StateObject private var catalog = ScanLocationCatalog()
    @State private var showList = false
    @State private var hovering = false

    var body: some View {
        Button {
            catalog.refresh()
            showList.toggle()
        } label: {
            HStack(spacing: 14) {
                LocationBadge(location: selection, tint: tint, size: 42)
                LocationDetail(location: selection, title: catalog.title(for: selection), showsBar: true, tint: tint)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 460)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial).opacity(0.6)
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(hovering || showList ? 0.13 : 0.08))
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(showList ? tint.opacity(0.7) : Color.clear, lineWidth: 1.2))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .onHover { hovering = $0 }
        .popover(isPresented: $showList, arrowEdge: .bottom) { list }
        .accessibilityLabel(Text("Location"))
        .accessibilityValue(Text(catalog.title(for: selection)))
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            option(.startupDisk)
            ForEach(catalog.externalVolumes) { volume in
                option(.volume(volume.url))
            }
            Divider().padding(.vertical, 4)
            option(.home)
            if case .custom = selection {
                option(selection)
            }
            Divider().padding(.vertical, 4)
            Button {
                showList = false
                chooseFolder()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                    Text("Choose Folder…")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(OptionRowStyle())
        }
        .padding(10)
        .frame(width: 380)
    }

    private func option(_ location: ScanLocation) -> some View {
        Button {
            selection = location
            showList = false
        } label: {
            HStack(spacing: 12) {
                LocationBadge(location: location, tint: tint, size: 34)
                LocationDetail(location: location, title: catalog.title(for: location), showsBar: true, tint: tint)
                Spacer(minLength: 6)
                if location == selection {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(OptionRowStyle())
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a folder")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selection = .custom(url.standardizedFileURL)
    }
}

private struct OptionRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)))
            )
            .onHover { hovering = $0 }
    }
}

private struct LocationBadge: View {
    let location: ScanLocation
    let tint: Color
    let size: CGFloat

    var body: some View {
        CategoryBadge(systemName: ScanLocationCatalog.icon(for: location), tint: tint, size: size)
    }
}

/// Title plus the line under it: used/free bar for disks, a note for the user
/// folder, or the path for a custom folder.
private struct LocationDetail: View {
    let location: ScanLocation
    let title: String
    let showsBar: Bool
    let tint: Color

    @State private var capacity: DiskCapacity?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            switch location {
            case .startupDisk, .volume:
                if let capacity {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.14))
                                Capsule()
                                    .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(4, geometry.size.width * capacity.usedFraction))
                            }
                        }
                        .frame(height: 5)
                        Text(String(
                            format: String(localized: "%@ free of %@"),
                            ByteCountFormatter.string(fromByteCount: capacity.free, countStyle: .file),
                            ByteCountFormatter.string(fromByteCount: capacity.total, countStyle: .file)
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .frame(width: 210, alignment: .leading)
                }
            case .home:
                Text("Your personal folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .custom(let url):
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
            }
        }
        .onAppear { capacity = location.isDisk ? DiskCapacity.read(at: location.url) : nil }
        .onChange(of: location) { newLocation in
            capacity = newLocation.isDisk ? DiskCapacity.read(at: newLocation.url) : nil
        }
    }
}
