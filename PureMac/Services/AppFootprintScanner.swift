import Foundation

/// How much space one installed app takes in total: its bundle plus the data
/// it keeps in the user's Library and a few well-known extra places.
struct AppFootprint: Identifiable, Sendable {
    enum PartKind: Hashable, Sendable {
        case bundle, support, caches, containers, other
        /// A known extra location, such as Xcode's DerivedData.
        case extra(String)
    }

    struct Part: Identifiable, Sendable {
        let kind: PartKind
        var size: Int64
        /// Folders and files that make up this part, largest first.
        var paths: [URL]

        var id: PartKind { kind }
    }

    let name: String
    let bundleIdentifier: String
    let appURL: URL
    let parts: [Part]

    var id: String { appURL.path }
    var totalSize: Int64 { parts.reduce(0) { $0 + $1.size } }
}

enum AppFootprintScanner {
    /// Apps smaller than this in total are left out.
    static let minimumSize: Int64 = 1_000_000

    /// Library folders searched for each app, and what they count as. Entries
    /// are named after the bundle id, or the app name where noted.
    private static let libraryPlaces: [(folder: String, kind: AppFootprint.PartKind, suffix: String, byName: Bool)] = [
        ("Application Support", .support, "", true),
        ("Caches", .caches, "", true),
        ("Containers", .containers, "", false),
        ("HTTPStorages", .caches, "", false),
        ("WebKit", .caches, "", false),
        ("Saved Application State", .other, ".savedState", false),
        ("Preferences", .other, ".plist", false),
        ("Logs", .other, "", true),
    ]

    /// Apps that keep large data somewhere their bundle id doesn't give away.
    /// (bundle id fragment, label, path relative to the home folder)
    private static let extraPlaces: [(match: String, label: String, path: String)] = [
        ("com.apple.dt.Xcode", "DerivedData", "Library/Developer/Xcode/DerivedData"),
        ("com.apple.dt.Xcode", "Simulators", "Library/Developer/CoreSimulator"),
        ("com.apple.dt.Xcode", "Archives", "Library/Developer/Xcode/Archives"),
        ("com.apple.dt.Xcode", "Device Support", "Library/Developer/Xcode/iOS DeviceSupport"),
        ("com.valvesoftware.steam", "Game Data", "Library/Application Support/Steam/steamapps"),
        ("com.docker.docker", "VM Data", "Library/Containers/com.docker.docker/Data/vms"),
        ("com.google.Chrome", "Profiles", "Library/Application Support/Google/Chrome"),
        ("com.microsoft.VSCode", "Extensions", ".vscode/extensions"),
        ("com.todesktop.230313mzl4w4u92", "Extensions", ".cursor/extensions"),
        ("com.spotify.client", "Offline Cache", "Library/Application Support/Spotify/PersistentCache"),
    ]

    /// Measures every app in /Applications and ~/Applications (and one folder
    /// deeper). `knownSize` answers from an earlier scan when it can; anything
    /// it doesn't know is measured on disk.
    static func scan(
        knownSize: @Sendable (String) -> Int64?,
        onProgress: @Sendable (_ done: Int, _ total: Int, _ name: String) -> Void
    ) -> [AppFootprint] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let apps = discoverApps(home: home)
        var results: [AppFootprint] = []

        func size(of path: String) -> Int64 {
            if let known = knownSize(path) { return known }
            return measure(path)
        }

        for (index, app) in apps.enumerated() {
            if Task.isCancelled { return [] }
            onProgress(index, apps.count, app.name)
            var parts: [AppFootprint.PartKind: AppFootprint.Part] = [:]
            var counted: [(path: String, kind: AppFootprint.PartKind, size: Int64)] = []
            var measured: [String: Int64] = [:]

            func add(_ kind: AppFootprint.PartKind, path: String, size: Int64) {
                guard size > 0 else { return }
                parts[kind, default: AppFootprint.Part(kind: kind, size: 0, paths: [])].size += size
                parts[kind]?.paths.append(URL(fileURLWithPath: path))
                counted.append((path, kind, size))
                measured[path] = size
            }

            add(.bundle, path: app.url.path, size: size(of: app.url.path))

            var visited = Set<String>()
            for place in libraryPlaces {
                var names = [app.bundleID + place.suffix]
                if place.byName, app.name != app.bundleID { names.append(app.name) }
                for name in names {
                    let path = "\(home)/Library/\(place.folder)/\(name)"
                    guard visited.insert(path).inserted, FileManager.default.fileExists(atPath: path) else { continue }
                    add(place.kind, path: path, size: size(of: path))
                }
            }

            for extra in extraPlaces where app.bundleID.contains(extra.match) {
                let path = "\(home)/\(extra.path)"
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let extraSize = size(of: path)
                // An extra place inside a folder already counted (Steam's games
                // live in its Application Support folder) moves out of that
                // part instead of being counted twice.
                if let parent = counted.first(where: { path.hasPrefix($0.path + "/") }) {
                    parts[parent.kind]?.size -= extraSize
                }
                add(.extra(extra.label), path: path, size: extraSize)
            }

            let list = parts.values
                .filter { $0.size > 0 }
                .map { part -> AppFootprint.Part in
                    var part = part
                    part.paths.sort { (measured[$0.path] ?? 0) > (measured[$1.path] ?? 0) }
                    return part
                }
                .sorted { $0.size > $1.size }
            let footprint = AppFootprint(name: app.name, bundleIdentifier: app.bundleID, appURL: app.url, parts: list)
            if footprint.totalSize >= minimumSize { results.append(footprint) }
        }
        onProgress(apps.count, apps.count, "")
        return results.sorted { $0.totalSize > $1.totalSize }
    }

    private struct DiscoveredApp {
        let url: URL
        let name: String
        let bundleID: String
    }

    private static func discoverApps(home: String) -> [DiscoveredApp] {
        var apps: [DiscoveredApp] = []
        var seen = Set<String>()
        let fileManager = FileManager.default

        func consider(_ url: URL) {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                  seen.insert(bundleID).inserted else { return }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            apps.append(DiscoveredApp(url: url, name: name, bundleID: bundleID))
        }

        for root in ["/Applications", "\(home)/Applications"] {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(entry)
                if url.pathExtension == "app" {
                    consider(url)
                } else if let inner = try? fileManager.contentsOfDirectory(atPath: url.path) {
                    // One level down, like /Applications/Utilities.
                    for item in inner.sorted() where item.hasSuffix(".app") {
                        consider(url.appendingPathComponent(item))
                    }
                }
            }
        }
        return apps
    }

    /// Allocated bytes under `path`, without following links or leaving the volume.
    static func measure(_ path: String) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            var info = stat()
            return lstat(path, &info) == 0 ? Int64(info.st_blocks) * 512 : 0
        }
        let device = DirectoryLister.device(of: path)
        var total: Int64 = 0
        var stack = [path]
        while let folder = stack.popLast() {
            if Task.isCancelled { return total }
            autoreleasepool {
                for entry in DirectoryLister.list(folder) ?? [] {
                    switch entry.kind {
                    case .file: total += entry.allocated
                    case .directory where entry.device == device || device == nil: stack.append(folder + "/" + entry.name)
                    default: break
                    }
                }
            }
        }
        return total
    }
}
