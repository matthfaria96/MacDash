import Darwin
import Foundation

/// Fast directory listing for Space Lens. One `getattrlistbulk` call returns
/// names, types, allocated sizes and ids for many entries at once, instead of
/// one `lstat` per entry; it falls back to `lstat` where the file system
/// refuses the bulk call.
enum DirectoryLister {
    enum EntryKind {
        case file, directory, symlink, mountPoint, other
    }

    struct Entry {
        let name: String
        let kind: EntryKind
        /// Bytes actually allocated on disk (0 for cloud placeholders).
        let allocated: Int64
        let device: Int32
        let fileID: UInt64
        let linkCount: UInt32
        /// APFS: id shared by exact clones of the same data (`cp -c`, Finder
        /// duplicates), so the blocks are counted once.
        let cloneID: UInt64?
        /// A cloud placeholder whose contents live online.
        let isDataless: Bool
    }

    /// Entries of `path`, or nil when the folder can't be read.
    static func list(_ path: String) -> [Entry]? {
        if let entries = listBulk(path) { return entries }
        return listWithStat(path)
    }

    // MARK: Bulk

    private static let returnedAttrs: UInt32 = 0x8000_0000
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let dirMountStatus: UInt32 = 0x0000_0004
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let extCloneID: UInt32 = 0x0000_0100
    private static let extFlags: UInt32 = 0x0000_0200
    private static let optExtendedCommon: UInt64 = 0x20
    private static let sharesAllBlocks: UInt64 = 0x40
    private static let mountPointStatus: UInt32 = 0x1
    static let datalessFlag: UInt32 = 0x4000_0000

    private static func listBulk(_ path: String) -> [Entry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var request = attrlist(
            bitmapcount: u_short(ATTR_BIT_MAP_COUNT),
            reserved: 0,
            commonattr: returnedAttrs | cmnName | cmnDevID | cmnObjType | cmnFlags | cmnFileID | cmnError,
            volattr: 0,
            dirattr: dirMountStatus,
            fileattr: fileLinkCount | fileAllocSize,
            forkattr: extCloneID | extFlags
        )
        var options = optExtendedCommon
        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var entries: [Entry] = []

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, options)
            if count < 0 {
                // Some file systems refuse the extended attributes: retry without.
                if errno == EINVAL, options != 0, entries.isEmpty {
                    options = 0
                    request.forkattr = 0
                    continue
                }
                return entries.isEmpty ? nil : entries
            }
            if count == 0 { break }

