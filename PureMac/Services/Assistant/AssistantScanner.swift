import Darwin
import Foundation

/// Set from the main thread to stop an analysis; read by the worker threads.
final class AssistantCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// Everything one analysis measured, before any of it is interpreted. Plain
/// facts only: the wording and the verdicts come from `AssistantRules`.
struct AssistantFacts: Sendable {
    /// A file or folder with what identified it when it was measured.
    struct Measured: Sendable {
        let path: String
        var label: String
        var size: Int64
        let fileID: UInt64?
        let modified: Date?
        let isDirectory: Bool
    }

    /// A folder its project can rebuild.
    struct Artifact: Sendable {
        var item: Measured
        let name: String
        let project: String
        /// Last sign of work on the project; nil when nothing could tell.
        let lastActivity: Date?
        let command: String?
    }

    struct EditorFacts: Sendable {
        let key: String
        let name: String
        let bundleIDs: [String]
        var oldExtensions: [Measured] = []
        var regenerating: [Measured] = []
        var caches: [Measured] = []
        var orphanWorkspaces: [Measured] = []
    }

    struct Session: Sendable {
        var item: Measured
        let project: String
        /// True when the project's folder no longer exists.
        let orphaned: Bool
    }

    struct ClaudeFacts: Sendable {
        var oldVersions: [Measured] = []
        var sessions: [Session] = []
        var history: [Measured] = []
        var desktopCaches: [Measured] = []
        var sessionsTotal: Int64 = 0
    }

    struct App: Sendable {
        let path: String
        let name: String
        let bundleID: String
        let size: Int64
        let lastUsed: Date?
        let isRunning: Bool
    }

    var home: String
    var now = Date()
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    /// Sizes of the folders the walk kept, by path.
    var sizes: [String: Int64] = [:]
    var filesChecked = 0
    /// True when folders were skipped for lack of Full Disk Access.
    var limitedAccess = false
    var artifacts: [Artifact] = []
    var editors: [EditorFacts] = []
    var claude = ClaudeFacts()
    var chromiumCaches: [Measured] = []
    var devCaches: [Measured] = []
    /// Folders Drive Offload knows how to move.
    var offload: [Measured] = []
    var apps: [App] = []
    var applicationsTotal: Int64 = 0
    var unusedMonths = 6

    func size(_ relative: String) -> Int64 { sizes[home + "/" + relative] ?? 0 }
}

enum AssistantStep: String, CaseIterable, Sendable {
    case disk
    case folders
    case projects
    case tools
    case apps
    case verdict

    var title: String {
        switch self {
        case .disk: return String(localized: "Reading the disk")
        case .folders: return String(localized: "Measuring your folders")
        case .projects: return String(localized: "Checking projects and build folders")
        case .tools: return String(localized: "Checking VS Code, Claude and developer tools")
        case .apps: return String(localized: "Checking applications")
        case .verdict: return String(localized: "Working out what to recommend")
        }
    }

    var symbol: String {
        switch self {
        case .disk: return "internaldrive.fill"
        case .folders: return "folder.fill"
        case .projects: return "hammer.fill"
        case .tools: return "chevron.left.forwardslash.chevron.right"
        case .apps: return "square.grid.2x2.fill"
        case .verdict: return "checklist"
        }
    }
}

// MARK: - One pass over the home folder

/// Measures a folder tree once. On the way it keeps the size of every folder
/// near the top (and of the deeper ones the catalog asks for) and notes the
/// folders that look like something a project can rebuild. Memory stays
/// small: sizes are kept for a few thousand folders, not for every file.
final class AssistantTreeWalk: @unchecked Sendable {
    struct Candidate: Sendable {
        let path: String
        let name: String
        var size: Int64
        /// True when only git can say whether the folder is build output.
        let needsGit: Bool
        let command: String?
    }

    private let root: String
    private let device: Int32?
    private let skip: Set<String>
    private let tracked: Set<String>
    private let expand: Set<String>
    private let appSupport: String
    private let cancel: AssistantCancelFlag
    private let onFolder: @Sendable (String) -> Void

    private let lock = NSLock()
    private(set) var sizes: [String: Int64] = [:]
    private(set) var candidates: [Candidate] = []
    private(set) var files = 0

    /// Folders this close to the root always have their size kept.
    static let keepDepth = 3
    private static let packageEndings = [
        ".app", ".framework", ".bundle", ".xcodeproj", ".xcworkspace", ".photoslibrary", ".fcpbundle", ".logicx",
        ".band", ".imovielibrary", ".tvlibrary", ".musiclibrary", ".sparsebundle",
    ]

