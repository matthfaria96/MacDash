import AppKit
import Foundation

/// Docker commands offered as cleanup items. Unlike the Developer area's
/// prune, these also remove tagged images and named volumes nobody uses.
enum DockerDataAction: String, CaseIterable, Sendable {
    case images
    case volumes
    case buildCache

    /// Commands to try in order; the next one runs only if the previous failed.
    var commands: [[String]] {
        switch self {
        case .images: return [["image", "prune", "--all", "--force"]]
        // `--all` (named volumes too) exists since Docker 23; older engines
        // already include named volumes without it.
        case .volumes: return [["volume", "prune", "--all", "--force"], ["volume", "prune", "--force"]]
        case .buildCache: return [["builder", "prune", "--all", "--force"]]
        }
    }

    /// The row of `docker system df` this command reclaims.
    var diskUsageType: String {
        switch self {
        case .images: return "Images"
        case .volumes: return "Local Volumes"
        case .buildCache: return "Build Cache"
        }
    }

    var title: String {
        switch self {
        case .images: return String(localized: "All unused Docker images, including tagged ones")
        case .volumes: return String(localized: "Unused Docker volumes (may hold database data)")
        case .buildCache: return String(localized: "All Docker build cache")
        }
    }

    var itemPath: String { CleanableItem.dockerActionPathPrefix + rawValue }

    init?(itemPath: String) {
        guard itemPath.hasPrefix(CleanableItem.dockerActionPathPrefix) else { return nil }
        self.init(rawValue: String(itemPath.dropFirst(CleanableItem.dockerActionPathPrefix.count)))
    }
}

/// Finds whole virtual machines and Docker's own disks. Every item starts
/// unselected: these are things people may still need, so the user opts in
/// one by one. Machines are moved to the Trash, never deleted outright.
enum VirtualMachineFinder {
    /// Where one tool keeps its machines.
    struct Place: Sendable {
        let folder: String
        /// Extensions a machine has here; nil means every folder is one.
        let extensions: Set<String>?
        let tool: String
        /// Apps (by bundle id) or command-line processes that must be quit
        /// before a machine can be moved safely.
        let bundleIDs: [String]
        let processes: [String]
    }

    static func places(home: String) -> [Place] {
        [
            Place(folder: "\(home)/Library/Containers/com.utmapp.UTM/Data/Documents", extensions: ["utm"], tool: "UTM",
                  bundleIDs: ["com.utmapp.UTM"], processes: []),
            Place(folder: "\(home)/Parallels", extensions: ["pvm"], tool: "Parallels Desktop",
                  bundleIDs: ["com.parallels.desktop.console"], processes: ["prl_vm_app"]),
            Place(folder: "\(home)/Documents/Parallels", extensions: ["pvm"], tool: "Parallels Desktop",
                  bundleIDs: ["com.parallels.desktop.console"], processes: ["prl_vm_app"]),
            Place(folder: "\(home)/Virtual Machines.localized", extensions: ["vmwarevm"], tool: "VMware Fusion",
                  bundleIDs: ["com.vmware.fusion"], processes: ["vmware-vmx"]),
            Place(folder: "\(home)/Documents/Virtual Machines.localized", extensions: ["vmwarevm"], tool: "VMware Fusion",
                  bundleIDs: ["com.vmware.fusion"], processes: ["vmware-vmx"]),
            Place(folder: "\(home)/VirtualBox VMs", extensions: nil, tool: "VirtualBox",
                  bundleIDs: ["org.virtualbox.app.VirtualBox"], processes: ["VBoxHeadless", "VirtualBoxVM"]),
            Place(folder: "\(home)/.tart/vms", extensions: nil, tool: "Tart", bundleIDs: [], processes: ["tart"]),
            Place(folder: "\(home)/.lima", extensions: nil, tool: "Lima", bundleIDs: [], processes: ["limactl"]),
            Place(folder: "\(home)/.colima/_lima", extensions: nil, tool: "Colima", bundleIDs: [], processes: ["colima", "limactl"]),
            Place(folder: "\(home)/.local/share/containers/podman/machine/applehv", extensions: ["raw", "img"], tool: "Podman",
                  bundleIDs: [], processes: ["vfkit", "podman"]),
            Place(folder: "\(home)/.local/share/containers/podman/machine/libkrun", extensions: ["raw", "img"], tool: "Podman",
                  bundleIDs: [], processes: ["krunkit", "podman"]),
            Place(folder: "\(home)/.local/share/containers/podman/machine/qemu", extensions: ["qcow2", "raw"], tool: "Podman",
                  bundleIDs: [], processes: ["qemu-system-aarch64", "qemu-system-x86_64", "podman"]),
            Place(folder: "\(home)/.android/avd", extensions: ["avd"], tool: "Android Emulator", bundleIDs: [],
                  processes: ["qemu-system-aarch64", "qemu-system-x86_64", "emulator"]),
        ]
    }

    /// Docker's own disks: removing one resets that tool to empty.
    static func dockerDisks(home: String) -> [(path: String, tool: String, place: Place)] {
        [
            ("\(home)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "Docker Desktop",
             Place(folder: "\(home)/Library/Containers/com.docker.docker/Data/vms/0/data", extensions: ["raw"], tool: "Docker Desktop",
                   bundleIDs: ["com.docker.docker"], processes: ["com.docker.backend", "com.docker.virtualization"])),
            ("\(home)/.orbstack/data", "OrbStack",
             Place(folder: "\(home)/.orbstack", extensions: nil, tool: "OrbStack",
                   bundleIDs: ["dev.kdrag0n.MacVirt"], processes: ["OrbStack Helper", "orbstack-helper"])),
        ]
    }

