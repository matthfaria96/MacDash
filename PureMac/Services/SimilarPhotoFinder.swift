import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SimilarPhotoScanLimits: Hashable, Sendable {
    let maxPhotos: Int
    let maxEntries: Int

    static let standard = SimilarPhotoScanLimits(maxPhotos: 500, maxEntries: 10_000)
}

struct SimilarPhoto: Identifiable, Sendable {
    let url: URL
    let size: Int64
    let modifiedAt: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let thumbnailData: Data

    var id: URL { url }
}

struct SimilarPhotoGroup: Identifiable, Sendable {
    let photos: [SimilarPhoto]
    let similarity: Double

    var id: URL { photos[0].url }
    var totalSize: Int64 { photos.reduce(0) { $0 + $1.size } }
}

struct SimilarPhotoScanResult: Sendable {
    let folder: URL
    let groups: [SimilarPhotoGroup]
    let entriesVisited: Int
    let candidatesFound: Int
    let photosAnalyzed: Int
    let skippedItems: Int
    let photoLimitReached: Bool
    let entryLimitReached: Bool

    var matchedPhotoCount: Int { groups.reduce(0) { $0 + $1.photos.count } }
    var matchedPhotoSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    var isPartial: Bool { photoLimitReached || entryLimitReached }
}

struct SimilarPhotoScanProgress: Hashable, Sendable {
    enum Phase: Hashable, Sendable {
        case discovering
        case analyzing
        case comparing
    }

    let phase: Phase
    let entriesVisited: Int
    let candidatesFound: Int
    let photosAnalyzed: Int
    let currentURL: URL?
}

enum SimilarPhotoFinderError: LocalizedError, Equatable {
    case invalidFolder(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolder(let path):
            return String(localized: "The selected folder cannot be scanned: \(path)")
        }
    }
}