    init(
        root: String,
        skip: Set<String>,
        tracked: Set<String>,
        expand: Set<String>,
        cancel: AssistantCancelFlag,
        onFolder: @escaping @Sendable (String) -> Void
    ) {
        self.root = root
        self.skip = skip
        self.tracked = tracked
        self.expand = expand
        self.cancel = cancel
        self.onFolder = onFolder
        device = DirectoryLister.device(of: root)
        appSupport = root + "/Library/Application Support/"
    }

    @discardableResult
    func run() -> Int64 {
        let total = walk(root, depth: 0, detect: false)
        lock.lock(); sizes[root] = total; lock.unlock()
        return total
    }

    private func walk(_ path: String, depth: Int, detect: Bool) -> Int64 {
        if cancel.isCancelled { return 0 }
        guard let entries = DirectoryLister.list(path) else { return 0 }

        var total: Int64 = 0
        var fileCount = 0
        var folders: [String] = []
        for entry in entries {
            switch entry.kind {
            case .file:
                total += entry.allocated
                fileCount += 1
            case .directory:
                // Another volume, or a cloud folder whose listing lives online.
                guard device == nil || entry.device == device, !entry.isDataless else { continue }
                folders.append(entry.name)
            default:
                break
            }
        }
        if fileCount > 0 {
            lock.lock(); files += fileCount; lock.unlock()
        }
        guard !folders.isEmpty else { return total }

        let keepChildren = depth < Self.keepDepth || expand.contains(path)
            || (depth == Self.keepDepth && path.hasPrefix(appSupport))
        // Neighbors are only gathered when a folder here might be build output.
        var neighbors: Set<String>?
        struct Child {
            let path: String
            let detect: Bool
            let keep: Bool
            var candidate: Candidate?
        }
        var children: [Child] = []
        children.reserveCapacity(folders.count)

        for name in folders {
            let child = path + "/" + name
            if skip.contains(child) { continue }
            var childDetect: Bool
            if depth == 0 {
                childDetect = !name.hasPrefix(".") && !AssistantCatalog.nonProjectRoots.contains(name)
            } else {
                childDetect = detect && depth + 1 < AssistantCatalog.projectDepth && !name.hasPrefix(".")
                    && !Self.packageEndings.contains { name.hasSuffix($0) }
            }
            var candidate: Candidate?
            if detect, let rules = AssistantCatalog.artifacts[name] {
                if neighbors == nil { neighbors = Set(entries.map(\.name)) }
                candidate = Self.match(rules, name: name, path: child, neighbors: neighbors ?? [])
                if candidate != nil { childDetect = false }
            }
            children.append(Child(
                path: child, detect: childDetect,
                keep: keepChildren || candidate != nil || tracked.contains(child),
                candidate: candidate
            ))
        }
        guard !children.isEmpty else { return total }

        var childSizes = [Int64](repeating: 0, count: children.count)
        if depth <= 2, children.count > 1 {
            childSizes.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                let list = children
                DispatchQueue.concurrentPerform(iterations: list.count) { index in
                    if depth <= 1 { self.onFolder(list[index].path) }
                    (base + index).pointee = self.walk(list[index].path, depth: depth + 1, detect: list[index].detect)
                }
            }
        } else {
            for (index, child) in children.enumerated() {
                childSizes[index] = walk(child.path, depth: depth + 1, detect: child.detect)
            }
        }

        var kept: [(String, Int64)] = []
        var found: [Candidate] = []
        for (index, child) in children.enumerated() {
            total += childSizes[index]
            if child.keep { kept.append((child.path, childSizes[index])) }
            if var candidate = child.candidate {
                candidate.size = childSizes[index]
                found.append(candidate)
            }
        }
        if !kept.isEmpty || !found.isEmpty {
            lock.lock()
            for (keptPath, size) in kept { sizes[keptPath] = size }
            candidates.append(contentsOf: found)
            lock.unlock()
        }
        return total
    }

    /// The first rule whose files are in place. A rule that needs nothing
    /// from git wins over one that does.
    static func match(_ rules: [AssistantCatalog.ArtifactRule], name: String, path: String, neighbors: Set<String>) -> Candidate? {
        var viaGit: AssistantCatalog.ArtifactRule?
        for rule in rules {
            let siblingsRequired = !rule.siblings.isEmpty || !rule.siblingSuffixes.isEmpty
            let siblingsFound = rule.siblings.contains(where: neighbors.contains)
                || rule.siblingSuffixes.contains { suffix in neighbors.contains { $0.hasSuffix(suffix) } }
            if siblingsRequired, !siblingsFound { continue }
            if !rule.inside.isEmpty, !rule.inside.contains(where: { FileManager.default.fileExists(atPath: path + "/" + $0) }) {
                continue
            }
            if rule.needsGit {
                if viaGit == nil { viaGit = rule }
                continue
            }
            return Candidate(path: path, name: name, size: 0, needsGit: false, command: rule.command)
        }
        return viaGit.map { Candidate(path: path, name: name, size: 0, needsGit: true, command: $0.command) }
    }
}