    // MARK: Finding

    static func findMachines(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [CleanableItem] {
        var items: [CleanableItem] = []
        var seen = Set<String>()
        for place in places(home: home) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: place.folder) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") && !name.hasPrefix("_") {
                if Task.isCancelled { return items }
                let path = place.folder + "/" + name
                guard seen.insert(path).inserted, matches(path, name: name, in: place) else { continue }
                let size = AppFootprintScanner.measure(path)
                guard size > 0 else { continue }
                let lastUsed = lastChange(of: path)
                items.append(CleanableItem(
                    name: label(for: (name as NSString).deletingPathExtension, tool: place.tool, lastUsed: lastUsed),
                    path: path,
                    size: size,
                    category: .virtualMachines,
                    isSelected: false,
                    lastModified: lastUsed
                ))
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    private static func matches(_ path: String, name: String, in place: Place) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        if let extensions = place.extensions {
            return extensions.contains((name as NSString).pathExtension.lowercased())
        }
        return isDirectory.boolValue
    }

    /// Items for the Docker data area: Docker's commands for unused data,
    /// then each tool's whole disk.
    static func findDockerData(home: String = FileManager.default.homeDirectoryForCurrentUser.path) async -> [CleanableItem] {
        var items: [CleanableItem] = []
        if let docker = dockerBinary(home: home), let usage = await reclaimable(docker: docker) {
            for action in DockerDataAction.allCases {
                guard let bytes = usage[action.diskUsageType], bytes > 0 else { continue }
                items.append(CleanableItem(name: action.title, path: action.itemPath, size: bytes,
                                           category: .dockerData, isSelected: false, lastModified: nil))
            }
        }
        for disk in dockerDisks(home: home) where FileManager.default.fileExists(atPath: disk.path) {
            let size = AppFootprintScanner.measure(disk.path)
            guard size > 0 else { continue }
            items.append(CleanableItem(
                name: String(format: String(localized: "%@ disk: every image, container and volume (Docker starts empty)"), disk.tool),
                path: disk.path,
                size: size,
                category: .dockerData,
                isSelected: false,
                lastModified: lastChange(of: disk.path)
            ))
        }
        return items
    }

    static func dockerBinary(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.orbstack/bin/docker",
         "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Reclaimable bytes per `docker system df` row, or nil when Docker isn't running.
    private static func reclaimable(docker: String) async -> [String: Int64]? {
        guard let output = try? await BrewProcessRunner.run(
            executableURL: URL(fileURLWithPath: docker),
            arguments: ["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"],
            timeout: 10
        ), output.status == 0 else { return nil }
        var usage: [String: Int64] = [:]
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            // "1.234GB (45%)": the number comes first.
            usage[parts[0]] = parseBytes(parts[1].split(separator: " ").first.map(String.init) ?? "")
        }
        return usage
    }

    /// Docker's compact sizes ("1.23GB", "456MB", "789kB", "0B").
    static func parseBytes(_ text: String) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, multiplier) in units where text.hasSuffix(suffix) {
            if let value = Double(text.dropLast(suffix.count)) { return Int64(value * multiplier) }
        }
        return nil
    }

    // MARK: Safety

    /// The place `path` belongs to, when it is one machine (or Docker disk)
    /// directly inside a known folder. Anything else is never removed.
    static func place(for path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Place? {
        let normalized = (path as NSString).standardizingPath
        let parent = (normalized as NSString).deletingLastPathComponent
        let name = (normalized as NSString).lastPathComponent
        if let disk = dockerDisks(home: home).first(where: { $0.path == normalized }) { return disk.place }
        return places(home: home).first { place in
            parent == place.folder && !name.hasPrefix(".") && !name.hasPrefix("_")
                && (place.extensions?.contains((name as NSString).pathExtension.lowercased()) ?? true)
        }
    }

    /// The tool that has to be quit first, if it is running. Moving a disk
    /// out from under a running machine would corrupt it.
    static func runningTool(for place: Place) -> String? {
        let appRunning = place.bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        if appRunning || place.processes.contains(where: isProcessRunning) { return place.tool }
        return nil
    }

    private static func isProcessRunning(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: Labels

    /// The most recent change inside a machine: its disks are written while
    /// it runs, so this is close to when it was last used.
    static func lastChange(of path: String) -> Date? {
        let fileManager = FileManager.default
        var newest = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        for name in (try? fileManager.contentsOfDirectory(atPath: path)) ?? [] {
            if let date = (try? fileManager.attributesOfItem(atPath: path + "/" + name))?[.modificationDate] as? Date,
               date > (newest ?? .distantPast) {
                newest = date
            }
        }
        return newest
    }

    private static func label(for name: String, tool: String, lastUsed: Date?) -> String {
        guard let lastUsed else { return "\(name) · \(tool)" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(format: String(localized: "%@ · %@ · used %@"), name, tool,
                      formatter.localizedString(for: lastUsed, relativeTo: Date()))
    }
}
