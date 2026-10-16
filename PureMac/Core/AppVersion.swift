import Foundation

/// The version and build of this copy of MacFresh, as shown in Settings.
enum AppVersion {
    static let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
}
