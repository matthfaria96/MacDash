import Darwin
import Foundation

/// Walks the scope of a scan mode and applies `AntivirusRules`. It only
/// reads: every detection comes back to the UI as pending, and nothing is
/// moved, unloaded or stopped here.
struct AntivirusScanner: Sendable {
    struct Trust: Sendable {
        var hashes: Set<String> = []
        var paths: Set<String> = []
        var teamIDs: Set<String> = []

        init(rules: [TrustRule]) {
            for rule in rules {
                switch rule.kind {
                case .hash: hashes.insert(rule.value)
                case .path: paths.insert(rule.value)
                case .teamID: teamIDs.insert(rule.value)
                }
            }
        }

        func covers(path: String) -> Bool {
            paths.contains(path) || paths.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }

    let home: String
    let quarantineFolder: String

    init(home: String = NSHomeDirectory(), quarantineFolder: String) {
        self.home = home
        self.quarantineFolder = quarantineFolder
    }

    // MARK: Scope

    /// Folders walked for each mode, measured on the reference scanner.
    func roots(for mode: AntivirusScanMode, custom: [URL]) -> [String] {
        if mode == .custom { return custom.map(\.path) }
        var roots = [
            "\(home)/Downloads",
            "\(home)/Library/Application Support",
            "/Library/Application Support",
        ] + mountedDiskImages()
        if mode == .balanced || mode == .deep {
            roots += [
                "/Applications",
                "\(home)/Applications",
                "/Library/SystemExtensions",
                "/Library/Internet Plug-Ins",
                "\(home)/Library/Internet Plug-Ins",
                "/Library/PrivilegedHelperTools",
                "/Users/Shared",
                "/private/tmp",
                "/private/var/tmp",
            ]
        }
        if mode == .deep {
            roots += [
                "\(home)/Library",
                "\(home)/Documents",
                "\(home)/Desktop",
                "\(home)/.Trash",
            ]
        }
        // A deeper root already covers the ones inside it.
        let unique = Array(Set(roots)).sorted()
        return unique.filter { root in !unique.contains { $0 != root && root.hasPrefix($0 + "/") } }
    }

    /// Never walked: our own quarantine, iCloud placeholders (opening them
    /// downloads the file), caches that only hold derived data, and the system.
    private func isExcluded(_ path: String) -> Bool {
        let excluded = [
            quarantineFolder,
            "\(home)/Library/Mobile Documents",
            "\(home)/Library/CloudStorage",
            "\(home)/Library/Caches",
            "\(home)/Library/Containers/com.apple.CloudDocs.MobileDocumentsFileProvider",
            "\(home)/Library/Metadata/CoreSpotlight",
            "\(home)/Library/Developer/CoreSimulator",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "/System",
            Bundle.main.bundlePath,
        ]
        return excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Read-only volumes under /Volumes are almost always opened disk images.
    private func mountedDiskImages() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsReadOnlyKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard url.path.hasPrefix("/Volumes/"), values?.volumeIsReadOnly == true, values?.volumeIsRootFileSystem != true else { return nil }
            return url.path
        }
    }

    // MARK: Scan

    func scan(
        mode: AntivirusScanMode,
        custom: [URL] = [],
        trust: Trust,
        cache: [String: AntivirusCacheEntry],
        progress: @escaping @Sendable (AntivirusProgress) -> Void
    ) async -> AntivirusScanOutcome {
        var state = ScanState(mode: mode, trust: trust, cache: cache, progress: progress)

        if mode != .custom {
            state.progress.phase = .launchItems
            scanLaunchItems(&state)
        }

        state.progress.phase = .files
        for root in roots(for: mode, custom: custom) where !Task.isCancelled {
            walk(root, archiveDepth: 0, state: &state)
        }

        if (mode == .balanced || mode == .deep), !Task.isCancelled {
            state.progress.phase = .processes
            scanRunningPrograms(&state)
        }

        state.flush(force: true)
        return AntivirusScanOutcome(
            detections: state.detections,
            filesChecked: state.progress.filesChecked,
            cleanFiles: state.clean,
            wasCancelled: Task.isCancelled
        )
    }

    private struct ScanState {
        let mode: AntivirusScanMode
        let trust: Trust
        let cache: [String: AntivirusCacheEntry]
        let report: @Sendable (AntivirusProgress) -> Void
        var progress = AntivirusProgress()
        var detections: [Detection] = []
        var clean: [String: AntivirusCacheEntry] = [:]
        /// Paths already part of a detection, so a program started by a
        /// flagged launch agent isn't reported twice.
        var claimed: Set<String> = []
        var lastReport = Date.distantPast

        init(mode: AntivirusScanMode, trust: Trust, cache: [String: AntivirusCacheEntry], progress: @escaping @Sendable (AntivirusProgress) -> Void) {
            self.mode = mode
            self.trust = trust
            self.cache = cache
            self.report = progress
        }

