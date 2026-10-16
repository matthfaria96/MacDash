import XCTest
@testable import PureMac

@MainActor
final class MonitoringLifecycleTests: XCTestCase {
    func testRepeatedActivationDoesNotLeakSubscriptionsAndLastOwnerStopsSampling() {
        var samples = 0
        let monitor = SystemMonitor(sampleAction: { samples += 1 })
        let page = UUID()
        monitor.start(owner: page, interval: 1.5)
        monitor.start(owner: page, interval: 1.5)
        XCTAssertEqual(samples, 1)
        XCTAssertTrue(monitor.isSampling)
        monitor.stop(owner: page)
        XCTAssertFalse(monitor.isSampling)
        monitor.stop(owner: page)
        XCTAssertFalse(monitor.isSampling)
    }

    func testLeavingPerformanceKeepsOnlyMenuBarIntervalUntilMenuBarStops() {
        let monitor = SystemMonitor(sampleAction: {})
        let page = UUID(), menuBar = UUID(), popover = UUID()
        monitor.start(owner: menuBar)
        monitor.start(owner: page, interval: 1.5)
        monitor.start(owner: popover)
        XCTAssertEqual(monitor.samplingInterval, 1.5)
        monitor.stop(owner: page)
        XCTAssertTrue(monitor.isSampling)
        XCTAssertEqual(monitor.samplingInterval, 2)
        monitor.stop(owner: popover)
        XCTAssertTrue(monitor.isSampling)
        monitor.stop(owner: menuBar)
        XCTAssertFalse(monitor.isSampling)
        XCTAssertNil(monitor.samplingInterval)
    }

    func testQueuedTimerCannotSampleAfterLastOwnerLeaves() async throws {
        var samples = 0
        let monitor = SystemMonitor(sampleAction: { samples += 1 })
        let owner = UUID()
        monitor.start(owner: owner, interval: 0.1)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertGreaterThan(samples, 1)
        monitor.stop(owner: owner)
        let stoppedCount = samples
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(samples, stoppedCount)
    }
}

/// Mounts a small throwaway disk image and ejects it the way the Eject
/// buttons do, so the real drive path is exercised without touching the
/// user's own drives.
final class ExternalDriveEjectTests: XCTestCase {
    func testMountedDiskImageIsListedAndEjects() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacFreshEject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("eject.dmg")
        let volumeName = "MacFreshEjectTest\(Int.random(in: 1000...9999))"
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "4m", "-fs", "APFS", "-volname", volumeName, image.path])
        try run("/usr/bin/hdiutil", ["attach", "-quiet", image.path])

        var drive: ExternalDrive?
        for _ in 0..<20 where drive == nil {
            drive = ExternalDriveReader.mounted().first { $0.name == volumeName }
            if drive == nil { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        let mounted = try XCTUnwrap(drive, "A mounted disk image should be listed as an external drive")
        XCTAssertTrue(mounted.isDiskImage)
        XCTAssertGreaterThan(mounted.total, 0)

        let ejected = await ExternalDriveReader.eject(mounted)
        if !ejected { try? run("/usr/bin/hdiutil", ["detach", "-force", mounted.url.path]) }
        XCTAssertTrue(ejected, "Eject should unmount the disk image")
        XCTAssertFalse(ExternalDriveReader.mounted().contains { $0.name == volumeName })
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments.joined(separator: " ")) failed")
    }
}

/// Prints what the Bluetooth reader finds on this Mac. Not an assertion of
/// specific devices: it only checks that a connected device with a battery
/// macOS knows about doesn't come back without one.
final class BluetoothBatteryReadingTests: XCTestCase {
    func testConnectedDevicesReportTheirBatteries() {
        let devices = BluetoothReader.connected()
        for device in devices {
            print("BLUETOOTH-DEVICE \(device.name) [\(device.kind)] battery=\(device.battery.map { "\($0)%" } ?? "none")")
        }
        let classic = AccessoryBatteryReader.classic()
        for device in devices where classic[device.name] != nil {
            XCTAssertNotNil(device.battery, "\(device.name) has a battery level in IOBluetooth")
        }
    }
}