actor SimilarPhotoFinder {
    typealias ProgressHandler = @Sendable (SimilarPhotoScanProgress) async -> Void
    typealias GroupsHandler = @Sendable ([SimilarPhotoGroup]) async -> Void

    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct Candidate: Sendable {
        let url: URL
        let identity: FileIdentity
        let modifiedAt: Date?
    }

    private struct Signature: Sendable {
        let differenceHash: UInt64
        let averageHash: UInt64
        let red: Double
        let green: Double
        let blue: Double
        let aspectRatio: Double
    }

    private struct AnalyzedPhoto: Sendable {
        let photo: SimilarPhoto
        let signature: Signature
    }

    private static let supportedExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    private let fileManager: FileManager
    private let limits: SimilarPhotoScanLimits

    init(fileManager: FileManager = .default, limits: SimilarPhotoScanLimits = .standard) {
        self.fileManager = fileManager
        self.limits = limits
    }

    func scan(
        folder rawFolder: URL,
        progress: @escaping ProgressHandler = { _ in },
        foundGroups: GroupsHandler? = nil
    ) async throws -> SimilarPhotoScanResult {
        let folder = rawFolder.standardizedFileURL
        guard Self.isDirectory(at: folder),
              !Self.isSymbolicLink(at: folder),
              !Self.isPackage(at: folder),
              !Self.isCloudPlaceholder(at: folder) else {
            throw SimilarPhotoFinderError.invalidFolder(folder.path)
        }

        var candidates: [Candidate] = []
        var entriesVisited = 0
        var skippedItems = 0
        var photoLimitReached = false
        var entryLimitReached = false
        let keys: [URLResourceKey] = [
            .contentModificationDateKey,
            .isPackageKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                skippedItems += 1
                return true
            }
        ) else {
            throw SimilarPhotoFinderError.invalidFolder(folder.path)
        }

        while let rawURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if entriesVisited >= limits.maxEntries {
                entryLimitReached = true
                break
            }
            entriesVisited += 1
            let url = rawURL.standardizedFileURL

            if Self.isSymbolicLink(at: url) {
                enumerator.skipDescendants()
                skippedItems += 1
                continue
            }
            if Self.isPackage(at: url) {
                enumerator.skipDescendants()
                skippedItems += 1
                continue
            }
            if Self.isCloudPlaceholder(at: url) {
                enumerator.skipDescendants()
                skippedItems += 1
                continue
            }
            guard Self.isRegularFile(at: url),
                  Self.supportedExtensions.contains(url.pathExtension.lowercased()),
                  let identity = Self.identity(at: url) else {
                continue
            }
            if candidates.count >= limits.maxPhotos {
                photoLimitReached = true
                break
            }

            let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            candidates.append(Candidate(url: url, identity: identity, modifiedAt: modifiedAt))

            if candidates.count == 1 || candidates.count.isMultiple(of: 20) {
                await progress(SimilarPhotoScanProgress(
                    phase: .discovering,
                    entriesVisited: entriesVisited,
                    candidatesFound: candidates.count,
                    photosAnalyzed: 0,
                    currentURL: url
                ))
            }
        }

        let orderedCandidates = candidates.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        var analyzed: [AnalyzedPhoto] = []
        analyzed.reserveCapacity(orderedCandidates.count)
        // Groups form while photos are analyzed: each new photo joins the first
        // group whose first photo it matches, or pairs up with an unmatched one.
        var clusters: [(members: [Int], scores: [Double])] = []
        var singles: [Int] = []
        let batchSize = 8

        for start in stride(from: 0, to: orderedCandidates.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(orderedCandidates[start..<min(start + batchSize, orderedCandidates.count)])
            // Thumbnails and signatures for a batch are built in parallel.
            let results = await withTaskGroup(of: (Int, AnalyzedPhoto?).self) { group -> [AnalyzedPhoto?] in
                for (offset, candidate) in batch.enumerated() {
                    group.addTask {
                        guard let photo = Self.analyze(candidate), Self.identity(at: candidate.url) == candidate.identity else {
                            return (offset, nil)
                        }
                        return (offset, photo)
                    }
                }
                var ordered = [AnalyzedPhoto?](repeating: nil, count: batch.count)
                for await (offset, photo) in group { ordered[offset] = photo }
                return ordered
            }

            let groupCountBefore = clusters.count
            var grewGroup = false
            for photo in results {
                guard let photo else { skippedItems += 1; continue }
                let index = analyzed.count
                analyzed.append(photo)
                if let cluster = clusters.firstIndex(where: { Self.similarity(analyzed[$0.members[0]].signature, photo.signature) != nil }),
                   let score = Self.similarity(analyzed[clusters[cluster].members[0]].signature, photo.signature) {
                    clusters[cluster].members.append(index)
                    clusters[cluster].scores.append(score)
                    grewGroup = true
                } else if let single = singles.firstIndex(where: { Self.similarity(analyzed[$0].signature, photo.signature) != nil }),
                          let score = Self.similarity(analyzed[singles[single]].signature, photo.signature) {
                    clusters.append((members: [singles[single], index], scores: [score]))
                    singles.remove(at: single)
                } else {
                    singles.append(index)
                }
            }

            if let foundGroups, clusters.count != groupCountBefore || grewGroup {
                await foundGroups(Self.groups(from: clusters, photos: analyzed))
            }
            await progress(SimilarPhotoScanProgress(
                phase: .analyzing,
                entriesVisited: entriesVisited,
                candidatesFound: orderedCandidates.count,
                photosAnalyzed: analyzed.count,
                currentURL: batch.last?.url
            ))
        }

        try Task.checkCancellation()
        let groups = Self.groups(from: clusters, photos: analyzed)

        return SimilarPhotoScanResult(
            folder: folder,
            groups: groups,
            entriesVisited: entriesVisited,
            candidatesFound: candidates.count,
            photosAnalyzed: analyzed.count,
            skippedItems: skippedItems,
            photoLimitReached: photoLimitReached,
            entryLimitReached: entryLimitReached
        )
    }

    private static func analyze(_ candidate: Candidate) -> AnalyzedPhoto? {
        guard let source = CGImageSourceCreateWithURL(candidate.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = number(properties[kCGImagePropertyPixelWidth]),
              let height = number(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0 else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let signature = signature(for: thumbnail, aspectRatio: Double(width) / Double(height)),
              let thumbnailData = encodeThumbnail(thumbnail) else {
            return nil
        }
        let photo = SimilarPhoto(
            url: candidate.url,
            size: candidate.identity.size,
            modifiedAt: candidate.modifiedAt,
            pixelWidth: width,
            pixelHeight: height,
            thumbnailData: thumbnailData
        )
        return AnalyzedPhoto(photo: photo, signature: signature)
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        return nil
    }

    private static func signature(for image: CGImage, aspectRatio: Double) -> Signature? {
        guard let gray = grayscalePixels(image, width: 9, height: 8),
              let averageGray = grayscalePixels(image, width: 8, height: 8),
              let colors = colorPixels(image, width: 8, height: 8) else {
            return nil
        }

        var differenceHash: UInt64 = 0
        var differenceBit = 0
        for row in 0..<8 {
            for column in 0..<8 {
                if gray[row * 9 + column] > gray[row * 9 + column + 1] {
                    differenceHash |= UInt64(1) << UInt64(differenceBit)
                }
                differenceBit += 1
            }
        }

        let average = averageGray.reduce(0) { $0 + Int($1) } / 64
        var averageHash: UInt64 = 0
        for index in 0..<64 where Int(averageGray[index]) >= average {
            averageHash |= UInt64(1) << UInt64(index)
        }

        var red = 0.0
        var green = 0.0
        var blue = 0.0
        for index in 0..<64 {
            red += Double(colors[index * 4])
            green += Double(colors[index * 4 + 1])
            blue += Double(colors[index * 4 + 2])
        }

        return Signature(
            differenceHash: differenceHash,
            averageHash: averageHash,
            red: red / (64 * 255),
            green: green / (64 * 255),
            blue: blue / (64 * 255),
            aspectRatio: aspectRatio
        )
    }

    private static func grayscalePixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func colorPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func encodeThumbnail(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func groups(from clusters: [(members: [Int], scores: [Double])], photos: [AnalyzedPhoto]) -> [SimilarPhotoGroup] {
        clusters.map { cluster in
            let members = cluster.members
                .map { photos[$0].photo }
                .sorted {
                    if $0.modifiedAt != $1.modifiedAt {
                        return ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
                    }
                    return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
            return SimilarPhotoGroup(photos: members, similarity: cluster.scores.min() ?? 1)
        }
        .sorted {
            if $0.totalSize != $1.totalSize { return $0.totalSize > $1.totalSize }
            return $0.id.path.localizedStandardCompare($1.id.path) == .orderedAscending
        }
    }

    private static func similarity(_ lhs: Signature, _ rhs: Signature) -> Double? {
        let aspectDifference = abs(lhs.aspectRatio - rhs.aspectRatio) / max(lhs.aspectRatio, rhs.aspectRatio)
        guard aspectDifference <= 0.12 else { return nil }

        let differenceDistance = (lhs.differenceHash ^ rhs.differenceHash).nonzeroBitCount
        let averageDistance = (lhs.averageHash ^ rhs.averageHash).nonzeroBitCount
        let colorDistance = sqrt(
            pow(lhs.red - rhs.red, 2) +
            pow(lhs.green - rhs.green, 2) +
            pow(lhs.blue - rhs.blue, 2)
        ) / sqrt(3)
        guard differenceDistance <= 10, averageDistance <= 10, colorDistance <= 0.28 else { return nil }

        let score = 1 - (
            0.45 * Double(differenceDistance) / 64 +
            0.35 * Double(averageDistance) / 64 +
            0.20 * colorDistance
        )
        return score >= 0.84 ? score : nil
    }

    private static func identity(at url: URL) -> FileIdentity? {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return nil }
        return FileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: Int64(information.st_size),
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
    }

    private static func isRegularFile(at url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
    }

    private static func isDirectory(at url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFDIR
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFLNK
    }

    private static func isPackage(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    private static func isCloudPlaceholder(at url: URL) -> Bool {
        if url.pathExtension.lowercased() == "icloud" { return true }
        var information = stat()
        if lstat(url.path, &information) == 0 && information.st_flags & UInt32(SF_DATALESS) != 0 {
            return true
        }
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]) else {
            return false
        }
        return values.isUbiquitousItem == true &&
            values.ubiquitousItemDownloadingStatus != .current &&
            values.ubiquitousItemDownloadingStatus != .downloaded
    }
}