// MARK: - Scanner

enum AssistantScanner {
    struct Options: Sendable {
        var home: String
        var applicationRoots: [String]
        var fullDiskAccess: Bool
        /// Paths of the apps running now.
        var runningAppPaths: Set<String>
        var unusedMonths: Int
        var now = Date()
        /// More folders to leave unread.
        var alsoSkip: Set<String> = []
    }

    /// Runs every measurement. Returns nil when cancelled.
    static func gather(
        _ options: Options,
        cancel: AssistantCancelFlag,
        progress: @escaping @Sendable (AssistantStep, String) -> Void
    ) -> AssistantFacts? {
        let home = options.home
        var facts = AssistantFacts(home: home, now: options.now)
        facts.unusedMonths = options.unusedMonths

        progress(.disk, "")
        if let space = DirectoryLister.volumeSpace(home) {
            facts.diskTotal = space.total
            facts.diskFree = space.available
        }

        // Cloud storage is never listed: reading it would fetch folder
        // listings from the network. Without Full Disk Access, everything
        // macOS guards is left out too, so nothing can raise a prompt.
        var skip = options.alsoSkip.union([home + "/Library/CloudStorage"])
        if !options.fullDiskAccess {
            facts.limitedAccess = true
            skip.formUnion(guardedPaths(home: home))
        }

        progress(.folders, "")
        let walk = AssistantTreeWalk(
            root: home, skip: skip, tracked: trackedPaths(home: home), expand: expandedPaths(home: home), cancel: cancel
        ) { path in progress(.folders, path) }
        walk.run()
        guard !cancel.isCancelled else { return nil }
        facts.sizes = walk.sizes
        facts.filesChecked = walk.files

        progress(.projects, "")
        facts.artifacts = artifacts(from: walk.candidates, home: home, now: options.now, cancel: cancel) { progress(.projects, $0) }
        guard !cancel.isCancelled else { return nil }

        progress(.tools, "")
        let sizes = facts.sizes
        facts.editors = AssistantCatalog.editors.compactMap { editorFacts($0, home: home, sizes: sizes) }
        facts.claude = claudeFacts(home: home, sizes: sizes, now: options.now)
        facts.chromiumCaches = chromiumCaches(home: home, sizes: sizes)
        facts.devCaches = devCaches(home: home, sizes: sizes)
        facts.offload = offloadFolders(home: home, sizes: sizes)
        guard !cancel.isCancelled else { return nil }

        progress(.apps, "")
        facts.apps = apps(roots: options.applicationRoots, running: options.runningAppPaths, cancel: cancel)
        facts.applicationsTotal = facts.apps.reduce(0) { $0 + $1.size }
        guard !cancel.isCancelled else { return nil }

        progress(.verdict, "")
        return facts
    }

    /// What stays unread without Full Disk Access: the guarded home folders,
    /// every Library folder that isn't known to be open, and the protected
    /// corners of Application Support.
    static func guardedPaths(home: String) -> Set<String> {
        let fileManager = FileManager.default
        var paths = Set(AssistantCatalog.guardedHomeFolders.map { home + "/" + $0 })
        let library = home + "/Library"
        for name in (try? fileManager.contentsOfDirectory(atPath: library)) ?? []
        where !AssistantCatalog.openLibraryFolders.contains(name) {
            paths.insert(library + "/" + name)
        }
        let support = library + "/Application Support"
        for name in (try? fileManager.contentsOfDirectory(atPath: support)) ?? []
        where AssistantCatalog.guardedSupportFolders.contains(name) || name.hasPrefix("com.apple.") {
            paths.insert(support + "/" + name)
        }
        return paths
    }

