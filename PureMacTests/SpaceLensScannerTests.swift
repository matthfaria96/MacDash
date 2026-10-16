import Darwin
import Foundation
import XCTest
@testable import PureMac

final class SpaceLensScannerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("spacelens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    private func scan() async throws -> SpaceNode {
        let result = await SpaceLensScanner.scan(root: folder, onProgress: { _ in })
        return try XCTUnwrap(result?.root)
    }

    func testBulkListingMatchesStat() throws {
        try write("a.bin", bytes: 3_000_000)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let entries = try XCTUnwrap(DirectoryLister.list(folder.path))
        let file = try XCTUnwrap(entries.first { $0.name == "a.bin" })
        var info = stat()
        XCTAssertEqual(lstat(folder.appendingPathComponent("a.bin").path, &info), 0)
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.allocated, Int64(info.st_blocks) * 512)
        XCTAssertEqual(entries.first { $0.name == "sub" }?.kind, .directory)
    }

    func testHardLinksAreCountedOnce() async throws {
        try write("one/big.bin", bytes: 2_000_000)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("two"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: folder.appendingPathComponent("one/big.bin"), to: folder.appendingPathComponent("two/big.bin"))
        let root = try await scan()
        let single = DirectoryLister.list(folder.appendingPathComponent("one").path)?.first?.allocated ?? 0
        XCTAssertEqual(root.size, single)
    }

    func testAPFSClonesAreCountedOnce() async throws {
        try write("original.bin", bytes: 4_000_000)
        let source = folder.appendingPathComponent("original.bin").path
        let copy = folder.appendingPathComponent("clone.bin").path
        guard clonefile(source, copy, 0) == 0 else { throw XCTSkip("The temporary folder can't make clones") }
        let root = try await scan()
        let single = DirectoryLister.list(folder.path)?.first { $0.name == "original.bin" }?.allocated ?? 0
        XCTAssertEqual(root.size, single)
    }

    func testPackagesAreFoldedIntoOneItem() async throws {
        try write("Tool.app/Contents/MacOS/tool", bytes: 1_500_000)
        try write("Tool.app/Contents/Info.plist", bytes: 10)
        let root = try await scan()
        let app = try XCTUnwrap(root.children.first { $0.name == "Tool.app" })
        XCTAssertEqual(app.kind, .package)
        XCTAssertTrue(app.children.isEmpty)
        XCTAssertGreaterThanOrEqual(app.size, 1_500_000)
        XCTAssertEqual(app.itemCount, 2)
    }

    func testSmallFilesFoldIntoOneNode() async throws {
        for index in 0..<12 { try write("many/f\(index).txt", bytes: 100) }
        let root = try await scan()
        let many = try XCTUnwrap(root.children.first { $0.name == "many" })
        XCTAssertEqual(many.children.count, 1)
        XCTAssertEqual(many.children.first?.kind, .smallerFiles)
        XCTAssertEqual(many.itemCount, 12)
    }

    func testFindsNodesByPath() async throws {
        try write("a/b/c.bin", bytes: 2_000_000)
        let root = try await scan()
        let chain = SpaceLensModel.nodes(at: folder.appendingPathComponent("a/b/c.bin").path, root: root, rootPath: folder.path)
        XCTAssertEqual(chain?.map(\.name).dropFirst(), ["a", "b", "c.bin"])
        XCTAssertNil(SpaceLensModel.nodes(at: "/somewhere/else", root: root, rootPath: folder.path))
    }

    func testRingsFoldThinSlicesAndStayInsideTheCircle() async throws {
        try write("big.bin", bytes: 8_000_000)
        for index in 0..<40 { try write("small\(index).bin", bytes: 1_000_000 + index) }
        let root = try await scan()
        let geometry = Sunburst.Geometry(size: CGSize(width: 300, height: 300))
        let slices = Sunburst.layout(folder: root, geometry: geometry, free: Int64(root.size))
        let firstRing = slices.filter { $0.depth == 1 }
        XCTAssertTrue(firstRing.contains { if case .group = $0.kind { return true } else { return false } })
        XCTAssertTrue(firstRing.contains { if case .free = $0.kind { return true } else { return false } })
        XCTAssertLessThanOrEqual(firstRing.map(\.end).max() ?? 0, 2 * .pi + 1e-9)
        // Free space takes the second half when it equals the used space.
        let free = try XCTUnwrap(firstRing.first { if case .free = $0.kind { return true } else { return false } })
        XCTAssertEqual(free.start, .pi, accuracy: 1e-9)
    }

    func testMeasureMatchesScan() async throws {
        try write("x/1.bin", bytes: 1_200_000)
        try write("x/y/2.bin", bytes: 2_300_000)
        let root = try await scan()
        XCTAssertEqual(AppFootprintScanner.measure(folder.path), root.size)
    }
}

final class SunburstMotionTests: XCTestCase {
    func testHueBlendsTheShortWayAroundTheWheel() {
        let red = Sunburst.Paint(hue: 0.95, saturation: 1, brightness: 1, opacity: 1)
        let orange = Sunburst.Paint(hue: 0.05, saturation: 1, brightness: 1, opacity: 1)
        let middle = red.blended(to: orange, t: 0.5)
        XCTAssertTrue(middle.hue < 0.02 || middle.hue > 0.98, "went through green: \(middle.hue)")
    }

