import AppKit
import Foundation

/// Installs an update for an app that ships its own (Sparkle) updater:
/// downloads the new version from the app's feed, checks that it is the same
/// app from the same developer, and swaps it in. The old copy goes to the
/// Trash, so an update can always be undone.
enum SparkleInstaller {
    enum InstallError: LocalizedError {
        case noDownload
        case unsupportedFormat
        case downloadFailed(String)
        case noAppInDownload
        case notTheSameApp
        case signatureMismatch
        case stillRunning
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDownload:
                return String(localized: "The app's update feed has no download link.")
            case .unsupportedFormat:
                return String(localized: "This update comes as an installer package. Open the download to install it.")
            case .downloadFailed(let message):
                return String(format: String(localized: "The download failed: %@"), message)
            case .noAppInDownload:
                return String(localized: "The download doesn't contain the app.")
            case .notTheSameApp:
                return String(localized: "The download contains a different app, so nothing was changed.")
            case .signatureMismatch:
                return String(localized: "The new version isn't signed by the same developer, so nothing was changed.")
            case .stillRunning:
                return String(localized: "The app didn't quit, so it couldn't be replaced.")
            case .replaceFailed(let message):
                return String(format: String(localized: "The app couldn't be replaced: %@"), message)
            }
        }
    }

    /// Formats this installer can unpack. Installer packages (.pkg) and
    /// anything else fall back to opening the download.
    static func canInstall(_ update: SparkleAppUpdate) -> Bool {
        guard !update.isMacAppStore, let url = update.downloadURL else { return false }
        return archiveKind(of: url) != nil
    }

    static func install(
        _ update: SparkleAppUpdate,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let downloadURL = update.downloadURL, SparkleUpdateChecker.isSafeURL(downloadURL) else { throw InstallError.noDownload }
        guard let kind = archiveKind(of: downloadURL) else { throw InstallError.unsupportedFormat }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDashUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // 1. Download (80% of the bar).
        let archive = try await download(downloadURL, into: workspace) { progress($0 * 0.8) }
        try Task.checkCancellation()

        // 2. Unpack and find the app.
        let newApp = try await Task.detached(priority: .userInitiated) {
            try unpack(archive, kind: kind, in: workspace, bundleIdentifier: update.bundleIdentifier)
        }.value
        progress(0.85)
        try Task.checkCancellation()

        // 3. Same app, same developer, intact signature.
        try await Task.detached(priority: .userInitiated) {
            try verify(newApp: newApp, replacing: update.appURL)
        }.value
        progress(0.9)
        try Task.checkCancellation()

        // 4. Quit it if it's open, swap it in, and reopen it.
        let wasRunning = try await quitIfRunning(bundleIdentifier: update.bundleIdentifier)
        try await Task.detached(priority: .userInitiated) {
            try replace(update.appURL, with: newApp)
        }.value
        progress(1)
        if wasRunning {
            await MainActor.run {
                NSWorkspace.shared.openApplication(at: update.appURL, configuration: .init())
            }
        }
    }

    // MARK: Steps

    private enum ArchiveKind { case zip, diskImage, tarball }

    private static func archiveKind(of url: URL) -> ArchiveKind? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".dmg") { return .diskImage }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tbz") || name.hasSuffix(".tar.xz") || name.hasSuffix(".tar") { return .tarball }
        return nil
    }

    private static func download(
        _ url: URL,
        into folder: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        let holder = DownloadHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    if let error {
                        continuation.resume(throwing: (error as? URLError)?.code == .cancelled
                            ? CancellationError()
                            : InstallError.downloadFailed(error.localizedDescription))
                        return
                    }
                    if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
                        continuation.resume(throwing: InstallError.downloadFailed("HTTP \(status)"))
                        return
                    }
                    guard let location else {
                        continuation.resume(throwing: InstallError.downloadFailed(""))
                        return
                    }
                    do {
                        // The temporary file disappears when this handler returns.
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: InstallError.downloadFailed(error.localizedDescription))
                    }
                }
                holder.observation = task.progress.observe(\.fractionCompleted) { value, _ in
                    progress(value.fractionCompleted)
                }
                holder.task = task
                task.resume()
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    private final class DownloadHolder: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
    }

    private static func unpack(_ archive: URL, kind: ArchiveKind, in workspace: URL, bundleIdentifier: String) throws -> URL {
        let extracted = workspace.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)

        switch kind {
        case .zip:
            guard run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]).status == 0 else { throw InstallError.noAppInDownload }
        case .tarball:
            guard run("/usr/bin/tar", ["-xf", archive.path, "-C", extracted.path]).status == 0 else { throw InstallError.noAppInDownload }
        case .diskImage:
            let mount = workspace.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path, archive.path]).status == 0 else {
                throw InstallError.noAppInDownload
            }
            defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            guard let app = findApp(in: mount, bundleIdentifier: bundleIdentifier) else { throw InstallError.noAppInDownload }
            let copy = extracted.appendingPathComponent(app.lastPathComponent)
            guard run("/usr/bin/ditto", [app.path, copy.path]).status == 0 else { throw InstallError.noAppInDownload }
        }

        guard let app = findApp(in: extracted, bundleIdentifier: bundleIdentifier) else {
            throw findApp(in: extracted, bundleIdentifier: nil) == nil ? InstallError.noAppInDownload : InstallError.notTheSameApp
        }
        return app
    }

    /// An app bundle at the top of `folder` or one level down.
    private static func findApp(in folder: URL, bundleIdentifier: String?) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        let top = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in top {
            if item.pathExtension == "app" {
                candidates.append(item)
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, item.lastPathComponent != "__MACOSX" {
                let inner = (try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                candidates += inner.filter { $0.pathExtension == "app" }
            }
        }
        guard let bundleIdentifier else { return candidates.first }
        return candidates.first { Bundle(url: $0)?.bundleIdentifier == bundleIdentifier }
    }

    private static func verify(newApp: URL, replacing oldApp: URL) throws {
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle(url: oldApp)?.bundleIdentifier else {
            throw InstallError.notTheSameApp
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]).status == 0 else {
            throw InstallError.signatureMismatch
        }
        // When the installed app is signed by a developer, the new one must be too.
        if let oldTeam = teamIdentifier(of: oldApp) {
            guard teamIdentifier(of: newApp) == oldTeam else { throw InstallError.signatureMismatch }
        }
    }

    private static func teamIdentifier(of app: URL) -> String? {
        let output = run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path]).output
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let team = String(line.dropFirst("TeamIdentifier=".count))
            return team == "not set" ? nil : team
        }
        return nil
    }

    @MainActor
    private static func quitIfRunning(bundleIdentifier: String) async throws -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !running.isEmpty else { return false }
        running.forEach { $0.terminate() }
        for _ in 0..<60 {
            if running.allSatisfy(\.isTerminated) { return true }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw InstallError.stillRunning
    }

    private static func replace(_ oldApp: URL, with newApp: URL) throws {
        let fileManager = FileManager.default
        var trashed: NSURL?
        do {
            try fileManager.trashItem(at: oldApp, resultingItemURL: &trashed)
        } catch {
            throw InstallError.replaceFailed(error.localizedDescription)
        }
        do {
            try fileManager.moveItem(at: newApp, to: oldApp)
        } catch {
            // Put the old version back so the app is never left missing.
            if let trashed = trashed as URL? { try? fileManager.moveItem(at: trashed, to: oldApp) }
            throw InstallError.replaceFailed(error.localizedDescription)
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
