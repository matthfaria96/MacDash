import Foundation

// Drive Offload: what may move to an external drive, what is better cleaned,
// and what must never move. Folders that move are replaced by a symbolic link,
// so every app keeps finding them at the same path.

/// What MacDash suggests for a folder.
enum OffloadAdvice: Equatable {
    /// Large data that can live on the external drive.
    case move
    /// A cache that rebuilds itself: cleaning frees the space for good.
    case clean
    /// The owning app has its own way to relocate it; a link would break it.
    case nativeSetting(String)
}

/// A folder MacDash knows about.
struct OffloadCatalogEntry: Identifiable, Equatable {
    let id: String
    /// Path relative to the home folder.
    let relativePath: String
    let title: String
    let detail: String
    let symbol: String
    let advice: OffloadAdvice
    /// Apps that must be closed while the folder moves.
    var bundleIdentifiers: [String] = []
    /// Command-line processes that must not be running (e.g. "ollama").
    var processNames: [String] = []
    /// True when the content rebuilds itself if it is ever lost.
    var regenerates = false
}

enum DriveOffloadCatalog {
    static let entries: [OffloadCatalogEntry] = [
        OffloadCatalogEntry(
            id: "claude.vm", relativePath: "Library/Application Support/Claude/vm_bundles",
            title: String(localized: "Claude virtual machines"),
            detail: String(localized: "Images Claude uses to run code. Large and only read while Claude works."),
            symbol: "cpu.fill", advice: .move,
            bundleIdentifiers: ["com.anthropic.claudefordesktop"], processNames: ["Claude"], regenerates: true
        ),
        OffloadCatalogEntry(
            id: "ollama.models", relativePath: ".ollama/models",
            title: String(localized: "Ollama models"),
            detail: String(localized: "Downloaded AI models. Loaded into memory when used, so the drive speed matters little."),
            symbol: "cpu.fill", advice: .move,
            bundleIdentifiers: ["com.electron.ollama"], processNames: ["ollama", "Ollama"], regenerates: true
        ),
        OffloadCatalogEntry(
            id: "lmstudio.models", relativePath: ".lmstudio/models",
            title: String(localized: "LM Studio models"),
            detail: String(localized: "Downloaded AI models. Loaded into memory when used, so the drive speed matters little."),
            symbol: "cpu.fill", advice: .move,
            bundleIdentifiers: ["ai.elementlabs.lmstudio"], processNames: ["LM Studio", "lms"], regenerates: true
        ),
        OffloadCatalogEntry(
            id: "lmstudio.cache", relativePath: ".cache/lm-studio/models",
            title: String(localized: "LM Studio models"),
            detail: String(localized: "Downloaded AI models. Loaded into memory when used, so the drive speed matters little."),
            symbol: "cpu.fill", advice: .move,
            bundleIdentifiers: ["ai.elementlabs.lmstudio"], processNames: ["LM Studio", "lms"], regenerates: true
        ),
        OffloadCatalogEntry(
            id: "huggingface", relativePath: ".cache/huggingface",
            title: String(localized: "Hugging Face models"),
            detail: String(localized: "Models and datasets downloaded by Python AI tools."),
            symbol: "cpu.fill", advice: .move, processNames: ["python", "python3"], regenerates: true
        ),
        OffloadCatalogEntry(
            id: "simulators", relativePath: "Library/Developer/CoreSimulator/Devices",
            title: String(localized: "iOS simulators"),
            detail: String(localized: "Simulated iPhones and iPads with their apps and data."),
            symbol: "iphone", advice: .move,
            bundleIdentifiers: ["com.apple.dt.Xcode", "com.apple.iphonesimulator"],
            processNames: ["com.apple.CoreSimulator.CoreSimulatorService", "launchd_sim"]
        ),
        OffloadCatalogEntry(
            id: "xcode.archives", relativePath: "Library/Developer/Xcode/Archives",
            title: String(localized: "Xcode archives"),
            detail: String(localized: "Builds you exported. Rarely opened again."),
            symbol: "archivebox.fill", advice: .move, bundleIdentifiers: ["com.apple.dt.Xcode"]
        ),
        OffloadCatalogEntry(
            id: "xcode.devicesupport", relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
            title: String(localized: "Device support files"),
            detail: String(localized: "Debug symbols for each iPhone version you connected."),
            symbol: "iphone", advice: .move, bundleIdentifiers: ["com.apple.dt.Xcode"], regenerates: true
        ),
        OffloadCatalogEntry(
            id: "cargo.registry", relativePath: ".cargo/registry",
            title: String(localized: "Rust crates"),
            detail: String(localized: "Downloaded Rust packages. Cargo downloads them again if needed."),
            symbol: "shippingbox.fill", advice: .move, processNames: ["cargo", "rust-analyzer"], regenerates: true
        ),
        OffloadCatalogEntry(
            id: "rustup.toolchains", relativePath: ".rustup/toolchains",
            title: String(localized: "Rust toolchains"),
            detail: String(localized: "Compilers installed by rustup. Rust builds stop while the drive is away."),
            symbol: "hammer.fill", advice: .move, processNames: ["cargo", "rustc", "rust-analyzer"], regenerates: true
        ),
        OffloadCatalogEntry(
            id: "iphone.backups", relativePath: "Library/Application Support/MobileSync/Backup",
            title: String(localized: "iPhone and iPad backups"),
            detail: String(localized: "Backups made by Finder. Keep the drive connected when you back up a device."),
            symbol: "iphone", advice: .move, processNames: ["AMPDevicesAgent"]
        ),
        OffloadCatalogEntry(
            id: "downloads", relativePath: "Downloads",
            title: String(localized: "Downloads"),
            detail: String(localized: "Everything you downloaded. New downloads go to the drive too."),
            symbol: "arrow.down.circle.fill", advice: .move
        ),
        OffloadCatalogEntry(
            id: "movies", relativePath: "Movies",
            title: String(localized: "Movies"),
            detail: String(localized: "Videos and editing projects."),
            symbol: "film.fill", advice: .move
        ),

        // Better cleaned than moved: they rebuild on their own.
        OffloadCatalogEntry(
            id: "derivedData", relativePath: "Library/Developer/Xcode/DerivedData",
            title: String(localized: "Xcode build files"),
            detail: String(localized: "Rebuilt on the next build. Cleaning frees the space for good."),
            symbol: "hammer.fill", advice: .clean, regenerates: true
        ),
        OffloadCatalogEntry(
            id: "npm", relativePath: ".npm",
            title: String(localized: "npm cache"),
            detail: String(localized: "Downloaded packages that npm fetches again when needed."),
            symbol: "leaf.fill", advice: .clean, regenerates: true
        ),
        OffloadCatalogEntry(
            id: "pnpm", relativePath: "Library/pnpm/store",
            title: String(localized: "pnpm store"),
            detail: String(localized: "Downloaded packages that pnpm fetches again when needed."),
            symbol: "leaf.fill", advice: .clean, regenerates: true
        ),
        OffloadCatalogEntry(
            id: "caches", relativePath: "Library/Caches",
            title: String(localized: "App caches"),
            detail: String(localized: "Temporary files apps rebuild. Never move them: apps expect them on the Mac."),
            symbol: "internaldrive.fill", advice: .clean, regenerates: true
        ),

        // Apps with their own setting for this.
        OffloadCatalogEntry(
            id: "photos", relativePath: "Pictures/Photos Library.photoslibrary",
            title: String(localized: "Photos library"),
            detail: String(localized: "Photos can't follow a link."),
            symbol: "photo.fill",
            advice: .nativeSetting(String(localized: "Quit Photos, move the library to the drive in Finder, then open it with Option held and pick it as the System Photo Library."))
        ),
        OffloadCatalogEntry(
            id: "docker", relativePath: "Library/Containers/com.docker.docker",
            title: String(localized: "Docker disk"),
            detail: String(localized: "Docker keeps its images in one large disk file."),
            symbol: "shippingbox.fill",
            advice: .nativeSetting(String(localized: "Open Docker Desktop › Settings › Resources › Advanced and change the disk image location to the drive."))
        ),
    ]
}