    // MARK: Which deeper folders keep their size

    /// Folders below the usual depth whose size the rules ask for.
    static func trackedPaths(home: String) -> Set<String> {
        var paths = Set(DriveOffloadCatalog.entries.map { home + "/" + $0.relativePath })
        for cache in AssistantCatalog.devCaches { paths.insert(home + "/" + cache.relativePath) }
        return paths
    }

    /// Folders whose direct children keep their size, wherever they sit.
    static func expandedPaths(home: String) -> Set<String> {
        var paths: Set<String> = [home + "/" + AssistantCatalog.Claude.cliVersions]
        for folder in AssistantCatalog.Claude.bundledVersions { paths.insert(home + "/" + folder) }
        for editor in AssistantCatalog.editors {
            paths.insert(home + "/" + editor.supportDir + "/User/workspaceStorage")
        }
        return paths
    }

    // MARK: Identity

    struct Identity: Sendable {
        let fileID: UInt64
        let modified: Date
        let isDirectory: Bool
        let isLink: Bool
        let size: Int64
    }

    /// What `lstat` says about a path; nil when nothing is there.
    static func identity(of path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return Identity(
            fileID: UInt64(info.st_ino), modified: modified, isDirectory: type == S_IFDIR, isLink: type == S_IFLNK,
            size: Int64(info.st_blocks) * 512
        )
    }

    /// A measured item at `path`, sized from the walk when it kept the folder.
    /// Nil for missing paths and for links, which are never followed.
    static func measured(_ path: String, label: String, sizes: [String: Int64]) -> AssistantFacts.Measured? {
        guard let identity = identity(of: path), !identity.isLink else { return nil }
        let size = identity.isDirectory ? (sizes[path] ?? AppFootprintScanner.measure(path)) : identity.size
        return AssistantFacts.Measured(
            path: path, label: label, size: size, fileID: identity.fileID, modified: identity.modified,
            isDirectory: identity.isDirectory
        )
    }