        mutating func add(_ detection: Detection) {
            guard detection.components.allSatisfy({ !claimed.contains($0.path) }) else { return }
            claimed.formUnion(detection.components.map(\.path))
            detections.append(detection)
            progress.detections = detections.count
            flush(force: true)
        }

        mutating func flush(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) > 0.1 else { return }
            lastReport = now
            report(progress)
        }
    }

    // MARK: Files

    private func walk(_ root: String, archiveDepth: Int, archive: String? = nil, state: inout ScanState) {
        guard !isExcluded(root) || archive != nil else { return }
        let rootURL = URL(fileURLWithPath: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else { return }
        if !isDirectory.boolValue {
            inspectFile(rootURL, archiveDepth: archiveDepth, archive: archive, state: &state)
            return
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return }
        while let next = autoreleasepool(invoking: { enumerator.nextObject() }) {
            if Task.isCancelled { return }
            guard let url = next as? URL else { continue }
            // Every file's temporary objects are released before the next one.
            autoreleasepool { visit(url, enumerator: enumerator, archiveDepth: archiveDepth, archive: archive, state: &state) }
        }
    }

    private func visit(_ url: URL, enumerator: FileManager.DirectoryEnumerator, archiveDepth: Int, archive: String?, state: inout ScanState) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        let path = url.path
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return }
        if values.isDirectory == true {
            if archive == nil, isExcluded(path) || state.trust.covers(path: path) {
                enumerator.skipDescendants()
                return
            }
            // An app bundle named after an adware family is reported as a
            // whole; its insides don't need a second look.
            if url.pathExtension == "app", let family = AntivirusRules.adwareFamily(in: url.deletingPathExtension().lastPathComponent) {
                state.add(adwareDetection(family: family, bundle: url, archive: archive, mode: state.mode))
                enumerator.skipDescendants()
            }
            return
        }
        if values.isRegularFile == true {
            inspectFile(url, archiveDepth: archiveDepth, archive: archive, state: &state)
        }
    }

    private func inspectFile(_ url: URL, archiveDepth: Int, archive: String?, state: inout ScanState) {
        let path = url.path
        state.progress.filesChecked += 1
        state.progress.currentPath = archive.map { "\($0) › \(url.lastPathComponent)" } ?? path
        state.flush()
        if archive == nil, state.trust.covers(path: path) { return }

        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        // iCloud files that aren't downloaded (SF_DATALESS): reading one
        // would download it.
        if info.st_flags & 0x4000_0000 != 0 { return }
        let size = Int64(info.st_size)
        guard size > 0 else { return }
        let entry = AntivirusCacheEntry(inode: UInt64(info.st_ino), modified: TimeInterval(info.st_mtimespec.tv_sec), size: size)
        if archive == nil, state.cache[path] == entry {
            state.clean[path] = entry
            return
        }

        guard let head = readHead(url, count: 4096) else { return }
        let component = { (sha: String?) in
            archive.map { ThreatComponent(path: $0, role: .archive, sha256: nil, size: size, archiveEntry: url.lastPathComponent) }
                ?? ThreatComponent(path: path, role: .file, sha256: sha, size: size)
        }

        if AntivirusRules.isEICAR(head, fileSize: size) {
            let sha = AntivirusRules.sha256(of: url)
            if let sha, state.trust.hashes.contains(sha) { return }
            state.add(Detection(
                id: UUID(),
                name: String(localized: "EICAR test file"),
                category: .testFile,
                severity: .high,
                source: .testSignature,
                rule: "test.eicar",
                reason: String(localized: "A harmless standard file used to check that antivirus software works."),
                components: [component(sha)],
                signing: nil,
                detectedAt: Date(),
                mode: state.mode
            ))
            return
        }

        let kind = AntivirusRules.kind(of: head)
        if kind == .zip, state.mode.scansArchives, archiveDepth < 2, size < 200 * 1_048_576 {
            scanArchive(url, depth: archiveDepth, outer: archive ?? path, state: &state)
            return
        }

        if kind == .machO || kind == .script, let sha = AntivirusRules.sha256(of: url) {
            if state.trust.hashes.contains(sha) { return }
            if let known = AntivirusRules.knownHashes[sha] {
                state.add(Detection(
                    id: UUID(),
                    name: known,
                    category: .knownMalware,
                    severity: .high,
                    source: .fileHash,
                    rule: "hash.sha256",
                    reason: String(localized: "This file matches the fingerprint of known malware."),
                    components: [component(sha)],
                    signing: kind == .machO ? AntivirusRules.signingStatus(of: url) : nil,
                    detectedAt: Date(),
                    mode: state.mode
                ))
                return
            }
        }
        if archive == nil { state.clean[path] = entry }
    }

    private func readHead(_ url: URL, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }

    /// Unpacks a ZIP into a temporary folder with `ditto` and scans that.
    /// A match is reported on the archive, with the entry that matched.
    private func scanArchive(_ url: URL, depth: Int, outer: String, state: inout ScanState) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MacDashAV-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, temp.path]).status == 0 else { return }
        walk(temp.path, archiveDepth: depth + 1, archive: outer, state: &state)
    }

    private func adwareDetection(family: String, bundle: URL, archive: String?, mode: AntivirusScanMode) -> Detection {
        let component = archive.map { ThreatComponent(path: $0, role: .archive, sha256: nil, size: 0, archiveEntry: bundle.lastPathComponent) }
            ?? ThreatComponent(path: bundle.path, role: .appBundle, sha256: nil, size: 0)
        return Detection(
            id: UUID(),
            name: String(format: String(localized: "Adware: %@"), family.capitalized),
            category: .adware,
            severity: .high,
            source: .familyName,
            rule: "adware.family.\(family)",
            reason: String(localized: "The name matches a known adware family that shows ads or changes browser settings."),
            components: [component],
            signing: archive == nil ? AntivirusRules.signingStatus(of: bundle) : nil,
            detectedAt: Date(),
            mode: mode
        )
    }

    // MARK: Launch items

    private func scanLaunchItems(_ state: inout ScanState) {
        let ownPrefixes = [Bundle.main.bundleIdentifier, "com.macdash", "com.mactidy"].compactMap { $0 }
        let folders = ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in files.sorted() where name.hasSuffix(".plist") {
                if Task.isCancelled { return }
                autoreleasepool { checkLaunchItem(folder: folder, name: name, ownPrefixes: ownPrefixes, state: &state) }
            }
        }
    }

    private func checkLaunchItem(folder: String, name: String, ownPrefixes: [String], state: inout ScanState) {
        let plistPath = "\(folder)/\(name)"
        state.progress.filesChecked += 1
        state.progress.currentPath = plistPath
        state.flush()
        guard !state.trust.covers(path: plistPath),
              let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        let label = plist["Label"] as? String ?? name
        if ownPrefixes.contains(where: label.hasPrefix) { return }
        if let detection = judgeLaunchItem(plistPath: plistPath, label: label, plist: plist, state: &state) {
            state.add(detection)
        }
    }

    private static let interpreters: Set<String> = [
        "/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/python3", "/usr/bin/perl", "/usr/bin/ruby", "/usr/bin/osascript", "/usr/bin/env",
    ]

    private func judgeLaunchItem(plistPath: String, label: String, plist: [String: Any], state: inout ScanState) -> Detection? {
        var arguments = plist["ProgramArguments"] as? [String] ?? []
        if let program = plist["Program"] as? String { arguments.insert(program, at: 0) }
        let program = arguments.first
        // For `sh script.sh` the script is the real payload.
        let payload = program.flatMap { Self.interpreters.contains($0) ? arguments.dropFirst().first { $0.hasPrefix("/") } : $0 }

        let plistSize = (try? FileManager.default.attributesOfItem(atPath: plistPath)[.size] as? Int64) ?? 0
        var components = [ThreatComponent(path: plistPath, role: .launchItem, sha256: AntivirusRules.sha256(of: URL(fileURLWithPath: plistPath)), size: plistSize)]
        var payloadSigning: SigningStatus?
        if let payload, FileManager.default.fileExists(atPath: payload), !payload.hasPrefix("/System/"), !payload.hasPrefix("/usr/") {
            let url = URL(fileURLWithPath: payload)
            let size = (try? FileManager.default.attributesOfItem(atPath: payload)[.size] as? Int64) ?? 0
            components.append(ThreatComponent(path: payload, role: .program, sha256: AntivirusRules.sha256(of: url), size: size))
            payloadSigning = AntivirusRules.signingStatus(of: url)
        }
        if let sha = components.last?.sha256, state.trust.hashes.contains(sha) { return nil }
        if let team = payloadSigning?.teamID, state.trust.teamIDs.contains(team) { return nil }

        func detection(_ name: String, _ category: ThreatCategory, _ severity: ThreatSeverity, _ source: DetectionSource, _ rule: String, _ reason: String) -> Detection {
            Detection(id: UUID(), name: name, category: category, severity: severity, source: source, rule: rule, reason: reason,
                      components: components, signing: payloadSigning, detectedAt: Date(), mode: state.mode)
        }

        let kindName = plistPath.contains("LaunchDaemons") ? String(localized: "launch daemon") : String(localized: "launch agent")
        if let family = AntivirusRules.adwareFamily(in: label) ?? AntivirusRules.adwareFamily(in: payload ?? "") {
            return detection(String(format: String(localized: "Adware: %@"), family.capitalized), .adware, .high, .familyName, "adware.family.\(family)",
                             String(format: String(localized: "A %@ that starts a known adware family every time you log in."), kindName))
        }
        if let payload, let sha = components.last?.sha256, components.count > 1 {
            if let known = AntivirusRules.knownHashes[sha] {
                return detection(known, .knownMalware, .high, .fileHash, "hash.sha256",
                                 String(format: String(localized: "A %@ starts a file that matches known malware."), kindName))
            }
            if let head = readHead(URL(fileURLWithPath: payload), count: 4096), AntivirusRules.isEICAR(head, fileSize: components.last?.size ?? 0) {
                return detection(String(localized: "EICAR test file"), .testFile, .high, .testSignature, "test.eicar",
                                 String(format: String(localized: "A %@ starts the harmless antivirus test file."), kindName))
            }
            if AntivirusRules.kind(of: readHead(URL(fileURLWithPath: payload), count: 4) ?? Data()) == .script,
               let text = try? String(contentsOfFile: payload, encoding: .utf8), let rule = AntivirusRules.suspiciousScriptRule(text) {
                return detection(String(format: String(localized: "Suspicious %@"), kindName), .script, .suspicious, .scriptContent, rule,
                                 String(localized: "Its script downloads or decodes code and runs it, a common way to install malware."))
            }
        }
        if ThreatSignatures.launchItemLooksSuspicious(plist: plist) {
            return detection(String(format: String(localized: "Suspicious %@"), kindName), .persistence, .suspicious, .launchItem, "launch.arguments",
                             String(localized: "It runs a command that downloads, decodes or hides what it does."))
        }
        if let payload, let signing = payloadSigning, !signing.isTrustworthy,
           !AntivirusRules.isPackageManagerPath(payload), AntivirusRules.isUnusualProgramLocation(payload, home: home) {
            return detection(String(format: String(localized: "Suspicious %@"), kindName), .unsignedProgram, .suspicious, .codeSignature, "launch.unsigned-unusual-location",
                             String(localized: "It starts an unsigned program from a folder where apps aren't normally installed."))
        }
        // Clean: the plist and its program count as checked.
        state.claimed.formUnion(components.map(\.path))
        return nil
    }

    // MARK: Running programs

    private func scanRunningPrograms(_ state: inout ScanState) {
        var seen = Set<String>()
        for path in Self.runningExecutablePaths() where !Task.isCancelled {
            autoreleasepool { checkRunningProgram(path, seen: &seen, state: &state) }
        }
    }

    private func checkRunningProgram(_ path: String, seen: inout Set<String>, state: inout ScanState) {
        guard seen.insert(path).inserted, !state.claimed.contains(path), !isExcluded(path),
              !path.hasPrefix("/usr/"), !path.hasPrefix("/bin/"), !path.hasPrefix("/sbin/"), !path.hasPrefix("/Library/Apple/"),
              !state.trust.covers(path: path)
        else { return }
        let url = URL(fileURLWithPath: path)
        state.progress.currentPath = path
        state.progress.filesChecked += 1
        state.flush()
        guard let sha = AntivirusRules.sha256(of: url), !state.trust.hashes.contains(sha) else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let component = ThreatComponent(path: path, role: .program, sha256: sha, size: size)
        if let known = AntivirusRules.knownHashes[sha] {
            state.add(Detection(id: UUID(), name: known, category: .knownMalware, severity: .high, source: .fileHash, rule: "hash.sha256",
                                reason: String(localized: "A running program matches the fingerprint of known malware."),
                                components: [component], signing: AntivirusRules.signingStatus(of: url), detectedAt: Date(), mode: state.mode))
            return
        }
        guard AntivirusRules.isUnusualProgramLocation(path, home: home), !AntivirusRules.isPackageManagerPath(path) else { return }
        let signing = AntivirusRules.signingStatus(of: url)
        if let team = signing.teamID, state.trust.teamIDs.contains(team) { return }
        guard !signing.isTrustworthy else { return }
        state.add(Detection(id: UUID(), name: String(localized: "Suspicious running program"), category: .unsignedProgram, severity: .suspicious,
                            source: .codeSignature, rule: "process.unsigned-unusual-location",
                            reason: String(localized: "An unsigned program is running from a folder where apps aren't normally installed."),
                            components: [component], signing: signing, detectedAt: Date(), mode: state.mode))
    }

    static func runningExecutablePaths() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: 4096)
        return pids.prefix(Int(max(filled, 0))).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(cString: buffer)
        }
    }

    /// Process IDs whose executable is `path`, for stopping a threat after
    /// the user approves removing it.
    static func processIDs(runningAt path: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: 4096)
        return pids.prefix(Int(max(filled, 0))).filter { pid in
            pid > 0 && proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer) == path
        }
    }
}