            var offset = 0
            for _ in 0..<count {
                let start = buffer + offset
                let length = Int(start.loadUnaligned(as: UInt32.self))
                offset += length
                if let entry = parse(start, length: length) { entries.append(entry) }
            }
        }
        return entries
    }

    /// Reads one record. Fields come in a fixed order: the returned set, the
    /// error (only when present), then common, directory, file and extended
    /// attributes in bit order.
    private static func parse(_ record: UnsafeMutableRawPointer, length: Int) -> Entry? {
        var cursor = 4
        func u32() -> UInt32 {
            defer { cursor += 4 }
            return cursor + 4 <= length ? record.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) : 0
        }
        func u64() -> UInt64 {
            defer { cursor += 8 }
            return cursor + 8 <= length ? record.loadUnaligned(fromByteOffset: cursor, as: UInt64.self) : 0
        }

        let common = u32()
        _ = u32() // volume
        let dir = u32()
        let file = u32()
        let ext = u32()

        if common & cmnError != 0, u32() != 0 { return nil }

        var name = ""
        if common & cmnName != 0 {
            let reference = cursor
            let nameOffset = Int(Int32(bitPattern: u32()))
            let nameLength = Int(u32())
            let nameStart = reference + nameOffset
            if nameStart >= 0, nameLength > 0, nameStart + nameLength <= length {
                let bytes = UnsafeRawBufferPointer(start: record + nameStart, count: nameLength)
                name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        guard !name.isEmpty else { return nil }

        let device = common & cmnDevID != 0 ? Int32(bitPattern: u32()) : 0
        let objectType = common & cmnObjType != 0 ? u32() : 0
        let bsdFlags = common & cmnFlags != 0 ? u32() : 0
        let fileID = common & cmnFileID != 0 ? u64() : 0
        let mountStatus = dir & dirMountStatus != 0 ? u32() : 0
        let links = file & fileLinkCount != 0 ? u32() : 1
        var allocated = file & fileAllocSize != 0 ? Int64(bitPattern: u64()) : 0
        let cloneID = ext & extCloneID != 0 ? u64() : 0
        let flags = ext & extFlags != 0 ? u64() : 0

        let dataless = bsdFlags & datalessFlag != 0
        if dataless { allocated = 0 }

        let kind: EntryKind
        switch objectType {
        case 2 /* VDIR */: kind = mountStatus & mountPointStatus != 0 ? .mountPoint : .directory
        case 1 /* VREG */: kind = .file
        case 5 /* VLNK */: kind = .symlink
        default: kind = .other
        }
        return Entry(
            name: name,
            kind: kind,
            allocated: allocated,
            device: device,
            fileID: fileID,
            linkCount: links,
            cloneID: cloneID != 0 && flags & sharesAllBlocks != 0 ? cloneID : nil,
            isDataless: dataless
        )
    }

    // MARK: Fallback

    private static func listWithStat(_ path: String) -> [Entry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        var parent = stat()
        let parentDevice = lstat(path, &parent) == 0 ? parent.st_dev : 0
        return names.compactMap { name in
            var info = stat()
            guard lstat((path as NSString).appendingPathComponent(name), &info) == 0 else { return nil }
            let dataless = info.st_flags & datalessFlag != 0
            let kind: EntryKind
            switch info.st_mode & S_IFMT {
            case S_IFDIR: kind = info.st_dev != parentDevice ? .mountPoint : .directory
            case S_IFREG: kind = .file
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }
            return Entry(
                name: name,
                kind: kind,
                allocated: dataless ? 0 : Int64(info.st_blocks) * 512,
                device: info.st_dev,
                fileID: info.st_ino,
                linkCount: UInt32(info.st_nlink),
                cloneID: nil,
                isDataless: dataless
            )
        }
    }

    // MARK: Volumes

    static func device(of path: String) -> Int32? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : nil
    }

    /// Capacity and space available to apps, from the file system itself.
    static func volumeSpace(_ path: String) -> (total: Int64, available: Int64)? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let block = Int64(info.f_bsize)
        return (Int64(info.f_blocks) * block, Int64(info.f_bavail) * block)
    }

    /// True when `path` is where a volume is mounted, so the volume's own
    /// used-space figure describes it.
    static func isVolumeRoot(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountPoint = withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (mountPoint as NSString).standardizingPath == (path as NSString).standardizingPath
    }

    /// The other mounted APFS volumes sharing `root`'s container (VM, Preboot,
    /// Update…), with the space each uses. Those bytes count as "used" on this
    /// volume but sit in no file a scan can reach.
    static func siblingVolumes(of root: String, excluding scanned: Set<Int32>) -> [(name: String, bytes: Int64)] {
        func text<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        func container(_ mount: statfs) -> String? {
            guard text(mount.f_fstypename) == "apfs" else { return nil }
            let source = text(mount.f_mntfromname)
            guard source.hasPrefix("/dev/disk") else { return nil }
            let digits = source.dropFirst("/dev/disk".count).prefix { $0.isNumber }
            return digits.isEmpty ? nil : String(digits)
        }

        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
        let all = Array(UnsafeBufferPointer(start: mounts, count: Int(count)))
        let rootPath = (root as NSString).standardizingPath
        guard let own = all.first(where: { text($0.f_mntonname) == rootPath }).flatMap(container) else { return [] }

        var parts: [(String, Int64)] = []
        for mount in all where container(mount) == own {
            let path = text(mount.f_mntonname)
            guard let device = device(of: path), !scanned.contains(device),
                  let used = volumeSpaceUsed(path), used > 0 else { continue }
            parts.append(((path as NSString).lastPathComponent, used))
        }
        return parts
    }

    private static func volumeSpaceUsed(_ path: String) -> Int64? {
        let volInfo: UInt32 = 0x8000_0000
        let spaceUsed: UInt32 = 0x0080_0000
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0,
                               volattr: volInfo | spaceUsed, dirattr: 0, fileattr: 0, forkattr: 0)
        var buffer = [UInt8](repeating: 0, count: 16)
        let result = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, 0)
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { Int64(bitPattern: $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self)) }
    }
}