    private static func folderNames(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: Projects

    /// Keeps the candidates that really are build output, and works out when
    /// each project was last touched.
    static func artifacts(
        from candidates: [AssistantTreeWalk.Candidate],
        home: String,
        now: Date,
        git: String? = gitPath(),
        cancel: AssistantCancelFlag,
        onProject: (String) -> Void = { _ in }
    ) -> [AssistantFacts.Artifact] {
        let minimum: Int64 = 20_000_000
        let candidates = candidates.filter { $0.size >= minimum }
        var repositories: [String: String?] = [:]
        func repository(for folder: String) -> String? {
            if let known = repositories[folder] { return known }
            var current = folder
            var found: String?
            while current.hasPrefix(home + "/") {
                if FileManager.default.fileExists(atPath: current + "/.git") { found = current; break }
                current = (current as NSString).deletingLastPathComponent
            }
            repositories[folder] = found
            return found
        }

        // One pair of git calls per repository.
        var byRepository: [String: [AssistantTreeWalk.Candidate]] = [:]
        var accepted: [(candidate: AssistantTreeWalk.Candidate, repository: String?)] = []
        for candidate in candidates {
            let parent = (candidate.path as NSString).deletingLastPathComponent
            if let repo = repository(for: parent) {
                byRepository[repo, default: []].append(candidate)
            } else if !candidate.needsGit {
                accepted.append((candidate, nil))
            }
        }
        for (repo, list) in byRepository.sorted(by: { $0.key < $1.key }) {
            if cancel.isCancelled { return [] }
            onProject(repo)
            guard let git else {
                accepted += list.filter { !$0.needsGit }.map { ($0, repo) }
                continue
            }
            let verdict = gitVerdict(git: git, repository: repo, paths: list.map(\.path))
            for candidate in list {
                guard !verdict.tracked.contains(candidate.path) else { continue }
                if candidate.needsGit, !verdict.ignored.contains(candidate.path) { continue }
                accepted.append((candidate, repo))
            }
        }

        var activity: [String: Date?] = [:]
        return accepted.compactMap { candidate, repo in
            let parent = (candidate.path as NSString).deletingLastPathComponent
            let project = projectRoot(for: parent, repository: repo, home: home)
            guard let identity = identity(of: candidate.path), identity.isDirectory else { return nil }
            let last: Date?
            if let known = activity[project] {
                last = known
            } else {
                last = lastActivity(project: project, isRepository: repo != nil, home: home)
                activity[project] = last
            }
            let projectName = displayName(of: project, home: home)
            let inside = String(candidate.path.dropFirst(project.count + 1))
            return AssistantFacts.Artifact(
                item: AssistantFacts.Measured(
                    path: candidate.path, label: projectName + " › " + inside, size: candidate.size,
                    fileID: identity.fileID, modified: identity.modified, isDirectory: true
                ),
                name: candidate.name, project: project, lastActivity: last, command: candidate.command
            )
        }
        .sorted { $0.item.size > $1.item.size }
    }

    /// Whether one folder is still build output right now: the same checks
    /// the analysis made, repeated before anything moves.
    static func isStillArtifact(_ path: String, home: String, git: String? = gitPath()) -> Bool {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        guard let rules = AssistantCatalog.artifacts[name] else { return false }
        let neighbors = Set((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [])
        guard let candidate = AssistantTreeWalk.match(rules, name: name, path: path, neighbors: neighbors) else { return false }
        var repo: String?
        var current = parent
        while current.hasPrefix(home + "/") {
            if FileManager.default.fileExists(atPath: current + "/.git") { repo = current; break }
            current = (current as NSString).deletingLastPathComponent
        }
        guard let repo else { return !candidate.needsGit }
        guard let git else { return !candidate.needsGit }
        let verdict = gitVerdict(git: git, repository: repo, paths: [path])
        if verdict.tracked.contains(path) { return false }
        return !candidate.needsGit || verdict.ignored.contains(path)
    }

    /// A git that is really installed. `/usr/bin/git` alone is a stub that
    /// raises the "install developer tools" dialog, so it is only used when a
    /// developer folder is selected.
    static func gitPath() -> String? {
        let fixed = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        if let found = fixed.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let selected = Shell.run("/usr/bin/xcode-select", ["-p"])
        guard selected.status == 0,
              let folder = String(data: selected.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty else { return nil }
        let path = folder + "/usr/bin/git"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Which of `paths` the repository ignores, and which hold files it tracks.
    static func gitVerdict(git: String, repository: String, paths: [String]) -> (ignored: Set<String>, tracked: Set<String>) {
        var ignored = Set<String>()
        var tracked = Set<String>()
        let relative = paths.map { String($0.dropFirst(repository.count + 1)) }
        for start in stride(from: 0, to: relative.count, by: 64) {
            let chunk = Array(relative[start..<min(start + 64, relative.count)])
            // Names go in on standard input, separated by NUL, so no name can be misread.
            let input = Data(chunk.joined(separator: "\u{0}").utf8) + Data([0])
            let check = runGit(git, repository: repository, ["check-ignore", "-z", "--stdin"], input: input)
            for item in check.split(separator: 0) {
                let name = String(decoding: item, as: UTF8.self)
                ignored.insert(repository + "/" + name)
            }
            let files = runGit(git, repository: repository, ["--literal-pathspecs", "ls-files", "-z", "--"] + chunk)
            for item in files.split(separator: 0) {
                let file = String(decoding: item, as: UTF8.self)
                for name in chunk where file == name || file.hasPrefix(name + "/") {
                    tracked.insert(repository + "/" + name)
                }
            }
        }
        return (ignored, tracked)
    }

    /// Runs a read-only git command. The repository's own settings can't make
    /// it run anything else: its file monitor hook is switched off and it
    /// never waits for a password.
    private static func runGit(_ git: String, repository: String, _ arguments: [String], input: Data? = nil) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        // Options that apply to git itself come before the command.
        let global = arguments.prefix { $0.hasPrefix("--") }
        process.arguments = ["-C", repository, "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"]
            + global + arguments.dropFirst(global.count)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let inputPipe = input == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        if let input, let inputPipe {
            // A few kilobytes at most, well under what a pipe holds.
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    /// Folder names that say nothing about which project they belong to.
    private static let genericFolders: Set<String> = [
        "source", "src", "app", "apps", "web", "client", "server", "frontend", "backend", "native", "macos", "ios",
        "android", "windows", "linux", "core", "packages", "platforms", "desktop", "mobile", "code", "project",
    ]

    /// The folder a build folder's project is known by: its git repository,
    /// or else the nearest folder above it with a name of its own
    /// ("Skykeep" rather than "Skykeep/source").
    static func projectRoot(for parent: String, repository: String?, home: String) -> String {
        if let repository { return repository }
        var current = parent
        while genericFolders.contains((current as NSString).lastPathComponent.lowercased()) {
            let above = (current as NSString).deletingLastPathComponent
            // Never climb to a top-level folder such as Documents, or out of the home folder.
            guard above.hasPrefix(home + "/"), (above as NSString).deletingLastPathComponent != home else { break }
            current = above
        }
        return current
    }

    /// A project's name as shown; a folder with a generic name borrows the
    /// one above it ("Skykeep/source").
    static func displayName(of project: String, home: String) -> String {
        let name = (project as NSString).lastPathComponent
        let above = (project as NSString).deletingLastPathComponent
        guard genericFolders.contains(name.lowercased()), above.hasPrefix(home + "/"),
              (above as NSString).deletingLastPathComponent != home else { return name }
        return (above as NSString).lastPathComponent + "/" + name
    }

    /// The latest sign of work on a project: its git index and history, the
    /// files at its top (build folders aside) and its Claude Code sessions.
    static func lastActivity(project: String, isRepository: Bool, home: String) -> Date? {
        var dates: [Date] = []
        if isRepository {
            for file in [".git/index", ".git/HEAD", ".git/logs/HEAD", ".git/FETCH_HEAD"] {
                if let identity = identity(of: project + "/" + file) { dates.append(identity.modified) }
            }
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: project)) ?? []
        for name in entries.prefix(400) where AssistantCatalog.artifacts[name] == nil && name != ".DS_Store" && name != ".git" {
            if let identity = identity(of: project + "/" + name) { dates.append(identity.modified) }
        }
        let sessions = home + "/" + AssistantCatalog.Claude.projects + "/" + AssistantCatalog.claudeProjectFolder(for: project)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: sessions) {
            for name in files where name.hasSuffix(".jsonl") {
                if let identity = identity(of: sessions + "/" + name) { dates.append(identity.modified) }
            }
        }
        return dates.max()
    }

    // MARK: Editors

    static func editorFacts(_ editor: AssistantCatalog.Editor, home: String, sizes: [String: Int64]) -> AssistantFacts.EditorFacts? {
        let extensions = home + "/" + editor.extensionsDir
        let support = home + "/" + editor.supportDir
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: extensions) || fileManager.fileExists(atPath: support) else { return nil }
        var facts = AssistantFacts.EditorFacts(key: editor.key, name: editor.name, bundleIDs: editor.bundleIDs)

        for name in obsoleteExtensions(in: extensions) {
            if let item = measured(extensions + "/" + name, label: name, sizes: sizes), item.isDirectory {
                facts.oldExtensions.append(item)
            }
        }
        for name in AssistantCatalog.editorRegenerating.sorted() {
            if let item = measured(support + "/" + name, label: editor.name + " · " + name, sizes: sizes), item.isDirectory {
                facts.regenerating.append(item)
            }
        }
        for name in AssistantCatalog.chromiumCacheNames.sorted() {
            if let item = measured(support + "/" + name, label: editor.name + " · " + name, sizes: sizes), item.isDirectory {
                facts.caches.append(item)
            }
        }
        let storage = support + "/User/workspaceStorage"
        for name in folderNames(storage) {
            let folder = storage + "/" + name
            guard let project = workspaceFolder(in: folder), !fileManager.fileExists(atPath: project) else { continue }
            if let item = measured(folder, label: (project as NSString).lastPathComponent, sizes: sizes), item.isDirectory {
                facts.orphanWorkspaces.append(item)
            }
        }
        return facts
    }

    /// Extension folders the editor no longer uses: a newer version of the
    /// same extension sits next to them, and the editor's own list doesn't
    /// name them.
    static func obsoleteExtensions(in folder: String) -> [String] {
        let names = folderNames(folder)
        var referenced: Set<String>?
        if let data = FileManager.default.contents(atPath: folder + "/extensions.json"),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var found = Set<String>()
            for entry in list {
                if let location = entry["relativeLocation"] as? String { found.insert(location) }
                if let location = entry["location"] as? [String: Any], let path = location["path"] as? String {
                    found.insert((path as NSString).lastPathComponent)
                }
            }
            referenced = found
        }
        var newest: [String: [Int]] = [:]
        var identities: [String: (id: String, version: [Int])] = [:]
        for name in names {
            guard let identity = AssistantCatalog.extensionIdentity(name) else { continue }
            identities[name] = identity
            if let current = newest[identity.id], !AssistantCatalog.isOlder(current, than: identity.version) { continue }
            newest[identity.id] = identity.version
        }
        return names.filter { name in
            guard let identity = identities[name], let top = newest[identity.id],
                  AssistantCatalog.isOlder(identity.version, than: top) else { return false }
            return !(referenced?.contains(name) ?? false)
        }
    }

    /// The local folder a workspace storage entry belongs to; nil for remote
    /// workspaces and entries that don't say.
    static func workspaceFolder(in storage: String) -> String? {
        guard let data = FileManager.default.contents(atPath: storage + "/workspace.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (object["folder"] ?? object["workspace"]) as? String,
              let url = URL(string: text), url.isFileURL else { return nil }
        return url.path
    }

    // MARK: Claude

    static func claudeFacts(home: String, sizes: [String: Int64], now: Date) -> AssistantFacts.ClaudeFacts {
        var facts = AssistantFacts.ClaudeFacts()
        let fileManager = FileManager.default

        // Versions: the newest stays, and so does the one the `claude` command runs.
        let versions = home + "/" + AssistantCatalog.Claude.cliVersions
        let inUse = (try? fileManager.destinationOfSymbolicLink(atPath: home + "/" + AssistantCatalog.Claude.cliLink))
            .map { ($0 as NSString).lastPathComponent }
        for name in olderVersions(in: versions, keeping: inUse) {
            if let item = measured(versions + "/" + name, label: "Claude Code " + name, sizes: sizes) { facts.oldVersions.append(item) }
        }
        for folder in AssistantCatalog.Claude.bundledVersions {
            let path = home + "/" + folder
            for name in olderVersions(in: path, keeping: nil) {
                let label = (folder as NSString).lastPathComponent + " " + name
                if let item = measured(path + "/" + name, label: label, sizes: sizes) { facts.oldVersions.append(item) }
            }
        }

        // Sessions: one folder per project, one file (and sometimes one folder) per session.
        let projects = home + "/" + AssistantCatalog.Claude.projects
        facts.sessionsTotal = sizes[projects] ?? 0
        let cutoff = now.addingTimeInterval(-Double(AssistantCatalog.Claude.sessionIdleDays) * 86_400)
        for folder in folderNames(projects) {
            let path = projects + "/" + folder
            let names = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
            let sessions = names.filter { $0.hasSuffix(".jsonl") }
            guard !sessions.isEmpty else { continue }
            let origin = sessions.lazy.compactMap { sessionFolder(in: path + "/" + $0) }.first
            let orphaned = origin.map { !fileManager.fileExists(atPath: $0) } ?? false
            let project = origin.map { ($0 as NSString).lastPathComponent } ?? folder
            for name in names where name.hasSuffix(".jsonl") || UUID(uuidString: name) != nil {
                guard let item = measured(path + "/" + name, label: project, sizes: sizes),
                      let modified = item.modified, orphaned || modified < cutoff else { continue }
                facts.sessions.append(AssistantFacts.Session(item: item, project: project, orphaned: orphaned))
            }
        }

        let history = home + "/" + AssistantCatalog.Claude.fileHistory
        for name in folderNames(history) {
            guard let item = measured(history + "/" + name, label: name, sizes: sizes),
                  let modified = item.modified, modified < cutoff else { continue }
            facts.history.append(item)
        }

        let support = home + "/" + AssistantCatalog.Claude.support
        for name in AssistantCatalog.chromiumCacheNames.sorted() {
            if let item = measured(support + "/" + name, label: "Claude · " + name, sizes: sizes), item.isDirectory {
                facts.desktopCaches.append(item)
            }
        }
        return facts
    }

    /// Version entries in `folder` older than the newest, leaving out `keeping`.
    static func olderVersions(in folder: String, keeping: String?) -> [String] {
        let names = folderNames(folder).filter { !AssistantCatalog.versionNumbers($0).isEmpty }
        guard let newest = names.max(by: { AssistantCatalog.isOlder(AssistantCatalog.versionNumbers($0), than: AssistantCatalog.versionNumbers($1)) })
        else { return [] }
        return names.filter { $0 != newest && $0 != keeping }
    }

    /// The folder a Claude Code session ran in, read from the start of its file.
    static func sessionFolder(in file: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32 * 1024), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "\"cwd\":\"") else { return nil }
        var raw = ""
        var escaped = false
        for character in text[start.upperBound...] {
            if escaped { raw.append(character); escaped = false; continue }
            if character == "\\" { raw.append(character); escaped = true; continue }
            if character == "\"" { break }
            raw.append(character)
        }
        guard let json = "\"\(raw)\"".data(using: .utf8),
              let path = try? JSONDecoder().decode(String.self, from: json), path.hasPrefix("/") else { return nil }
        return path
    }

