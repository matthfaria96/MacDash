import Foundation

/// What the Assistant knows about the Mac: where editors, Claude and build
/// tools leave their data, which folders a project can rebuild, and which
/// paths it may ever move to the Trash. Everything here is a fixed rule that
/// can be read and tested; nothing is guessed.
enum AssistantCatalog {
    // MARK: - Editors built on VS Code

    struct Editor: Sendable {
        let key: String
        let name: String
        let bundleIDs: [String]
        /// Relative to the home folder.
        let extensionsDir: String
        let supportDir: String
    }

    static let editors: [Editor] = [
        Editor(key: "vscode", name: "Visual Studio Code", bundleIDs: ["com.microsoft.VSCode"],
               extensionsDir: ".vscode/extensions", supportDir: "Library/Application Support/Code"),
        Editor(key: "vscode-insiders", name: "VS Code Insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"],
               extensionsDir: ".vscode-insiders/extensions", supportDir: "Library/Application Support/Code - Insiders"),
        Editor(key: "cursor", name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"],
               extensionsDir: ".cursor/extensions", supportDir: "Library/Application Support/Cursor"),
        Editor(key: "vscodium", name: "VSCodium", bundleIDs: ["com.vscodium"],
               extensionsDir: ".vscode-oss/extensions", supportDir: "Library/Application Support/VSCodium"),
        Editor(key: "windsurf", name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"],
               extensionsDir: ".windsurf/extensions", supportDir: "Library/Application Support/Windsurf"),
    ]

    /// Folders in an editor's support folder that it fills again on its own:
    /// downloaded extension installers, compiled script caches, logs and
    /// crash dumps.
    static let editorRegenerating: Set<String> = ["CachedExtensionVSIXs", "CachedData", "logs", "Crashpad"]

    // MARK: - Chromium caches

    /// Cache folders every Chromium or Electron app rebuilds.
    static let chromiumCacheNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnWebGPUCache", "DawnGraphiteCache",
        "GraphiteDawnCache", "ShaderCache", "GrShaderCache",
    ]

    /// What a Chromium profile folder has next to its caches. Two of these
    /// must be there before a folder called "Cache" counts as one.
    static let chromiumMarkers: Set<String> = [
        "Local Storage", "Session Storage", "Network", "Cookies", "Local State", "Preferences", "IndexedDB",
    ]

    // MARK: - Claude

    enum Claude {
        static let desktopBundleIDs = ["com.anthropic.claudefordesktop"]
        static let projects = ".claude/projects"
        static let fileHistory = ".claude/file-history"
        /// Versions installed by Claude Code's own updater.
        static let cliVersions = ".local/share/claude/versions"
        /// The link that says which of them runs.
        static let cliLink = ".local/bin/claude"
        static let support = "Library/Application Support/Claude"
        /// Copies of Claude Code the desktop app keeps, one folder per version.
        static let bundledVersions = [
            "Library/Application Support/Claude/claude-code",
            "Library/Application Support/Claude/claude-code-vm",
        ]
        /// Sessions untouched for this long are listed for review.
        static let sessionIdleDays = 14
    }

    // MARK: - Package manager caches

    struct DevCache: Sendable {
        let tool: String
        let relativePath: String
        /// True when each folder inside is listed on its own.
        var children = false
        /// Folders inside that are left alone.
        var except: Set<String> = []
    }

    /// Download caches no other MacDash tool covers. Their tool fetches the
    /// content again when it is needed.
    static let devCaches: [DevCache] = [
        DevCache(tool: "Bun", relativePath: ".bun/install/cache"),
        DevCache(tool: "Cargo", relativePath: ".cargo/registry/cache"),
        DevCache(tool: "Cargo", relativePath: ".cargo/registry/src"),
        DevCache(tool: "Cargo", relativePath: ".cargo/git/checkouts"),
        DevCache(tool: "Gradle", relativePath: ".gradle/caches"),
        DevCache(tool: "Gradle", relativePath: ".gradle/wrapper/dists"),
        DevCache(tool: "Maven", relativePath: ".m2/repository"),
        DevCache(tool: "CocoaPods", relativePath: ".cocoapods/repos"),
        DevCache(tool: "Dart", relativePath: ".pub-cache/hosted"),
        DevCache(tool: "NuGet", relativePath: ".nuget/packages"),
        DevCache(tool: "Composer", relativePath: ".composer/cache"),
        // Model downloads here belong to Drive Offload; pip is Smart Care's.
        DevCache(tool: ".cache", relativePath: ".cache", children: true,
                 except: ["huggingface", "lm-studio", "torch", "whisper", "pip"]),
    ]

    // MARK: - Folders a project can rebuild

    struct ArtifactRule: Sendable {
        /// Files that must sit next to the folder (any one of them).
        var siblings: [String] = []
        /// Endings one of the neighbors must have, such as ".xcodeproj".
        var siblingSuffixes: [String] = []
        /// Files that must exist inside the folder (any one of them).
        var inside: [String] = []
        /// True when the name alone could be anything ("build", "dist"): the
        /// folder then only counts when the project's git repository ignores
        /// it and tracks nothing in it.
        var needsGit = false
        /// The command that brings it back; nil when the next build does.
        var command: String?

        /// True when the name needs nothing else to count.
        var isSelfEvident: Bool { siblings.isEmpty && siblingSuffixes.isEmpty && inside.isEmpty && !needsGit }
    }

    private static let node = ["package.json"]
    private static let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

    static let artifacts: [String: [ArtifactRule]] = [
        "node_modules": [ArtifactRule(siblings: node, command: "npm install")],
        "bower_components": [ArtifactRule(siblings: ["bower.json"], command: "bower install")],
        ".next": [ArtifactRule(siblings: node)],
        ".nuxt": [ArtifactRule(siblings: node)],
        ".svelte-kit": [ArtifactRule(siblings: node)],
        ".turbo": [ArtifactRule(siblings: node)],
        ".parcel-cache": [ArtifactRule(siblings: node)],
        ".angular": [ArtifactRule(siblings: node)],
        ".expo": [ArtifactRule(siblings: node)],
        ".astro": [ArtifactRule(siblings: node)],
        ".nx": [ArtifactRule(siblings: ["nx.json"])],
        "target": [
            ArtifactRule(siblings: ["Cargo.toml"], command: "cargo build"),
            ArtifactRule(siblings: ["pom.xml"], command: "mvn package"),
            ArtifactRule(needsGit: true),
        ],
        ".build": [ArtifactRule(siblings: ["Package.swift"], command: "swift build")],
        "DerivedData": [
            ArtifactRule(siblings: ["Package.swift"], siblingSuffixes: [".xcodeproj", ".xcworkspace"]),
            ArtifactRule(needsGit: true),
        ],
        "Pods": [ArtifactRule(siblings: ["Podfile"], command: "pod install")],
        ".venv": [ArtifactRule(inside: ["pyvenv.cfg"], command: "python -m venv")],
        "venv": [ArtifactRule(inside: ["pyvenv.cfg"], command: "python -m venv")],
        "env": [ArtifactRule(inside: ["pyvenv.cfg"], command: "python -m venv")],
        ".tox": [ArtifactRule()],
        ".mypy_cache": [ArtifactRule()],
        ".pytest_cache": [ArtifactRule()],
        ".ruff_cache": [ArtifactRule()],
        ".dart_tool": [ArtifactRule(siblings: ["pubspec.yaml"], command: "flutter pub get")],
        ".gradle": [ArtifactRule(siblings: gradle)],
        ".cxx": [ArtifactRule(siblings: gradle)],
        ".zig-cache": [ArtifactRule(siblings: ["build.zig"])],
        "zig-cache": [ArtifactRule(siblings: ["build.zig"])],
        "zig-out": [ArtifactRule(siblings: ["build.zig"])],
        ".terraform": [ArtifactRule(siblingSuffixes: [".tf"], command: "terraform init")],
        "elm-stuff": [ArtifactRule(siblings: ["elm.json"])],
        ".stack-work": [ArtifactRule(siblings: ["stack.yaml"])],
        "dist-newstyle": [ArtifactRule(siblings: ["cabal.project"], siblingSuffixes: [".cabal"])],
        "_build": [ArtifactRule(siblings: ["mix.exs", "dune-project"])],
        "bin": [ArtifactRule(siblingSuffixes: [".csproj", ".fsproj", ".vbproj"], needsGit: true)],
        "obj": [ArtifactRule(siblingSuffixes: [".csproj", ".fsproj", ".vbproj"], needsGit: true)],
        "build": [ArtifactRule(needsGit: true)],
        "dist": [ArtifactRule(needsGit: true)],
        "coverage": [ArtifactRule(needsGit: true)],
        ".output": [ArtifactRule(siblings: node, needsGit: true)],
        "storybook-static": [ArtifactRule(siblings: node, needsGit: true)],
    ]

    /// Names ticked by default once their project has been idle: build output
    /// and dependencies in the strict sense. The rest ("dist", "coverage",
    /// "bin"…) may hold something a person exported, so it waits for a tick.
    static let artifactsSuggestedWhenIdle: Set<String> = [
        "node_modules", "bower_components", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular",
        ".expo", ".astro", ".nx", "target", ".build", "DerivedData", "Pods", ".venv", "venv", ".tox", ".mypy_cache",
        ".pytest_cache", ".ruff_cache", ".dart_tool", ".gradle", ".cxx", ".zig-cache", "zig-cache", "zig-out",
        ".terraform", "elm-stuff", ".stack-work", "dist-newstyle", "_build", "obj", "build",
    ]

    /// A project left alone for this long counts as idle.
    static let idleProjectDays = 30
    /// The same, while the disk is nearly full and space matters more than a rebuild.
    static let idleProjectDaysWhenFull = 7

    /// Home folders where projects are never looked for.
    static let nonProjectRoots: Set<String> = ["Library", "Applications", "Pictures", "Music", "Movies", "Public"]

    /// How deep below the home folder projects are looked for.
    static let projectDepth = 9

    // MARK: - What is read without Full Disk Access

    /// Home folders macOS guards with a prompt of its own (files, photos and
    /// media libraries). Without Full Disk Access they are not opened at all:
    /// an analysis must never make macOS ask for anything.
    static let guardedHomeFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", ".Trash"]

    /// The only Library folders read without Full Disk Access. The rest holds
    /// other apps' data, contacts, calendars and mail, which macOS either
    /// refuses or asks about.
    static let openLibraryFolders: Set<String> = ["Application Support", "Caches", "Logs", "Developer", "pnpm", "Android"]

    /// Application Support folders that belong to protected system data.
    static let guardedSupportFolders: Set<String> = [
        "AddressBook", "CloudDocs", "FileProvider", "MobileSync", "CallHistoryDB", "CallHistoryTransactions", "Knowledge",
    ]

    // MARK: - What may go to the Trash

    enum Rule {
        static let artifact = "artifact"
        static let editorExtension = "editor.extension"
        static let editorData = "editor.data"
        static let editorWorkspace = "editor.workspace"
        static let claudeSession = "claude.session"
        static let claudeHistory = "claude.history"
        static let claudeVersion = "claude.version"
        static let chromiumCache = "chromium.cache"
        static let devCache = "dev.cache"
    }

    /// Home paths nothing below ever leaves, whatever rule asks.
    private static let never: [String] = OffloadSafety.protectedPrefixes + [
        ".aws", ".kube", ".config", ".docker", ".netrc", "Library/Application Support/MacDash",
    ]

    /// True when `path` has exactly the shape `rule` describes. This is the
    /// last word before anything moves: a path from an old or edited report
    /// that doesn't fit its rule is refused, so a report can never be used to
    /// reach other files. `home` and `path` are plain absolute paths.
    static func permits(_ path: String, rule: String, home: String) -> Bool {
        guard (path as NSString).standardizingPath == path, path.hasPrefix(home + "/") else { return false }
        let relative = String(path.dropFirst(home.count + 1))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        for prefix in never where relative == prefix || relative.hasPrefix(prefix + "/") { return false }
        guard let name = parts.last else { return false }
        let parent = parts.dropLast().joined(separator: "/")

        switch rule {
        case Rule.artifact:
            guard parts.count >= 2, parts.count <= projectDepth + 1, artifacts[name] != nil else { return false }
            let top = parts[0]
            return !top.hasPrefix(".") && !nonProjectRoots.contains(top)
        case Rule.editorExtension:
            return editors.contains { $0.extensionsDir == parent } && !name.hasPrefix(".") && name != "extensions.json"
        case Rule.editorData:
            return editors.contains { $0.supportDir == parent } && editorRegenerating.contains(name)
        case Rule.editorWorkspace:
            return editors.contains { $0.supportDir + "/User/workspaceStorage" == parent }
        case Rule.claudeSession:
            guard parts.count == 4, parts[0] == ".claude", parts[1] == "projects", name != "memory" else { return false }
            return name.hasSuffix(".jsonl") || UUID(uuidString: name) != nil
        case Rule.claudeHistory:
            return parent == Claude.fileHistory
        case Rule.claudeVersion:
            return parent == Claude.cliVersions || Claude.bundledVersions.contains(parent)
        case Rule.chromiumCache:
            return parts.count == 4 && parts[0] == "Library" && parts[1] == "Application Support"
                && chromiumCacheNames.contains(name)
        case Rule.devCache:
            return devCaches.contains { cache in
                cache.children
                    ? cache.relativePath == parent && !cache.except.contains(name) && !name.hasPrefix(".")
                    : cache.relativePath == relative
            }
        default:
            return false
        }
    }

    // MARK: - Versions

    /// Splits "publisher.name-1.2.3-darwin-arm64" into its identifier and
    /// version numbers. Nil when the name has no version.
    static func extensionIdentity(_ folder: String) -> (id: String, version: [Int])? {
        let pieces = folder.split(separator: "-").map(String.init)
        guard let index = pieces.firstIndex(where: { piece in
            let numbers = piece.split(separator: ".")
            return numbers.count >= 2 && numbers.allSatisfy { Int($0) != nil }
        }), index > 0 else { return nil }
        let id = pieces[..<index].joined(separator: "-").lowercased()
        return (id, versionNumbers(pieces[index]))
    }

    static func versionNumbers(_ text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// True when `a` is an older version than `b`.
    static func isOlder(_ a: [Int], than b: [Int]) -> Bool {
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// The folder name Claude Code uses for a project's sessions: the
    /// project's path with everything but letters and digits turned into "-".
    static func claudeProjectFolder(for path: String) -> String {
        String(path.unicodeScalars.map { scalar in
            (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))) ? Character(scalar) : "-"
        })
    }
}