/// Why a folder can't move.
enum OffloadBlockReason: Equatable {
    case outsideHome
    case protected
    case alreadyLink
    case iCloud
    case notFolder
    case nested
    case otherDisk

    var message: String {
        switch self {
        case .outsideHome: return String(localized: "Only folders in your home folder can move.")
        case .protected: return String(localized: "macOS or the app depends on this folder staying on the Mac.")
        case .alreadyLink: return String(localized: "This folder is already a link to another place.")
        case .iCloud: return String(localized: "iCloud syncs this folder. Moving it would break syncing.")
        case .notFolder: return String(localized: "Only folders can move.")
        case .nested: return String(localized: "A folder inside or around this one has already moved.")
        case .otherDisk: return String(localized: "This folder is on another disk.")
        }
    }
}

enum OffloadSafety {
    /// Paths (relative to home) that must never become links, along with
    /// everything inside them.
    static let protectedPrefixes = [
        "Library/Preferences", "Library/Keychains", "Library/Containers", "Library/Group Containers",
        "Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/CloudStorage",
        "Library/Application Support/CloudDocs", "Library/Accounts", "Library/Cookies", "Library/Safari",
        "Library/Metadata", "Library/LaunchAgents", "Library/Caches", "Library/Daemon Containers",
        "Library/Application Support/com.apple.TCC", "Library/Application Support/AddressBook",
        "Library/Calendars", "Library/HTTPStorages", "Library/Biome", "Library/Trial",
        "Library/IdentityServices", "Library/Sharing", "Library/Saved Application State",
        "Library/Application Support/FileProvider", "Library/Application Support/Knowledge",
        "Library/Photos", ".Trash", ".ssh", ".gnupg", "Applications",
    ]

    /// Paths that can't move themselves but whose subfolders may.
    static let protectedExact = [
        "", "Library", "Library/Application Support", "Library/Developer", "Desktop", "Documents",
        "Pictures", "Music", ".config", ".local", ".cache", ".cargo", ".rustup",
    ]

    /// Checks a folder against the rules. `home` and `moved` are passed in so
    /// tests can use temporary folders.
    static func blockReason(
        for url: URL,
        home: URL,
        moved: [String],
        fileManager: FileManager = .default
    ) -> OffloadBlockReason? {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return .outsideHome }
        let relative = String(path.dropFirst(homePath.count + 1))

        if protectedExact.contains(relative) { return .protected }
        for prefix in protectedPrefixes where relative == prefix || relative.hasPrefix(prefix + "/") {
            return .protected
        }
        if relative.hasSuffix(".photoslibrary") || relative.contains(".photoslibrary/") { return .protected }

        for other in moved {
            if other == path || path.hasPrefix(other + "/") || other.hasPrefix(path + "/") { return .nested }
        }

        if DriveOffloadEngine.isSymbolicLink(url) { return .alreadyLink }
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isUbiquitousItemKey, .volumeIdentifierKey]) else {
            return .notFolder
        }
        if values.isSymbolicLink == true { return .alreadyLink }
        if values.isDirectory != true { return .notFolder }
        if values.isUbiquitousItem == true { return .iCloud }
        let homeVolume = (try? home.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        if let volume = values.volumeIdentifier as? NSObject, let homeVolume, !volume.isEqual(homeVolume) {
            return .otherDisk
        }
        return nil
    }
}