    // MARK: Caches

    /// Chromium cache folders of other apps in Application Support, found in
    /// the sizes the walk kept.
    static func chromiumCaches(home: String, sizes: [String: Int64]) -> [AssistantFacts.Measured] {
        let root = home + "/Library/Application Support/"
        let own = Set(AssistantCatalog.editors.map { home + "/" + $0.supportDir } + [home + "/" + AssistantCatalog.Claude.support])
        let minimum: Int64 = 20_000_000
        var markerCounts: [String: Int] = [:]
        var found: [AssistantFacts.Measured] = []
        for (path, size) in sizes where size >= minimum && path.hasPrefix(root) {
            let name = (path as NSString).lastPathComponent
            guard AssistantCatalog.chromiumCacheNames.contains(name) else { continue }
            let app = (path as NSString).deletingLastPathComponent
            guard !own.contains(app), (app as NSString).deletingLastPathComponent + "/" == root else { continue }
            let markers = markerCounts[app] ?? AssistantCatalog.chromiumMarkers.filter {
                FileManager.default.fileExists(atPath: app + "/" + $0)
            }.count
            markerCounts[app] = markers
            guard markers >= 2 else { continue }
            let label = (app as NSString).lastPathComponent + " · " + name
            if let item = measured(path, label: label, sizes: sizes), item.isDirectory { found.append(item) }
        }
        return found.sorted { $0.size > $1.size }
    }

