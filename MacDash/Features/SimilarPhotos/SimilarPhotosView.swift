import AppKit
import SwiftUI

@MainActor
final class SimilarPhotosViewModel: ObservableObject {
    enum Phase {
        case idle
        case scanning
        case loaded
        case failed(String)
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var folder: URL?
    @Published private(set) var result: SimilarPhotoScanResult?
    @Published private(set) var progress: SimilarPhotoScanProgress?
    /// Groups formed so far, shown while the scan keeps going.
    @Published private(set) var liveGroups: [SimilarPhotoGroup] = []

    private let finder: SimilarPhotoFinder
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()

    init(finder: SimilarPhotoFinder = SimilarPhotoFinder()) {
        self.finder = finder
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    /// Starts analyzing the chosen location.
    func analyze(_ url: URL) {
        startScan(folder: url.standardizedFileURL)
    }

    func rescan() {
        guard let folder else { return }
        startScan(folder: folder)
    }

    func cancel() {
        guard isScanning else { return }
        scanTask?.cancel()
        phase = .cancelled
        progress = nil
    }

    /// Returns to the first screen, as if no folder had been chosen.
    func reset() {
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        folder = nil
        result = nil
        progress = nil
        phase = .idle
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startScan(folder: URL) {
        scanTask?.cancel()
        let id = UUID()
        scanID = id
        self.folder = folder
        result = nil
        liveGroups = []
        progress = SimilarPhotoScanProgress(
            phase: .discovering,
            entriesVisited: 0,
            candidatesFound: 0,
            photosAnalyzed: 0,
            currentURL: folder
        )
        phase = .scanning

        scanTask = Task { [weak self, finder] in
            do {
                let result = try await finder.scan(folder: folder, progress: { [weak self] progress in
                    await self?.receive(progress, scanID: id)
                }, foundGroups: { [weak self] groups in
                    await self?.receive(groups, scanID: id)
                })
                guard let self, self.scanID == id, !Task.isCancelled else { return }
                self.result = result
                UsageStats.shared.recordScan(.similarPhotos, filesChecked: result.entriesVisited)
                self.progress = nil
                self.phase = .loaded
            } catch is CancellationError {
                guard let self, self.scanID == id, self.isScanning else { return }
                self.progress = nil
                self.phase = .cancelled
            } catch {
                guard let self, self.scanID == id else { return }
                self.progress = nil
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func receive(_ groups: [SimilarPhotoGroup], scanID: UUID) {
        guard self.scanID == scanID, isScanning else { return }
        withAnimation(.easeOut(duration: 0.3)) { liveGroups = groups }
    }

    private func receive(_ progress: SimilarPhotoScanProgress, scanID: UUID) {
        guard self.scanID == scanID, isScanning else { return }
        self.progress = progress
    }
}

struct SimilarPhotosView: View {
    @StateObject private var model: SimilarPhotosViewModel
    @State private var location: ScanLocation = .startupDisk

    private let tint = SectionPalette.photos.accent

    init(finder: SimilarPhotoFinder = SimilarPhotoFinder()) {
        _model = StateObject(wrappedValue: SimilarPhotosViewModel(finder: finder))
    }

    /// The start screen is a single card that fills the page, sized like the
    /// Duplicates and Space Lens start screens. Results scroll.
    private var showsStartCard: Bool {
        switch model.phase {
        case .idle: return true
        case .loaded: return model.result == nil
        default: return false
        }
    }

    @ViewBuilder
    private var page: some View {
        if showsStartCard {
            VStack(alignment: .leading, spacing: 16) {
                header
                idleState
            }
            .padding(24)
            .frame(maxWidth: 1040, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    content
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    var body: some View {
        page
        .onDisappear {
            model.cancel()
        }
    }

    private var header: some View {
        FeaturePageHeader(
            title: Text("Similar Photos"),
            systemImage: "photo.stack.fill",
            tint: tint,
            detail: {
                Text("Find visually similar photos")
            },
            accessory: {
                if model.isScanning {
                    StopActionButton { model.cancel() }
                } else if model.folder != nil {
                    StartOverButton { model.reset() }
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idleState
        case .scanning:
            scanningState
        case .loaded:
            if let result = model.result {
                resultView(result)
            } else {
                idleState
            }
        case .failed(let message):
            messageState(
                title: "Photos could not be compared",
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: Tint.orange
            )
        case .cancelled:
            messageState(
                title: "Scan stopped",
                message: String(localized: "No photos were changed. You can scan the folder again at any time."),
                systemImage: "stop.circle",
                tint: .white
            )
        }
    }

    // MARK: Idle

    private var idleState: some View {
        CardSurface(padding: 0, elevation: .flat) {
            VStack(spacing: 15) {
                Spacer()
                GlassOrbIcon(systemImage: "sparkle.magnifyingglass", tint: tint, size: 150)
                Text("Find photos that look alike")
                    .font(.system(size: 18, weight: .semibold))
                Text("MacDash builds small local thumbnails, compares their visual structure and color, then groups likely matches for review.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                ScanLocationPicker(selection: $location, tint: tint)
                    .padding(.top, 6)
                Button {
                    model.analyze(location.url)
                } label: {
                    Label("Analyze", systemImage: "magnifyingglass")
                        .padding(.horizontal, 14)
                }
                .buttonStyle(GlassProminentButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 2)
                Text("Analyzes up to 500 photos per scan. Nothing is uploaded or deleted.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Scanning

    /// Until the first group forms, a calm progress card; then a slim
    /// progress line with the groups appearing underneath as they form.
    @ViewBuilder
    private var scanningState: some View {
        if model.liveGroups.isEmpty {
            scanningCard
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progressTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(progressCounts)
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Text(String(format: String(localized: "%lld groups so far"), Int64(model.liveGroups.count)))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(GlassPanelBackground(cornerRadius: 16))

                LazyVStack(spacing: 8) {
                    ForEach(model.liveGroups) { group in
                        LiveSimilarGroupRow(group: group, tint: tint)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    private var scanningCard: some View {
        VStack(spacing: 22) {
            ProgressView()
                .controlSize(.large)
                .tint(tint)
            VStack(spacing: 6) {
                Text(progressTitle)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(model.progress?.currentURL?.lastPathComponent ?? String(localized: "Preparing visual comparison"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            ProgressView()
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(maxWidth: 360)
            Text(progressCounts)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, minHeight: 340)
        .background(GlassPanelBackground(cornerRadius: 28))
    }

    private var progressCounts: String {
        var parts = [
            String(localized: "\(model.progress?.entriesVisited ?? 0) items"),
            String(localized: "\(model.progress?.candidatesFound ?? 0) photos")
        ]
        if let progress = model.progress, progress.photosAnalyzed > 0 {
            parts.append(String(localized: "\(progress.photosAnalyzed) compared"))
        }
        return parts.joined(separator: "  ·  ")
    }

    private var progressTitle: String {
        switch model.progress?.phase {
        case .discovering, .none:
            return String(localized: "Finding local photos")
        case .analyzing:
            return String(localized: "Building visual signatures")
        case .comparing:
            return String(localized: "Grouping similar shots")
        }
    }

    // MARK: Results

    private func resultView(_ result: SimilarPhotoScanResult) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            summaryStrip(result)

            if result.groups.isEmpty {
                VStack(spacing: 12) {
                    GlassOrbIcon(systemImage: "checkmark.circle.fill", tint: Tint.green, size: 84)
                    Text("No similar groups found")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("The analyzed photos did not meet MacDash's visual similarity threshold.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
                .background(GlassPanelBackground(cornerRadius: 24))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggested groups")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Similarity is a visual estimate, not proof that two files are identical. Use Show in Finder to compare originals at full quality.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                ForEach(Array(result.groups.enumerated()), id: \.element.id) { index, group in
                    SimilarPhotoGroupCard(index: index + 1, group: group, tint: tint, onReveal: model.reveal)
                }
            }
        }
    }

    /// Three big numbers on one glass strip, with a single quiet line below.
    private func summaryStrip(_ result: SimilarPhotoScanResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                stat(value: "\(result.groups.count)", label: "Groups")
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.75, height: 44)
                stat(value: "\(result.matchedPhotoCount)", label: "Matching photos")
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.75, height: 44)
                stat(value: Self.format(result.matchedPhotoSize), label: "Space to review")
            }
            .padding(.vertical, 20)

            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.75)

            HStack(spacing: 8) {
                Image(systemName: result.isPartial ? "exclamationmark.circle" : "checkmark.circle")
                Text(footnote(for: result))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let folder = model.folder {
                    Button {
                        model.reveal(folder)
                    } label: {
                        Text("Show in Finder")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(tint)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(GlassPanelBackground(cornerRadius: 24))
    }

    private func stat(value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private func footnote(for result: SimilarPhotoScanResult) -> String {
        var parts = [String(localized: "\(result.photosAnalyzed) analyzed")]
        if result.skippedItems > 0 { parts.append(String(localized: "\(result.skippedItems) skipped")) }
        parts.append(result.isPartial ? String(localized: "Sample limit reached") : String(localized: "Scan complete"))
        if let folder = model.folder { parts.append((folder.path as NSString).abbreviatingWithTildeInPath) }
        return parts.joined(separator: "  ·  ")
    }

    private func messageState(title: LocalizedStringKey, message: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 14) {
            GlassOrbIcon(systemImage: systemImage, tint: tint, size: 84)
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if model.folder != nil {
                Button("Scan Again") {
                    model.rescan()
                }
                .buttonStyle(GlassProminentButtonStyle(large: true))
            }
        }
        .padding(.vertical, 44)
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(GlassPanelBackground(cornerRadius: 28))
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One group of look-alike photos on its own glass panel.
private struct SimilarPhotoGroupCard: View {
    let index: Int
    let group: SimilarPhotoGroup
    let tint: Color
    let onReveal: (URL) -> Void

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Group \(index)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(group.photos.count) photos · \(Self.format(group.totalSize))")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("\(Int((group.similarity * 100).rounded()))% match")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(group.photos) { photo in
                    SimilarPhotoTile(photo: photo, onReveal: { onReveal(photo.url) })
                }
            }
        }
        .padding(20)
        .background(GlassPanelBackground(cornerRadius: 24))
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A large photo with its name and size underneath. "Show in Finder" appears
/// over the photo when the pointer is on it.
private struct SimilarPhotoTile: View {
    let photo: SimilarPhoto
    let onReveal: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.06))
                if let image = NSImage(data: photo.thumbnailData) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.35))
                }
                if hovering {
                    Button(action: onReveal) {
                        Label("Show in Finder", systemImage: "arrow.up.forward.square")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .background(Color.black.opacity(0.35), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                    .accessibilityLabel("Show \(photo.url.lastPathComponent) in Finder")
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.4 : 0.14), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(hovering ? 0.35 : 0.2), radius: hovering ? 14 : 8, y: hovering ? 7 : 4)
            .scaleEffect(hovering ? 1.015 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(photo.url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(photo.url.path)
                Text("\(photo.pixelWidth) × \(photo.pixelHeight) · \(Self.format(photo.size))")
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 2)
        }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show in Finder", action: onReveal)
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A forming group during the scan: a strip of small thumbnails, the count
/// and the size. Light enough to redraw as the group grows.
private struct LiveSimilarGroupRow: View {
    let group: SimilarPhotoGroup
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(group.photos.prefix(6)) { photo in
                    Group {
                        if let image = NSImage(data: photo.thumbnailData) {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                    .frame(width: 56, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
                }
                if group.photos.count > 6 {
                    Text("+\(group.photos.count - 6)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: String(localized: "%lld photos"), Int64(group.photos.count)))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(ByteCountFormatter.string(fromByteCount: group.totalSize, countStyle: .file))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GlassPanelBackground(cornerRadius: 16))
    }
}
