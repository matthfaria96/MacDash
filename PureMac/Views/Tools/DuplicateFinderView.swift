import AppKit
import SwiftUI

struct DuplicateFinderView: View {
    private enum ScreenState: Equatable {
        case idle
        case scanning
        case finished
        case failed(String)
    }

    private let finder: DuplicateFinder
    @State private var state: ScreenState = .idle
    @State private var result: DuplicateScanResult?
    @State private var selectedFolder: URL?
    @State private var location: ScanLocation = .startupDisk
    @State private var progress = DuplicateScanProgress(
        phase: .discovering,
        filesInspected: 0,
        filesToHash: 0,
        filesHashed: 0,
        bytesHashed: 0,
        currentURL: nil
    )
    @State private var selectedIDs: Set<URL> = []
    /// Groups confirmed so far, shown while the scan keeps going.
    @State private var liveGroups: [DuplicateGroup] = []
    @State private var expandedGroupIDs: Set<String> = []
    @State private var scanGeneration = UUID()
    @State private var scanTask: Task<Void, Never>?
    @State private var trashTask: Task<Void, Never>?
    @State private var isMovingToTrash = false
    @State private var showsTrashConfirmation = false
    @State private var actionMessage: ActionMessage?

    init(finder: DuplicateFinder = DuplicateFinder()) {
        self.finder = finder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            if result?.groups.isEmpty == false {
                selectionBar
            }
        }
        .padding(24)
        .frame(maxWidth: 1040, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Move selected duplicates to Trash?",
            isPresented: $showsTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                moveSelectedToTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedIDs.count) files totaling \(format(selectedSize)) will be moved to Trash. The protected copy in every group stays in place.")
        }
        .alert(item: $actionMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.detail),
                dismissButton: .default(Text("OK"))
            )
        }
        .onDisappear {
            scanGeneration = UUID()
            scanTask?.cancel()
            trashTask?.cancel()
        }
    }

    private var header: some View {
        FeaturePageHeader(
            title: Text("Duplicate Finder"),
            systemImage: "doc.on.doc.fill",
            tint: SectionPalette.duplicates.accent,
            detail: {
                Text(headerSubtitle)
                    .lineLimit(2)
                    .truncationMode(.middle)
            },
            accessory: {
                if state == .scanning {
                    StopActionButton { scanTask?.cancel() }
                        .accessibilityHint("Stops scanning without changing any files")
                } else if state != .idle {
                    StartOverButton { resetToIdle() }
                        .disabled(isMovingToTrash)
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            idleState
        case .scanning:
            scanningState
        case .failed(let message):
            failureState(message)
        case .finished:
            if let result, result.groups.isEmpty {
                emptyResult(result)
            } else if let result {
                resultContent(result)
            } else {
                idleState
            }
        }
    }

    private var idleState: some View {
        CardSurface(padding: 0, elevation: .flat) {
            VStack(spacing: 15) {
                Spacer()
                GlassOrbIcon(systemImage: "doc.text.magnifyingglass", tint: SectionPalette.duplicates.accent, size: 150)
                Text("Find copies that are exactly the same")
                    .font(.system(size: 18, weight: .semibold))
                Text("Choose where to look. MacFresh compares file sizes first, then verifies matching files byte for byte. Nothing is selected or removed automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                ScanLocationPicker(selection: $location, tint: SectionPalette.duplicates.accent, isDisabled: isMovingToTrash)
                    .padding(.top, 6)
                Button {
                    startScan(location.url)
                } label: {
                    Label("Analyze", systemImage: "magnifyingglass")
                        .padding(.horizontal, 14)
                }
                .buttonStyle(GlassProminentButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(isMovingToTrash)
                .padding(.top, 2)
                Text("This can take a while.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Until the first match is confirmed, the progress ring; after that, a
    /// slim progress line and the groups found so far, growing as the scan goes.
    @ViewBuilder
    private var scanningState: some View {
        if liveGroups.isEmpty {
            scanningRing
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progressSummary)
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text(String(format: String(localized: "%lld groups so far · %@ to reclaim"),
                                    Int64(liveGroups.count),
                                    format(liveGroups.reduce(0) { $0 + $1.reclaimableSize })))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    if let fraction = progress.fractionCompleted {
                        GlowProgressBar(progress: fraction, tint: SectionPalette.duplicates.accent)
                            .frame(width: 160, height: 6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(GlassPanelBackground(cornerRadius: 16))

                CardSurface(padding: 0, elevation: .flat) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(liveGroups) { group in
                                HStack(spacing: 12) {
                                    Image(nsImage: IconCache.icon(forFile: group.keeper.url.path))
                                        .resizable()
                                        .frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.keeper.url.lastPathComponent)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(String(format: String(localized: "%lld copies"), Int64(group.files.count)))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(format(group.reclaimableSize))
                                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .transition(.opacity)
                                Divider().opacity(0.3).padding(.leading, 56)
                            }
                        }
                    }
                }
            }
        }
    }

    private var scanningRing: some View {
        CardSurface(padding: 28, elevation: .flat, tint: SectionPalette.duplicates.accent) {
            VStack(spacing: 20) {
                Spacer()
                ZStack {
                    Circle()
                        .stroke(SectionPalette.duplicates.accent.opacity(0.14), lineWidth: 9)
                        .frame(width: 104, height: 104)
                    if let fraction = progress.fractionCompleted {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(SectionPalette.duplicates.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 104, height: 104)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(SectionPalette.duplicates.accent)
                    }
                    Image(systemName: progress.phase == .discovering ? "folder" : "number")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(SectionPalette.duplicates.accent)
                }
                VStack(spacing: 7) {
                    Text(progress.phase == .discovering ? "Looking through files" : "Verifying possible matches")
                        .font(.system(size: 18, weight: .semibold))
                    Text(progressSummary)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let currentURL = progress.currentURL {
                        Text(currentURL.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 520)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(progressSummary)
        }
    }

    private func failureState(_ message: String) -> some View {
        CardSurface(padding: 0, elevation: .flat, tint: Tint.red) {
            VStack(spacing: 14) {
                Spacer()
                GlassOrbIcon(systemImage: "exclamationmark.triangle.fill", tint: Tint.red, size: 78)
                Text("Scan could not finish")
                    .font(.system(size: 18, weight: .semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                HStack {
                    if let folder = selectedFolder {
                        Button("Try Again") { startScan(folder) }
                            .buttonStyle(GlassProminentButtonStyle())
                            .tint(SectionPalette.duplicates.accent)
                            .disabled(isMovingToTrash)
                    }
                    Button("Change Location") { resetToIdle() }
                        .buttonStyle(GlassButtonStyle())
                        .disabled(isMovingToTrash)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyResult(_ result: DuplicateScanResult) -> some View {
        CardSurface(padding: 0, elevation: .flat, tint: Tint.green) {
            VStack(spacing: 14) {
                Spacer()
                GlassOrbIcon(systemImage: "checkmark.seal.fill", tint: Tint.green, size: 84)
                Text("No exact duplicates found")
                    .font(.system(size: 19, weight: .semibold))
                Text("Inspected \(result.filesInspected.formatted()) files in \(result.folder.lastPathComponent). \(skippedSummary(result.skippedFiles))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resultContent(_ result: DuplicateScanResult) -> some View {
        VStack(spacing: 14) {
            summaryCard(result)
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(result.groups) { group in
                        groupCard(group)
                    }
                    if !result.skippedFiles.isEmpty {
                        skippedCard(result.skippedFiles)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryCard(_ result: DuplicateScanResult) -> some View {
        CardSurface(padding: 14, elevation: .flat) {
            HStack(spacing: 0) {
                summaryMetric(value: result.groups.count.formatted(), label: "Duplicate groups", icon: "square.stack.3d.up", tint: SectionPalette.duplicates.accent)
                Divider().frame(height: 38)
                summaryMetric(value: result.duplicateFileCount.formatted(), label: "Matching files", icon: "doc.on.doc", tint: Tint.purple)
                Divider().frame(height: 38)
                summaryMetric(value: format(result.reclaimableSize), label: "Available to review", icon: "internaldrive", tint: Tint.green)
                Spacer(minLength: 10)
            }
        }
    }

    private func summaryMetric(value: String, label: LocalizedStringKey, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            CategoryBadge(systemName: icon, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        CardSurface(padding: 0, elevation: .flat, tint: SectionPalette.duplicates.accent) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CategoryBadge(systemName: "doc.on.doc.fill", tint: SectionPalette.duplicates.accent, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.keeper.url.lastPathComponent)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text("\(group.files.count) exact copies · \(format(group.fileSize)) each")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusChip(label: String(localized: "\(format(group.reclaimableSize)) reviewable"), systemImage: "arrow.down.circle", tint: Tint.green)
                    Button(groupCandidatesSelected(group) ? "Clear" : "Select copies") {
                        toggleGroupSelection(group)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(isMovingToTrash)
                    Button {
                        toggleExpanded(group)
                    } label: {
                        Image(systemName: expandedGroupIDs.contains(group.id) ? "chevron.up" : "chevron.down")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expandedGroupIDs.contains(group.id) ? "Collapse duplicate group" : "Expand duplicate group")
                }
                .padding(14)

                if expandedGroupIDs.contains(group.id) {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                            fileRow(file, keeper: index == 0)
                            if index < group.files.count - 1 {
                                Divider().padding(.leading, 49)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func fileRow(_ file: DuplicateFile, keeper: Bool) -> some View {
        HStack(spacing: 11) {
            if keeper {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tint.green)
                    .frame(width: 18)
                    .accessibilityLabel("Protected copy")
            } else {
                Toggle("", isOn: selectionBinding(for: file.url))
                    .labelsHidden()
                    .toggleStyle(AnimatedCheckboxStyle(tint: SectionPalette.duplicates.accent))
                    .disabled(isMovingToTrash)
                    .accessibilityLabel("Select \(file.url.lastPathComponent)")
            }
            FileIcon(path: file.url.path, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(file.url.lastPathComponent)
                        .font(.system(size: 13, weight: keeper ? .semibold : .regular))
                        .lineLimit(1)
                    if keeper {
                        StatusChip(label: String(localized: "Keep"), systemImage: "lock.fill", tint: Tint.green)
                    }
                }
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let modifiedAt = file.modifiedAt {
                Text(modifiedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "arrow.forward.square")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reveal \(file.url.lastPathComponent) in Finder")
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private func skippedCard(_ skippedFiles: [DuplicateSkippedFile]) -> some View {
        CardSurface(padding: 14, elevation: .flat, tint: Tint.orange) {
            DisclosureGroup {
                VStack(spacing: 8) {
                    ForEach(skippedFiles) { file in
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(Tint.orange)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.url.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(file.detail.map { "\(file.reason.label): \($0)" } ?? file.reason.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            } label: {
                                Image(systemName: "arrow.forward.square")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Reveal skipped item in Finder")
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack {
                    CategoryBadge(systemName: "exclamationmark.triangle", tint: Tint.orange, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Skipped items")
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(skippedFiles.count) unsafe or unavailable items were not scanned")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var selectionBar: some View {
        CardSurface(padding: 14, elevation: .raised, tint: selectedIDs.isEmpty ? nil : SectionPalette.duplicates.accent) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedIDs.isEmpty ? "Nothing selected" : "\(selectedIDs.count) selected")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    Text(selectedIDs.isEmpty ? "Select the extra copies you want to review" : "\(format(selectedSize)) will move to Trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !selectedIDs.isEmpty {
                    Button("Clear Selection") { selectedIDs.removeAll() }
                        .buttonStyle(.borderless)
                        .disabled(isMovingToTrash)
                }
                Button {
                    showsTrashConfirmation = true
                } label: {
                    if isMovingToTrash {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 100)
                    } else {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
                .buttonStyle(GlassProminentButtonStyle())
                .tint(Tint.red)
                .disabled(selectedIDs.isEmpty || isMovingToTrash || state == .scanning)
                .accessibilityHint("Shows a confirmation before moving the selected copies")
            }
        }
    }

    private var headerSubtitle: String {
        if state == .scanning, let current = progress.currentURL {
            return current.deletingLastPathComponent().path
        }
        return selectedFolder?.path ?? String(localized: "Identical file cleanup")
    }

    private var progressSummary: String {
        switch progress.phase {
        case .discovering:
            return String(localized: "\(progress.filesInspected.formatted()) files inspected")
        case .hashing:
            return String(localized: "\(progress.filesHashed.formatted()) of \(progress.filesToHash.formatted()) candidates · \(format(progress.bytesHashed)) verified")
        }
    }

    private var selectedSize: Int64 {
        guard let result else { return 0 }
        return result.groups
            .flatMap(\.files)
            .filter { selectedIDs.contains($0.url) }
            .reduce(0) { $0 + $1.size }
    }

    private func selectionBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(url) },
            set: { selected in
                if selected {
                    selectedIDs.insert(url)
                } else {
                    selectedIDs.remove(url)
                }
            }
        )
    }

    private func groupCandidatesSelected(_ group: DuplicateGroup) -> Bool {
        group.files.dropFirst().allSatisfy { selectedIDs.contains($0.url) }
    }

    private func toggleGroupSelection(_ group: DuplicateGroup) {
        let candidateIDs = Set(group.files.dropFirst().map(\.url))
        if candidateIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(candidateIDs)
        } else {
            selectedIDs.formUnion(candidateIDs)
        }
    }

    private func toggleExpanded(_ group: DuplicateGroup) {
        withAnimation(MotionTokens.gentle) {
            if expandedGroupIDs.contains(group.id) {
                expandedGroupIDs.remove(group.id)
            } else {
                expandedGroupIDs.insert(group.id)
            }
        }
    }

    private func startScan(_ folder: URL) {
        guard !isMovingToTrash else { return }
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        selectedFolder = folder
        selectedIDs.removeAll()
        expandedGroupIDs.removeAll()
        result = nil
        liveGroups = []
        progress = DuplicateScanProgress(
            phase: .discovering,
            filesInspected: 0,
            filesToHash: 0,
            filesHashed: 0,
            bytesHashed: 0,
            currentURL: folder
        )
        state = .scanning
        scanTask = Task { @MainActor in
            let usesScopedAccess = folder.startAccessingSecurityScopedResource()
            defer {
                if usesScopedAccess {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let scanResult = try await finder.scan(folder: folder, progress: { update in
                    await MainActor.run {
                        guard scanGeneration == generation else { return }
                        progress = update
                    }
                }, foundGroups: { groups in
                    await MainActor.run {
                        guard scanGeneration == generation else { return }
                        withAnimation(.easeOut(duration: 0.25)) { liveGroups = groups }
                    }
                })
                try Task.checkCancellation()
                guard scanGeneration == generation else { return }
                result = scanResult
                UsageStats.shared.recordScan(.duplicates, filesChecked: scanResult.filesInspected)
                expandedGroupIDs = Set(scanResult.groups.prefix(3).map(\.id))
                state = .finished
            } catch is CancellationError {
                guard scanGeneration == generation else { return }
                state = .idle
            } catch {
                guard scanGeneration == generation else { return }
                state = .failed(error.localizedDescription)
            }
            if scanGeneration == generation {
                scanTask = nil
            }
        }
    }

    private func resetToIdle() {
        guard !isMovingToTrash else { return }
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        state = .idle
        result = nil
        selectedFolder = nil
        selectedIDs.removeAll()
        expandedGroupIDs.removeAll()
        progress = DuplicateScanProgress(
            phase: .discovering,
            filesInspected: 0,
            filesToHash: 0,
            filesHashed: 0,
            bytesHashed: 0,
            currentURL: nil
        )
    }

    private func moveSelectedToTrash() {
        guard let currentResult = result, !selectedIDs.isEmpty else { return }
        let generation = scanGeneration
        let folder = currentResult.folder
        let selectionSnapshot = selectedIDs
        isMovingToTrash = true
        trashTask = Task { @MainActor in
            let usesScopedAccess = currentResult.folder.startAccessingSecurityScopedResource()
            defer {
                if usesScopedAccess {
                    currentResult.folder.stopAccessingSecurityScopedResource()
                }
                if scanGeneration == generation {
                    isMovingToTrash = false
                    trashTask = nil
                }
            }
            var movedFiles: [DuplicateFile] = []
            var failures: [String] = []
            for group in currentResult.groups {
                if Task.isCancelled { return }
                let groupSelection = selectionSnapshot.filter { group.contains($0) }
                guard !groupSelection.isEmpty else { continue }
                do {
                    let report = try await finder.moveToTrash(group: group, selectedIDs: groupSelection)
                    movedFiles.append(contentsOf: report.trashedFiles)
                    failures.append(contentsOf: report.failures.map { "\($0.url.lastPathComponent): \($0.message)" })
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            guard scanGeneration == generation,
                  selectedFolder == folder,
                  result?.folder == folder,
                  !Task.isCancelled else { return }
            applyTrashResult(movedFiles)
            if !movedFiles.isEmpty {
                UsageStats.shared.recordCleanup(.duplicates, bytes: movedFiles.reduce(0) { $0 + $1.size })
            }
            if failures.isEmpty {
                actionMessage = ActionMessage(
                    title: String(localized: "Moved to Trash"),
                    detail: String(localized: "\(movedFiles.count) files totaling \(format(movedFiles.reduce(0) { $0 + $1.size })) were moved. Every protected copy remains in place.")
                )
            } else {
                actionMessage = ActionMessage(
                    title: movedFiles.isEmpty ? String(localized: "Nothing was moved") : String(localized: "Some files were not moved"),
                    detail: failures.joined(separator: "\n")
                )
            }
        }
    }

    private func applyTrashResult(_ movedFiles: [DuplicateFile]) {
        guard let currentResult = result else { return }
        let movedIDs = Set(movedFiles.map(\.url))
        let remainingGroups = currentResult.groups.compactMap { group -> DuplicateGroup? in
            let remaining = group.files.filter { !movedIDs.contains($0.url) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(digest: group.digest, files: remaining)
        }
        result = DuplicateScanResult(
            folder: currentResult.folder,
            groups: remainingGroups,
            skippedFiles: currentResult.skippedFiles,
            filesInspected: currentResult.filesInspected,
            bytesHashed: currentResult.bytesHashed
        )
        selectedIDs.subtract(movedIDs)
        expandedGroupIDs.formIntersection(Set(remainingGroups.map(\.id)))
    }

    private func skippedSummary(_ skippedFiles: [DuplicateSkippedFile]) -> String {
        skippedFiles.isEmpty
            ? String(localized: "Every eligible file was checked.")
            : String(localized: "\(skippedFiles.count) unsafe or unavailable items were skipped.")
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct ActionMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}