    static func devCaches(home: String, sizes: [String: Int64]) -> [AssistantFacts.Measured] {
        let minimum: Int64 = 20_000_000
        var found: [AssistantFacts.Measured] = []
        for cache in AssistantCatalog.devCaches {
            let path = home + "/" + cache.relativePath
            if cache.children {
                for name in folderNames(path) where !cache.except.contains(name) {
                    if let item = measured(path + "/" + name, label: cache.tool + " · " + name, sizes: sizes),
                       item.isDirectory, item.size >= minimum { found.append(item) }
                }
            } else {
                let tail = cache.relativePath.split(separator: "/").dropFirst().joined(separator: "/")
                if let item = measured(path, label: cache.tool + " · " + tail, sizes: sizes), item.isDirectory, item.size >= minimum {
                    found.append(item)
                }
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    /// Large folders Drive Offload can move (AI models, simulators, backups).
    static func offloadFolders(home: String, sizes: [String: Int64]) -> [AssistantFacts.Measured] {
        DriveOffloadCatalog.entries
            .filter { $0.advice == .move && $0.id != "downloads" && $0.id != "movies" }
            .compactMap { entry in
                let path = home + "/" + entry.relativePath
                guard let size = sizes[path], size > 0 else { return nil }
                return measured(path, label: entry.title, sizes: sizes)
            }
            .sorted { $0.size > $1.size }
    }

    // MARK: Applications

    static func apps(roots: [String], running: Set<String>, cancel: AssistantCancelFlag) -> [AssistantFacts.App] {
        let fileManager = FileManager.default
        var bundles: [String] = []
        for root in roots {
            for entry in folderNames(root) {
                let path = root + "/" + entry
                if entry.hasSuffix(".app") {
                    bundles.append(path)
                } else if let inner = try? fileManager.contentsOfDirectory(atPath: path) {
                    bundles += inner.filter { $0.hasSuffix(".app") }.map { path + "/" + $0 }
                }
            }
        }
        var results = [AssistantFacts.App?](repeating: nil, count: bundles.count)
        let own = Bundle.main.bundleIdentifier ?? ""
        results.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            let list = bundles
            DispatchQueue.concurrentPerform(iterations: list.count) { index in
                if cancel.isCancelled { return }
                let path = list[index]
                let url = URL(fileURLWithPath: path)
                guard let identity = identity(of: path), !identity.isLink,
                      let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, bundleID != own else { return }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                (base + index).pointee = AssistantFacts.App(
                    path: path, name: name, bundleID: bundleID, size: AppFootprintScanner.measure(path),
                    lastUsed: UnusedAppsFinder.spotlightLastUsed(at: url),
                    isRunning: running.contains(url.resolvingSymlinksInPath().path)
                )
            }
        }
        return results.compactMap { $0 }.sorted { $0.size > $1.size }
    }
}
