import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drive Offload: moves large folders to an external drive and leaves a link
/// behind, so apps keep finding them. Every move can be turned off again.
///
/// Kept deliberately quiet: one line per folder (name, one sentence, size, one
/// action). Paths, the drive's details and secondary actions live in tooltips,
/// context menus and the collapsed "Other options".
struct DriveOffloadView: View {
    var onNavigate: (AppSection) -> Void = { _ in }

    @ObservedObject private var store = DriveOffloadStore.shared
    @ObservedObject private var permission = PermissionCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingMove: OffloadCandidate?
    @State private var pendingRestore: OffloadRecord?
    @State private var keepCopyOnDrive = false
    @State private var showsOtherOptions = false
    @State private var showsFormatGuide = false
    @State private var isDropTargeted = false

    static let symbol = "externaldrive.connected.to.line.below.fill"
    private var accent: Color { SectionPalette.driveOffload.accent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let message = store.message {
                    NoticeBanner(text: message.text, isError: message.isError) { store.message = nil }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if store.skippedProtectedFolders { accessCard }
                drivesCard
                if let operation = store.operation, !operation.title.isEmpty {
                    operationCard(operation)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                notices
                movedSection
                suggestionsSection
                otherOptionsSection
                Text("Keep the drive connected and eject it before unplugging.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
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
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: store.skippedProtectedFolders)
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
        .sheet(item: $pendingRestore) { restoreSheet($0) }
        .sheet(isPresented: $showsFormatGuide) { formatGuide }
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
            detail: { Text("Move large folders to an external drive. Everything can be undone.") },
            accessory: {
                HStack(spacing: 8) {
                    Button {
                        store.scan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(GlassIconButtonStyle())
                    .disabled(store.isScanning || store.operation != nil)
                    .help("Check Again")
                    Button {
                        pickFolders()
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            }
        )
    }

    // MARK: - Full Disk Access

    /// One request for everything, instead of macOS asking folder by folder.
    private var accessCard: some View {
        CardSurface(padding: 16, elevation: .flat, tint: accent) {
            HStack(spacing: 14) {
                CategoryBadge(systemName: "lock.shield.fill", tint: accent, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Allow full access once")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Then MacDash checks every folder without macOS asking item by item.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Allow Access") {
                    permission.requestAccess(context: .general) { store.scan() }
                }
                .buttonStyle(GlassProminentButtonStyle())
                .tint(accent)
            }
        }
    }

    // MARK: - Drives

    private var drivesCard: some View {
        CardSurface(padding: 18, elevation: .flat, tint: accent) {
            HStack(alignment: .center, spacing: 18) {
                driveColumn(
                    symbol: "internaldrive.fill",
                    name: String(localized: "This Mac"),
                    free: store.internalFree,
                    total: store.internalTotal,
                    tint: Tint.blue
                ) {
                    Label("Startup disk", systemImage: "internaldrive")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.8))
                    .accessibilityHidden(true)
                if let volume = store.selectedVolume {
                    driveColumn(
                        symbol: "externaldrive.fill",
                        name: volume.name,
                        free: volume.availableCapacity,
                        total: volume.totalCapacity,
                        tint: volume.supportsOffload ? accent : Tint.orange
                    ) {
                        driveStatus(volume)
                    }
                    .help(driveDetails(volume))
                } else {
                    driveColumn(
                        symbol: "externaldrive.fill",
                        name: String(localized: "No external drive"),
                        free: 0, total: 0,
                        tint: Color.white.opacity(0.5)
                    ) {
                        Text("Connect an SSD formatted as APFS.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func driveColumn<Extra: View>(
        symbol: String, name: String, free: Int64, total: Int64, tint: Color,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CategoryBadge(systemName: symbol, tint: tint, size: 38)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if symbol == "externaldrive.fill", store.volumes.count > 1 { volumeMenu }
                }
                if total > 0 {
                    GlowProgressBar(progress: Double(total - free) / Double(total), tint: tint)
                        .frame(height: 5)
                    Text(String(format: String(localized: "%@ free of %@"), DriveOffloadStore.format(free), DriveOffloadStore.format(total)))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                extra()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func driveStatus(_ volume: OffloadVolume) -> some View {
        if volume.supportsOffload {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Tint.green)
        } else {
            HStack(spacing: 6) {
                Label(String(format: String(localized: "%@ · needs APFS"), volume.fileSystemLabel), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Tint.orange)
                Button("How to convert") { showsFormatGuide = true }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5, weight: .medium))
            }
        }
    }

    private func driveDetails(_ volume: OffloadVolume) -> String {
        var parts = [volume.fileSystemLabel]
        if let ssd = volume.isSolidState { parts.append(ssd ? "SSD" : String(localized: "Hard disk")) }
        if let bus = volume.busProtocol, !bus.isEmpty { parts.append(bus) }
        return parts.joined(separator: " · ")
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

    // MARK: - Progress

    private func operationCard(_ operation: OffloadOperation) -> some View {
        CardSurface(padding: 16, elevation: .flat, tint: accent) {
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 6) {
                    Text(operationTitle(operation))
                        .font(.system(size: 14, weight: .semibold))
                    Text(stageText(operation.stage))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let progress = operation.progress {
                        GlowProgressBar(progress: progress, tint: accent).frame(height: 5)
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

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if let volume = store.selectedVolume, volume.isSolidState == false {
            notice("tortoise.fill", Tint.yellow,
                   "This is a hard disk",
                   "Moved folders open slower than on an SSD. Prefer models, archives and media over projects you build every day.")
        }
        ForEach(store.ghostMounts, id: \.self) { path in
            notice("exclamationmark.triangle.fill", Tint.orange,
                   "An app wrote while the drive was away",
                   LocalizedStringKey(String(format: String(localized: "A plain folder now sits at %@. When the drive returns, macOS gives it another name, and MacDash points the links there automatically."), path)))
        }
    }

    private func notice(_ symbol: String, _ tint: Color, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(GlassPanelBackground(cornerRadius: 12))
    }

    // MARK: - On the drive

    @ViewBuilder
    private var movedSection: some View {
        if !store.records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(
                    "On the drive",
                    note: String(format: String(localized: "%@ moved off your Mac in %lld folders."),
                                 DriveOffloadStore.format(store.offloadedBytes), Int64(store.records.count))
                )
                list(store.records) { recordRow($0) }
            }
        }
    }

    private func recordRow(_ record: OffloadRecord) -> some View {
        let status = store.statuses[record.id] ?? .interrupted
        return HStack(spacing: 12) {
            CategoryBadge(systemName: symbol(for: record), tint: status == .healthy ? accent : Tint.orange, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                if let problem = statusProblem(status) {
                    Text(problem)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tint.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            repairButton(record, status: status)
            sizeText(record.size)
            Toggle("", isOn: Binding(
                get: { true },
                set: { on in
                    guard !on else { return }
                    keepCopyOnDrive = false
                    pendingRestore = record
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(accent)
            .disabled(status != .healthy || store.operation != nil)
            .help(status == .healthy ? "Bring back to the Mac" : "Connect the drive and fix the status first")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .help(displayPath(record.sourcePath))
        .contextMenu {
            Button("Show on the drive") { store.revealCopy(record) }
                .disabled(status != .healthy)
        }
    }

    private func symbol(for record: OffloadRecord) -> String {
        DriveOffloadCatalog.entries.first { $0.id == record.catalogID }?.symbol ?? "folder.fill"
    }

    /// Nothing is shown while all is well; otherwise one short line says what's wrong.
    private func statusProblem(_ status: OffloadLinkStatus) -> LocalizedStringKey? {
        switch status {
        case .healthy, .needsRelink: return nil
        case .driveOffline: return "Drive disconnected. Apps can't reach this folder until it's back."
        case .conflict: return "An app made a new folder here while the drive was away."
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
                .help("Moves its files to the drive without overwriting anything.")
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

    // MARK: - Suggestions

    private var movable: [OffloadCandidate] {
        store.candidates
            .filter { [.recommended, .worthIt].contains($0.verdict) }
            .sorted { ($0.verdict, -$0.size) < ($1.verdict, -$1.size) }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Suggestions", note: String(localized: "Large folders that can live on the drive. The biggest gains come first."))
            if store.isScanning && movable.isEmpty {
                placeholderRow {
                    ProgressView().controlSize(.small)
                    Text("Measuring folders…").foregroundStyle(.secondary)
                }
            } else if movable.isEmpty {
                placeholderRow {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
                    Text("Nothing large left to move. Add any folder with the button above or by dropping it here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                list(movable) { candidateRow($0) }
            }
        }
    }

    private func candidateRow(_ candidate: OffloadCandidate) -> some View {
        HStack(spacing: 12) {
            CategoryBadge(systemName: candidate.symbol, tint: accent, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(candidate.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    if candidate.verdict == .recommended {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(accent)
                            .help("Recommended")
                            .accessibilityLabel("Recommended")
                    }
                }
                Text(candidate.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if candidate.measure == nil {
                ProgressView().controlSize(.mini)
            } else {
                sizeText(candidate.size)
            }
            Button("Move") { pendingMove = candidate }
                .buttonStyle(GlassProminentButtonStyle())
                .tint(accent)
                .disabled(!canMove || candidate.measure == nil)
                .help(moveHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .help(displayPath(candidate.url.path))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) }
            if candidate.isCustom {
                Button("Remove from the list") { store.removeCustom(candidate) }
            }
        }
    }

    private var canMove: Bool {
        store.operation == nil && store.selectedVolume?.supportsOffload == true
    }

    private var moveHelp: LocalizedStringKey {
        guard let volume = store.selectedVolume else { return "Connect an external drive first" }
        return volume.supportsOffload ? "Move to the drive" : "The drive needs to be APFS"
    }

    // MARK: - Other options

    private var cleanable: [OffloadCandidate] { store.candidates.filter { $0.verdict == .clean } }
    private var native: [OffloadCandidate] { store.candidates.filter { $0.verdict == .native } }
    private var blocked: [OffloadCandidate] { store.candidates.filter { $0.verdict == .blocked } }

    /// Everything that isn't a plain move, folded away until asked for.
    @ViewBuilder
    private var otherOptionsSection: some View {
        let count = cleanable.count + native.count + blocked.count
        if count > 0 {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : MotionTokens.snappy) { showsOtherOptions.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showsOtherOptions ? 90 : 0))
                        Text("Other options")
                            .font(.system(size: 13, weight: .semibold))
                        Text(count.formatted())
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showsOtherOptions {
                    VStack(alignment: .leading, spacing: 14) {
                        if !cleanable.isEmpty {
                            group("Better cleaned", note: "They rebuild on their own, so cleaning frees the space for good.") {
                                list(cleanable) { candidate in
                                    plainRow(candidate, detail: candidate.detail, tint: Tint.green) {
                                        Button("Clean") { onNavigate(.cleanup) }
                                            .buttonStyle(GlassButtonStyle())
                                            .help("Open Advanced Cleanup")
                                    }
                                }
                            }
                        }
                        if !native.isEmpty {
                            group("Use the app's own setting", note: "These apps can't follow a link, but they can move their data themselves.") {
                                list(native) { candidate in
                                    plainRow(candidate, detail: nativeHow(candidate), tint: Tint.blue, detailLines: 3) { EmptyView() }
                                }
                            }
                        }
                        if !blocked.isEmpty {
                            group("Not recommended", note: nil) {
                                list(blocked) { candidate in
                                    plainRow(candidate, detail: candidate.block?.message ?? OffloadBlockReason.otherDisk.message,
                                             tint: Color.white.opacity(0.45)) { EmptyView() }
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func nativeHow(_ candidate: OffloadCandidate) -> String {
        if case .nativeSetting(let how) = candidate.advice { return how }
        return candidate.detail
    }

    private func group<Content: View>(_ title: LocalizedStringKey, note: LocalizedStringKey?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let note {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            content()
        }
    }

    private func plainRow<Accessory: View>(
        _ candidate: OffloadCandidate, detail: String, tint: Color, detailLines: Int = 1,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            CategoryBadge(systemName: candidate.symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(detailLines)
                    .fixedSize(horizontal: false, vertical: detailLines > 1)
            }
            Spacer(minLength: 8)
            if candidate.size > 0 { sizeText(candidate.size) }
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .help(displayPath(candidate.url.path))
    }

    // MARK: - Format guide

    private var formatGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CategoryBadge(systemName: "externaldrive.fill", tint: Tint.orange, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Convert the drive to APFS")
                        .font(.system(size: 16, weight: .semibold))
                    Text("ExFAT and FAT are Windows formats. They have no journal, so unplugging without ejecting can corrupt files. They also don't keep macOS permissions, are slow with many small files and don't work with Time Machine. MacDash only moves folders to APFS.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                guideStep(1, "Get temporary space as large as what's on the drive: another external disk (which can then become your Time Machine backup) or a cloud plan for a month.")
                guideStep(2, "Copy everything to it and open a few files to check the copy.")
                guideStep(3, "In Disk Utility, choose View › Show All Devices, select the drive itself (not the volume), click Erase, and choose APFS with the GUID Partition Map scheme.")
                guideStep(4, "Copy your files back. The drive is now ready for Drive Offload.")
            }
            HStack {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                } label: {
                    Label("Open Disk Utility", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(GlassButtonStyle())
                Spacer()
                Button("Done") { showsFormatGuide = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(GlassProminentButtonStyle())
                    .tint(accent)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func guideStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20)
                .background(Circle().fill(accent.opacity(0.22)))
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Building blocks

    private func list<Item: Identifiable, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        CardSurface(padding: 0, elevation: .flat) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                    if index < items.count - 1 { Divider().opacity(0.25).padding(.leading, 60) }
                }
            }
        }
    }

    private func placeholderRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        CardSurface(padding: 16, elevation: .flat) {
            HStack(spacing: 10) {
                content()
                Spacer()
            }
            .font(.system(size: 12.5))
        }
    }

    private func sizeText(_ bytes: Int64) -> some View {
        Text(DriveOffloadStore.format(bytes))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(minWidth: 62, alignment: .trailing)
    }

    private func sectionTitle(_ title: LocalizedStringKey, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
        }
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
