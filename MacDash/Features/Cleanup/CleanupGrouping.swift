import AppKit
import Foundation
import SwiftUI

/// What a cleanable item is, in words a person can act on.
enum CleanupKind: String, CaseIterable {
    case cache, log, appData, savedState, trash, mail, other

    var title: String {
        switch self {
        case .cache: return String(localized: "Cache")
        case .log: return String(localized: "Logs")
        case .appData: return String(localized: "App data")
        case .savedState: return String(localized: "Saved state")
        case .trash: return String(localized: "Trash")
        case .mail: return String(localized: "Mail files")
        case .other: return String(localized: "Files")
        }
    }

    var icon: String {
        switch self {
        case .cache: return "bolt.horizontal.circle.fill"
        case .log: return "doc.text.fill"
        case .appData: return "shippingbox.fill"
        case .savedState: return "rectangle.stack.fill"
        case .trash: return "trash.fill"
        case .mail: return "envelope.fill"
        case .other: return "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .cache: return Tint.cyan
        case .log: return Tint.yellow
        case .appData: return Tint.purple
        case .savedState: return Tint.teal
        case .trash: return Tint.red
        case .mail: return Tint.blue
        case .other: return Color(white: 0.7)
        }
    }
}

/// Items that belong together: everything one app left behind, or one kind of
/// file in the Trash.
struct CleanupGroup: Identifiable {
    let id: String
    let title: String
    /// An installed app to borrow the icon from, if the group belongs to one.
    let appPath: String?
    let kinds: [CleanupKind]
    let items: [CleanableItem]

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    var summary: String {
        let kindText = kinds.map(\.title).joined(separator: ", ")
        // A lone item says where it lives instead of "1 item".
        if items.count == 1, let item = items.first, !item.isActionItem {
            return "\(kindText) · \((item.path as NSString).abbreviatingWithTildeInPath)"
        }
        let count = items.count == 1
            ? String(localized: "1 item")
            : String(format: String(localized: "%lld items"), Int64(items.count))
        return kindText.isEmpty ? count : "\(kindText) · \(count)"
    }
}

enum CleanupGrouper {
    private static let libraryRoots: [(folder: String, kind: CleanupKind)] = [
        ("Caches", .cache),
        ("Logs", .log),
        ("Application Support", .appData),
        ("Containers", .appData),
        ("Group Containers", .appData),
        ("HTTPStorages", .cache),
        ("WebKit", .cache),
        ("Saved Application State", .savedState),
    ]

    static func kind(of item: CleanableItem) -> CleanupKind {
        let path = item.path
        if path.contains("/.Trash") { return .trash }
        if path.contains("/Library/Mail") || item.category == .mailAttachments { return .mail }
        if let root = libraryRoot(in: path) { return root.kind }
        if path.localizedCaseInsensitiveContains("cache") { return .cache }
        return .other
    }

    /// Groups similar items, largest group first. Returns nil when grouping
    /// would not help (every item ends up alone).
    static func groups(for items: [CleanableItem]) -> [CleanupGroup]? {
        var buckets: [String: (title: String, appPath: String?, items: [CleanableItem])] = [:]
        var resolved: [String: (name: String, path: String?)] = [:]

        for item in items {
            let key: String
            var title: String
            var appPath: String?

            if item.isActionItem {
                key = "action:\(item.name)"
                title = item.name
            } else if kind(of: item) == .trash {
                let type = trashType(of: item)
                key = "trash:\(type)"
                title = String(format: String(localized: "Trash · %@"), type)
            } else if let owner = owner(of: item.path) {
                key = "owner:\(owner.lowercased())"
                if resolved[owner] == nil { resolved[owner] = resolve(owner) }
                title = resolved[owner]!.name
                appPath = resolved[owner]!.path
            } else {
                let parent = (item.path as NSString).deletingLastPathComponent
                key = "folder:\(parent)"
                title = (parent as NSString).lastPathComponent
            }
            var bucket = buckets[key] ?? (title, appPath, [])
            bucket.items.append(item)
            buckets[key] = bucket
        }

        guard buckets.count < items.count else { return nil }
        return buckets.map { key, bucket in
            let kinds = Array(Set(bucket.items.map(kind(of:)))).sorted { $0.rawValue < $1.rawValue }
            return CleanupGroup(id: key, title: bucket.title, appPath: bucket.appPath, kinds: kinds, items: bucket.items)
        }
        .sorted { $0.totalSize > $1.totalSize }
    }

    // MARK: Helpers

    private static func libraryRoot(in path: String) -> (folder: String, kind: CleanupKind)? {
        libraryRoots.first { path.contains("/Library/\($0.folder)/") }
    }

    /// The folder right under a Library location, usually an app or bundle ID.
    private static func owner(of path: String) -> String? {
        guard let root = libraryRoot(in: path),
              let range = path.range(of: "/Library/\(root.folder)/")
        else { return nil }
        let rest = path[range.upperBound...]
        let first = rest.split(separator: "/").first.map(String.init)
        guard let first, !first.isEmpty else { return nil }
        return first
    }

    /// Turns a folder name or bundle ID into an app name and, when the app is
    /// installed, its location (for the icon).
    private static func resolve(_ owner: String) -> (name: String, path: String?) {
        let candidates = [owner, owner.replacingOccurrences(of: "group.", with: ""), owner.replacingOccurrences(of: ".savedState", with: "")]
        for id in candidates where id.contains(".") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                return (name, url.path)
            }
        }
        if owner.contains("."), !owner.contains(" ") {
            let parts = owner.split(separator: ".")
            if let last = parts.last, parts.count >= 2 { return (String(last), nil) }
        }
        return (owner, nil)
    }

    private static func trashType(of item: CleanableItem) -> String {
        if (item.name as NSString).pathExtension.lowercased() == "app" { return SpaceCategory.application.title }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return SpaceCategory.folder.title
        }
        return SpaceCategory(fileExtension: (item.name as NSString).pathExtension).title
    }
}