    func testGrayTakesTheOtherHue() {
        let blended = Sunburst.Paint.group.blended(to: Sunburst.Paint(hue: 0.7, saturation: 0.6, brightness: 1, opacity: 1), t: 0.3)
        XCTAssertEqual(blended.hue, 0.7, accuracy: 1e-9)
    }

    func testFramesInterpolateEveryField() {
        let from = Sunburst.Frame(key: "a", start: 0, end: 1, depth: 1, paint: .free, alpha: 1)
        let to = Sunburst.Frame(key: "a", start: 2, end: 6, depth: 0, paint: .center, alpha: 0)
        let mid = from.interpolated(to: to, t: 0.5)
        XCTAssertEqual(mid.start, 1, accuracy: 1e-9)
        XCTAssertEqual(mid.end, 3.5, accuracy: 1e-9)
        XCTAssertEqual(mid.depth, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.alpha, 0.5, accuracy: 1e-9)
    }

    func testRadiiShrinkSmoothlyIntoTheCenter() {
        let geometry = Sunburst.Geometry(size: CGSize(width: 400, height: 400))
        let below = geometry.radii(depth: 0.999)
        let at = geometry.radii(depth: 1)
        XCTAssertEqual(below.outer, at.outer, accuracy: 0.5)
        XCTAssertEqual(below.inner, at.inner, accuracy: 0.5)
        XCTAssertEqual(geometry.radii(depth: 0).inner, 0)
        XCTAssertEqual(geometry.radii(depth: 0).outer, geometry.centerRadius)
    }
}

final class VirtualMachineFinderTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("vmhome-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func makeMachine(_ relative: String, bytes: Int = 2_000_000) throws {
        let folder = home + "/" + relative
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: URL(fileURLWithPath: folder + "/disk.img"))
    }

    func testFindsMachinesFromEachToolUnselected() throws {
        try makeMachine("Library/Containers/com.utmapp.UTM/Data/Documents/Windows 11.utm")
        try makeMachine("Parallels/Ubuntu.pvm")
        try makeMachine("VirtualBox VMs/Debian")
        try makeMachine(".lima/default")
        try makeMachine(".lima/_config")
        try makeMachine("Parallels/notes")

        let items = VirtualMachineFinder.findMachines(home: home)
        let names = Set(items.map { ($0.path as NSString).lastPathComponent })
        XCTAssertEqual(names, ["Windows 11.utm", "Ubuntu.pvm", "Debian", "default"])
        XCTAssertTrue(items.allSatisfy { !$0.isSelected && $0.category == .virtualMachines })
        XCTAssertTrue(items.first { $0.path.hasSuffix(".utm") }?.name.contains("UTM") ?? false)
    }

    func testOnlyMachinesDirectlyInsideKnownFoldersAreRemovable() {
        XCTAssertNotNil(VirtualMachineFinder.place(for: home + "/Parallels/Ubuntu.pvm", home: home))
        XCTAssertNotNil(VirtualMachineFinder.place(for: home + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", home: home))
        XCTAssertNotNil(VirtualMachineFinder.place(for: home + "/.orbstack/data", home: home))
        XCTAssertNil(VirtualMachineFinder.place(for: home + "/Parallels", home: home))
        XCTAssertNil(VirtualMachineFinder.place(for: home + "/Parallels/Ubuntu.pvm/disk.img", home: home))
        XCTAssertNil(VirtualMachineFinder.place(for: home + "/Parallels/notes.txt", home: home))
        XCTAssertNil(VirtualMachineFinder.place(for: home + "/.lima/_config", home: home))
        XCTAssertNil(VirtualMachineFinder.place(for: home + "/.orbstack/bin", home: home))
        XCTAssertNil(VirtualMachineFinder.place(for: home + "/Documents", home: home))
    }

    func testDockerActionsRoundTripThroughTheirPath() {
        for action in DockerDataAction.allCases {
            XCTAssertEqual(DockerDataAction(itemPath: action.itemPath), action)
            XCTAssertTrue(CleanableItem(name: "", path: action.itemPath, size: 1, category: .dockerData, isSelected: false, lastModified: nil).isActionItem)
        }
        XCTAssertNil(DockerDataAction(itemPath: "/Users/x/Docker.raw"))
        XCTAssertTrue(DockerDataAction.images.commands.allSatisfy { $0.contains("--all") })
    }

    func testParsesDockerSizes() {
        XCTAssertEqual(VirtualMachineFinder.parseBytes("1.5GB"), 1_500_000_000)
        XCTAssertEqual(VirtualMachineFinder.parseBytes("789kB"), 789_000)
        XCTAssertEqual(VirtualMachineFinder.parseBytes("0B"), 0)
        XCTAssertNil(VirtualMachineFinder.parseBytes("lots"))
    }

    func testRiskyAreasAreNeverPreselected() {
        XCTAssertTrue(CleaningCategory.virtualMachines.isRisky)
        XCTAssertTrue(CleaningCategory.dockerData.isRisky)
        XCTAssertFalse(CleaningCategory.dockerCache.isRisky)
        XCTAssertEqual(CleanupBundle.containing(.virtualMachines), .virtualization)
    }
}
