import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drive Offload: moves large folders to an external drive and leaves a link
/// behind, so apps keep finding them. Every move can be turned off again.
struct DriveOffloadView: View {
    var onNavigate: (AppSection) -> Void = { _ in }

    @ObservedObject private var store = DriveOffloadStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingMove: OffloadCandidate?
    @State private var pendingRestore: OffloadRecord?
    @State private var keepCopyOnDrive = false
    @State private var showsBlocked = false
    @State private var showsFormatGuide = false
    @State private var expandedNative: Set<String> = []
    @State private var isDropTargeted = false

    static let symbol = "externaldrive.connected.to.line.below.fill"
    private var accent: Color { SectionPalette.driveOffload.accent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = store.message {
                    NoticeBanner(text: message.text, isError: message.isError) { store.message = nil }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                drivesCard
                if let operation = store.operation, !operation.title.isEmpty {
                    operationCard(operation)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                warnings
                movedSection
                recommendationsSection
                cleanSection
                nativeSection
                blockedSection
                footnote
            }
            .padding(24)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(accent.opacity(0.08)))
                    .overlay(Label("Drop folders to check them", systemImage: "plus.circle.fill").font(.headline))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: store.records)
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: store.operation)
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: store.candidates)
        .onAppear {
            store.refreshVolumes()
            if !store.hasScanned { store.scan() }
        }
        .confirmationDialog(
            "Move to the external drive?",
            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
            titleVisibility: .visible,
            presenting: pendingMove
        ) { candidate in
            Button("Move") { store.move(candidate) }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text(String(format: String(localized: "%@ (%@) will be copied to %@ and checked file by file. Only then is it deleted from the Mac and replaced by a link, so apps find it in the same place. You can bring it back at any time."),
                        candidate.title, DriveOffloadStore.format(candidate.size), store.selectedVolume?.name ?? ""))
        }
        .sheet(item: $pendingRestore) { record in
            restoreSheet(record)
        }
        .alert(item: $store.busyApps) { prompt in
            Alert(
                title: Text("Close these apps first"),
                message: Text(String(format: String(localized: "%@ are using this folder. Moving it while they write could lose data."), prompt.names.joined(separator: ", "))),
                primaryButton: .default(Text("Quit and Continue"), action: prompt.retry),
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        FeaturePageHeader(
            title: Text("Drive Offload"),
            systemImage: Self.symbol,
            tint: accent,
            detail: {
                Text("Move large folders to an external drive. A link stays in their place, so apps don't notice, and every move can be undone.")
            },
            accessory: {
                HStack(spacing: 8) {
                    Button {
                        pickFolders()
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                    }
                    .buttonStyle(GlassButtonStyle())
                    Button {
                        store.scan()
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(store.isScanning || store.operation != nil)
                }
            }
        )
    }

    // MARK: - Drives

    private var drivesCard: some View {
        CardSurface(padding: 18, elevation: .flat, tint: accent) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    driveTile(
                        symbol: "internaldrive.fill",
                        name: String(localized: "This Mac"),
                        free: store.internalFree,
                        total: store.internalTotal,
                        chips: [(String(localized: "Startup disk"), Tint.blue)],
                        tint: Tint.blue
                    )
                    flowArrow
                    if let volume = store.selectedVolume {
                        driveTile(
                            symbol: "externaldrive.fill",
                            name: volume.name,
                            free: volume.availableCapacity,
                            total: volume.totalCapacity,
                            chips: volumeChips(volume),
                            tint: volume.supportsOffload ? accent : Tint.orange,
                            picker: store.volumes.count > 1
                        )
                    } else {
                        noDriveTile
                    }
                }
                if store.offloadedBytes > 0 {
                    Divider().opacity(0.4)
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(accent)
                        Text(String(format: String(localized: "%@ moved off your Mac in %lld folders."),
                                    DriveOffloadStore.format(store.offloadedBytes), Int64(store.records.count)))
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                }
            }
        }
    }

    private func volumeChips(_ volume: OffloadVolume) -> [(String, Color)] {
        var chips: [(String, Color)] = [(volume.fileSystemLabel, volume.supportsOffload ? Tint.green : Tint.orange)]
        if let ssd = volume.isSolidState { chips.append((ssd ? "SSD" : String(localized: "Hard disk"), ssd ? accent : Tint.yellow)) }
        if let bus = volume.busProtocol, !bus.isEmpty { chips.append((bus, Color.white.opacity(0.7))) }
        return chips
    }

    private var flowArrow: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.14))
                .frame(width: 40, height: 40)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
        }
        .accessibilityHidden(true)
    }

    private func driveTile(
        symbol: String, name: String, free: Int64, total: Int64,
        chips: [(String, Color)], tint: Color, picker: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CategoryBadge(systemName: symbol, tint: tint, size: 42)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if picker { volumeMenu }
                }
                if total > 0 {
                    GlowProgressBar(progress: Double(total - free) / Double(total), tint: tint)
                        .frame(height: 6)
                    Text(String(format: String(localized: "%@ free of %@"), DriveOffloadStore.format(free), DriveOffloadStore.format(total)))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    ForEach(chips, id: \.0) { chip in
                        StatusChip(label: chip.0, tint: chip.1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(GlassPanelBackground(cornerRadius: 14))
    }

    private var volumeMenu: some View {
        Menu {
            ForEach(store.volumes) { volume in
                Button {
                    store.selectedVolumeID = volume.id
                } label: {
                    Text("\(volume.name) · \(volume.fileSystemLabel)")
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the drive")
    }

    private var noDriveTile: some View {
        HStack(spacing: 12) {
            CategoryBadge(systemName: "externaldrive.fill", tint: Color.white.opacity(0.5), size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("No external drive")
                    .font(.system(size: 15, weight: .semibold))
                Text("Connect an SSD formatted as APFS.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(GlassPanelBackground(cornerRadius: 14))
    }

    // MARK: - Progress

    private func operationCard(_ operation: OffloadOperation) -> some View {
        CardSurface(padding: 16, elevation: .flat, tint: accent) {
            HStack(spacing: 14) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 6) {
                    Text(operationTitle(operation))
                        .font(.system(size: 14, weight: .semibold))
                    Text(stageText(operation.stage))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let progress = operation.progress {
                        GlowProgressBar(progress: progress, tint: accent)
                            .frame(height: 6)
                    }
                }
                Spacer()
                if operation.stage == .copying || operation.stage == .verifying {
                    StopActionButton { store.cancel() }
                }
            }
        }
    }

    private func operationTitle(_ operation: OffloadOperation) -> String {
        switch operation.kind {
        case .move: return String(format: String(localized: "Moving %@"), operation.title)
        case .restore: return String(format: String(localized: "Bringing back %@"), operation.title)
        case .merge: return String(format: String(localized: "Repairing %@"), operation.title)
        }
    }

    private func stageText(_ stage: OffloadOperation.Stage) -> LocalizedStringKey {
        switch stage {
        case .checking: return "Checking the folder and free space…"
        case .copying: return "Copying. Keep the drive connected."
        case .verifying: return "Comparing the copy with the original…"
        case .swapping: return "Putting the link in place…"
        case .finishing: return "Cleaning up…"
        }
    }

    // MARK: - Warnings

    @ViewBuilder
    private var warnings: some View {
        if let volume = store.selectedVolume, !volume.supportsOffload {
            formatWarning(volume)
        }
        if let volume = store.selectedVolume, volume.isSolidState == false {
            infoCard(
                symbol: "tortoise.fill", tint: Tint.yellow,
                title: "This is a hard disk",
                text: "Moved folders open slower than on an SSD. Prefer models, archives and media over projects you build every day."
            )
        }
        if store.skippedProtectedFolders {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Documents and Downloads weren't checked")
                        .font(.system(size: 13, weight: .semibold))
                    Text("macOS asks for permission every time an app reads them. Turn on Full Disk Access for MacDash to include them, or add a folder yourself with Add Folder.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Open Settings") { FullDiskAccessManager.shared.openFullDiskAccessSettings() }
                    .buttonStyle(GlassButtonStyle())
            }
            .padding(14)
            .background(GlassPanelBackground(cornerRadius: 14))
        }
        ForEach(store.ghostMounts, id: \.self) { path in
            infoCard(
                symbol: "exclamationmark.triangle.fill", tint: Tint.orange,
                title: "An app wrote while the drive was away",
                text: LocalizedStringKey(String(format: String(localized: "A plain folder now sits at %@. When the drive returns, macOS gives it another name, and MacDash points the links there automatically."), path))
            )
        }
    }

    private func formatWarning(_ volume: OffloadVolume) -> some View {
        CardSurface(padding: 16, elevation: .flat, tint: Tint.orange) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    CategoryBadge(systemName: "exclamationmark.triangle.fill", tint: Tint.orange, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: String(localized: "%@ is formatted as %@"), volume.name, volume.fileSystemLabel))
                            .font(.system(size: 14, weight: .semibold))
                        Text("ExFAT and FAT are Windows formats. They have no journal, so unplugging without ejecting can corrupt files. They also don't keep macOS permissions, are slow with many small files and don't work with Time Machine. MacDash only moves folders to APFS.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(showsFormatGuide ? "Hide steps" : "How to convert") {
                        withAnimation(reduceMotion ? nil : MotionTokens.snappy) { showsFormatGuide.toggle() }
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                if showsFormatGuide {
                    VStack(alignment: .leading, spacing: 8) {
                        guideStep(1, "Get temporary space as large as what's on the drive: another external disk (which can then become your Time Machine backup) or a cloud plan for a month.")
                        guideStep(2, "Copy everything to it and open a few files to check the copy.")
                        guideStep(3, "In Disk Utility, choose View › Show All Devices, select the drive itself (not the volume), click Erase, and choose APFS with the GUID Partition Map scheme.")
                        guideStep(4, "Copy your files back. The drive is now ready for Drive Offload.")
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                        } label: {
                            Label("Open Disk Utility", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(GlassButtonStyle())
                        .padding(.top, 2)
                    }
                    .padding(.leading, 46)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func guideStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Tint.orange.opacity(0.22)))
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func infoCard(symbol: String, tint: Color, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(GlassPanelBackground(cornerRadius: 14))
    }

    // MARK: - Moved

    @ViewBuilder
    private var movedSection: some View {
        if !store.records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("On the drive", count: store.records.count,
                             note: "Turn one off to bring it back to your Mac.")
                CardSurface(padding: 0, elevation: .flat) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.records.enumerated()), id: \.element.id) { index, record in
                            recordRow(record)
                            if index < store.records.count - 1 { Divider().opacity(0.3).padding(.leading, 62) }
                        }
                    }
                }
            }
        }
    }

    private func recordRow(_ record: OffloadRecord) -> some View {
        let status = store.statuses[record.id] ?? .interrupted
        return HStack(spacing: 12) {
            CategoryBadge(systemName: symbol(for: record), tint: status == .healthy ? accent : Tint.orange, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    statusChip(status)
                }
                Text(displayPath(record.sourcePath))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let hint = statusHint(status) {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Tint.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(DriveOffloadStore.format(record.size))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
            repairButton(record, status: status)
            if status == .healthy {
                Button {
                    store.revealCopy(record)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("Show on the drive")
            }
            Toggle("", isOn: Binding(
                get: { true },
                set: { on in
                    if !on {
                        keepCopyOnDrive = false
                        pendingRestore = record
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(accent)
            .disabled(status != .healthy || store.operation != nil)
            .help(status == .healthy ? "Bring back to the Mac" : "Connect the drive and fix the status first")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func symbol(for record: OffloadRecord) -> String {
        DriveOffloadCatalog.entries.first { $0.id == record.catalogID }?.symbol ?? "folder.fill"
    }

    private func statusChip(_ status: OffloadLinkStatus) -> some View {
        switch status {
        case .healthy: return StatusChip(label: String(localized: "On the drive"), systemImage: "checkmark", tint: Tint.green)
        case .driveOffline: return StatusChip(label: String(localized: "Drive disconnected"), systemImage: "bolt.horizontal.circle", tint: Tint.orange)
        case .needsRelink: return StatusChip(label: String(localized: "Updating link"), systemImage: "link", tint: Tint.yellow)
        case .conflict: return StatusChip(label: String(localized: "Needs repair"), systemImage: "exclamationmark.triangle", tint: Tint.orange)
        case .linkMissing: return StatusChip(label: String(localized: "Link missing"), systemImage: "link.badge.plus", tint: Tint.orange)
        case .copyMissing: return StatusChip(label: String(localized: "Copy not found"), systemImage: "questionmark.folder", tint: Tint.red)
        case .interrupted: return StatusChip(label: String(localized: "Interrupted"), systemImage: "pause.circle", tint: Tint.yellow)
        }
    }

    private func statusHint(_ status: OffloadLinkStatus) -> LocalizedStringKey? {
        switch status {
        case .healthy, .needsRelink: return nil
        case .driveOffline: return "Apps that use this folder can't reach it until the drive is back."
        case .conflict: return "An app made a new folder here while the drive was away. Repair moves its files to the drive without overwriting anything."
        case .linkMissing: return "The link on the Mac was deleted. The files are safe on the drive."
        case .copyMissing: return "The drive is connected, but this folder isn't on it anymore."
        case .interrupted: return "Connect the drive to finish or undo the last step."
        }
    }

    @ViewBuilder
    private func repairButton(_ record: OffloadRecord, status: OffloadLinkStatus) -> some View {
        switch status {
        case .conflict where store.mountPath(for: record) != nil:
            Button("Repair") { store.resolveConflict(record) }
                .buttonStyle(GlassProminentButtonStyle())
                .tint(accent)
                .disabled(store.operation != nil)
        case .linkMissing:
            Button("Restore Link") { store.recreateLink(record) }
                .buttonStyle(GlassProminentButtonStyle())
                .tint(accent)
        case .copyMissing:
            Button("Forget") { store.forget(record) }
                .buttonStyle(GlassButtonStyle())
        default:
            EmptyView()
        }
    }

    private func restoreSheet(_ record: OffloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CategoryBadge(systemName: "arrow.uturn.backward.circle.fill", tint: accent, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: String(localized: "Bring %@ back to the Mac?"), record.title))
                        .font(.system(size: 16, weight: .semibold))
                    Text(String(format: String(localized: "%@ will be copied back and checked. Then the link is replaced by the real folder. Your Mac has %@ free."),
                                DriveOffloadStore.format(record.size), DriveOffloadStore.format(store.internalFree)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("Keep a copy on the drive as a backup", isOn: $keepCopyOnDrive)
                .toggleStyle(AnimatedCheckboxStyle(tint: accent))
            HStack {
                Spacer()
                Button("Cancel") { pendingRestore = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Bring Back") {
                    let keep = keepCopyOnDrive
                    pendingRestore = nil
                    store.restore(record, keepCopy: keep)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(GlassProminentButtonStyle())
                .tint(accent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    // MARK: - Recommendations

    private var movable: [OffloadCandidate] {
        store.candidates
            .filter { [.recommended, .worthIt].contains($0.verdict) }
            .sorted { ($0.verdict, -$0.size) < ($1.verdict, -$1.size) }
    }

    @ViewBuilder
    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Can move", count: movable.count,
                         note: "Large folders that can live on the drive. The biggest gains come first.")
            if store.isScanning && movable.isEmpty {
                CardSurface(padding: 18, elevation: .flat) {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Measuring folders…").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else if movable.isEmpty {
                CardSurface(padding: 18, elevation: .flat) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
                        Text("Nothing large left to move. Add any folder with the button above or by dropping it here.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                CardSurface(padding: 0, elevation: .flat) {
                    VStack(spacing: 0) {
                        ForEach(Array(movable.enumerated()), id: \.element.id) { index, candidate in
                            candidateRow(candidate)
                            if index < movable.count - 1 { Divider().opacity(0.3).padding(.leading, 62) }
                        }
                    }
                }
            }
        }
    }

    private func candidateRow(_ candidate: OffloadCandidate) -> some View {
        HStack(spacing: 12) {
            CategoryBadge(systemName: candidate.symbol, tint: accent, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(candidate.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    if candidate.verdict == .recommended {
                        StatusChip(label: String(localized: "Recommended"), systemImage: "star.fill", tint: accent)
                    }
                    if candidate.entry?.regenerates == true {
                        StatusChip(label: String(localized: "Downloads again if lost"), tint: Tint.green)
                    }
                    if candidate.inDailyUse {
                        StatusChip(label: String(localized: "Used today"), systemImage: "clock", tint: Tint.yellow)
                    }
                }
                Text(candidate.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(displayPath(candidate.url.path))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            sizeLabel(candidate)
            if candidate.isCustom {
                Button {
                    store.removeCustom(candidate)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("Remove from the list")
            }
            Button("Move") { pendingMove = candidate }
                .buttonStyle(GlassProminentButtonStyle())
                .tint(accent)
                .disabled(!canMove || candidate.measure == nil)
                .help(moveHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func sizeLabel(_ candidate: OffloadCandidate) -> some View {
        if candidate.measure == nil {
            ProgressView().controlSize(.mini)
        } else {
            Text(DriveOffloadStore.format(candidate.size))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var canMove: Bool {
        store.operation == nil && store.selectedVolume?.supportsOffload == true
    }

    private var moveHelp: LocalizedStringKey {
        guard let volume = store.selectedVolume else { return "Connect an external drive first" }
        return volume.supportsOffload ? "Move to the drive" : "The drive needs to be APFS"
    }

    // MARK: - Clean / native / blocked

    private var cleanable: [OffloadCandidate] { store.candidates.filter { $0.verdict == .clean } }
    private var native: [OffloadCandidate] { store.candidates.filter { $0.verdict == .native } }
    private var blocked: [OffloadCandidate] { store.candidates.filter { $0.verdict == .blocked } }

    @ViewBuilder
    private var cleanSection: some View {
        if !cleanable.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Better cleaned", count: cleanable.count,
                             note: "These rebuild on their own. Cleaning frees the space for good, with nothing to move.")
                CardSurface(padding: 0, elevation: .flat) {
                    VStack(spacing: 0) {
                        ForEach(Array(cleanable.enumerated()), id: \.element.id) { index, candidate in
                            simpleRow(candidate, tint: Tint.green) {
                                Button("Open Advanced Cleanup") { onNavigate(.cleanup) }
                                    .buttonStyle(GlassButtonStyle())
                            }
                            if index < cleanable.count - 1 { Divider().opacity(0.3).padding(.leading, 62) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var nativeSection: some View {
        if !native.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Use the app's own setting", count: native.count,
                             note: "These apps can't follow a link, but they can move their data themselves.")
                CardSurface(padding: 0, elevation: .flat) {
                    VStack(spacing: 0) {
                        ForEach(Array(native.enumerated()), id: \.element.id) { index, candidate in
                            VStack(alignment: .leading, spacing: 0) {
                                simpleRow(candidate, tint: Tint.blue) {
                                    Button(expandedNative.contains(candidate.id) ? "Hide" : "How") {
                                        withAnimation(reduceMotion ? nil : MotionTokens.snappy) {
                                            if expandedNative.contains(candidate.id) {
                                                expandedNative.remove(candidate.id)
                                            } else {
                                                expandedNative.insert(candidate.id)
                                            }
                                        }
                                    }
                                    .buttonStyle(GlassButtonStyle())
                                }
                                if expandedNative.contains(candidate.id), case .nativeSetting(let how) = candidate.advice {
                                    Text(how)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.leading, 64)
                                        .padding(.trailing, 16)
                                        .padding(.bottom, 12)
                                        .transition(.opacity)
                                }
                            }
                            if index < native.count - 1 { Divider().opacity(0.3).padding(.leading, 62) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var blockedSection: some View {
        if !blocked.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(reduceMotion ? nil : MotionTokens.snappy) { showsBlocked.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showsBlocked ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text(String(format: String(localized: "Not recommended (%lld)"), Int64(blocked.count)))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if showsBlocked {
                    CardSurface(padding: 0, elevation: .flat) {
                        VStack(spacing: 0) {
                            ForEach(Array(blocked.enumerated()), id: \.element.id) { index, candidate in
                                simpleRow(candidate, tint: Color.white.opacity(0.45), detail: candidate.block?.message ?? OffloadBlockReason.otherDisk.message) {
                                    EmptyView()
                                }
                                if index < blocked.count - 1 { Divider().opacity(0.3).padding(.leading, 62) }
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private func simpleRow<Accessory: View>(
        _ candidate: OffloadCandidate, tint: Color, detail: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            CategoryBadge(systemName: candidate.symbol, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(detail ?? candidate.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if candidate.size > 0 { sizeLabel(candidate) }
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Footnote

    private var footnote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Keep the drive connected and always eject it before unplugging. Time Machine only backs up moved folders if the drive itself is included in the backup. Moved folders sit in “MacDash Offload” on the drive, with a note explaining each one.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: LocalizedStringKey, count: Int, note: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(count.formatted())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private func displayPath(_ path: String) -> String {
        let home = DemoMode.isActive ? "/Users/alex" : NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = String(localized: "Check")
        panel.message = String(localized: "Choose folders to move to the external drive.")
        if panel.runModal() == .OK { store.addCustom(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { store.addCustom(urls) }
        }
        return !providers.isEmpty
    }
}
