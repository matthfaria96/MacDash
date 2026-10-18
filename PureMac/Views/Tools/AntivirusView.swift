import AppKit
import SwiftUI

/// Antivirus: scan, review, quarantine and trust — one screen. Nothing found
/// is touched until the user decides, item by item.
struct AntivirusView: View {
    @ObservedObject private var store = AntivirusStore.shared
    @AppStorage("antivirus.mode") private var mode: AntivirusScanMode = .quick
    @State private var customURLs: [URL] = []
    @State private var listTab: ListTab = .quarantine
    @State private var pendingDelete: QuarantineRecord?
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tint = SectionPalette.antivirus.accent

    enum ListTab: String, CaseIterable, Identifiable {
        case quarantine, trusted, history
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .quarantine: return "Quarantine"
            case .trusted: return "Trusted"
            case .history: return "History"
            }
        }
        var icon: String {
            switch self {
            case .quarantine: return "archivebox"
            case .trusted: return "checkmark.seal"
            case .history: return "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusStrip
                scanPanel
                reviewSection
                listsSection
            }
            .padding(24)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: store.phase)
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: store.pending)
        .confirmationDialog(
            "Delete permanently?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { record in
            Button("Delete permanently", role: .destructive) { store.deleteForever(record) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("\(record.detection.name) will be erased from the quarantine and can't be restored.")
        }
        .alert("Antivirus", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        FeaturePageHeader(
            title: Text("Antivirus"),
            systemImage: "shield.lefthalf.filled",
            tint: tint,
            detail: {
                Text("Scans for malware, adware and suspicious launch items. Nothing is moved until you approve it.")
            },
            accessory: {
                if store.isScanning {
                    StopActionButton { store.stop() }
                } else if case .finished = store.phase {
                    StartOverButton { store.reset() }
                }
            }
        )
    }

    private var statusStrip: some View {
        CardSurface(padding: 14, elevation: .flat) {
            HStack(spacing: 0) {
                metric(
                    value: store.lastScan.map { $0.startedAt.formatted(.relative(presentation: .named)) } ?? String(localized: "Never"),
                    label: "Last scan", icon: "clock", tint: tint
                )
                Divider().frame(height: 38)
                metric(value: store.pending.count.formatted(), label: "To review", icon: "exclamationmark.shield", tint: store.pending.isEmpty ? Tint.green : Tint.orange)
                Divider().frame(height: 38)
                metric(value: store.quarantine.count.formatted(), label: "In quarantine", icon: "archivebox", tint: Tint.blue)
                Divider().frame(height: 38)
                metric(value: AntivirusRules.version, label: "Rules", icon: "list.bullet.rectangle", tint: Tint.teal)
                Spacer(minLength: 0)
            }
        }
    }

    private func metric(value: String, label: LocalizedStringKey, icon: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            CategoryBadge(systemName: icon, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Scan panel

    @ViewBuilder
    private var scanPanel: some View {
        switch store.phase {
        case .idle:
            idlePanel
        case .scanning(let running):
            scanningPanel(running)
        case .finished(let record):
            finishedPanel(record)
        }
    }

    private var idlePanel: some View {
        CardSurface(padding: 18, elevation: .flat, tint: dropTargeted ? tint : nil) {
            VStack(alignment: .leading, spacing: 16) {
                // Four across when they fit, otherwise two by two.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) { modeTiles(minWidth: 200) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        modeTiles(minWidth: 0)
                    }
                }
                if mode == .custom { customPicker }

                HStack(spacing: 10) {
                    Button {
                        store.start(mode, custom: customURLs)
                    } label: {
                        Label("Analyze", systemImage: "magnifyingglass")
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(GlassProminentButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == .custom && customURLs.isEmpty)

                    Button {
                        store.testProtection()
                    } label: {
                        Label("Test protection", systemImage: "testtube.2")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.large)
                    .help("Creates the harmless EICAR test file in MacDash's folder and scans it")

                    Spacer(minLength: 8)

                    Picker(selection: $store.schedule) {
                        Text("Off").tag(AntivirusStore.Schedule.off)
                        Text("Daily").tag(AntivirusStore.Schedule.daily)
                        Text("Weekly").tag(AntivirusStore.Schedule.weekly)
                    } label: {
                        Label("Automatic Quick scan", systemImage: "calendar.badge.clock")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Runs while MacDash is open. Findings wait for your review.")
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            mode = .custom
            customURLs = urls
            store.start(.custom, custom: urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func modeTiles(minWidth: CGFloat) -> some View {
        ForEach(AntivirusScanMode.allCases) { option in
            ModeTile(mode: option, isSelected: mode == option, tint: tint) { mode = option }
                .frame(minWidth: minWidth)
        }
    }

    private var customPicker: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                if customURLs.isEmpty {
                    Text("Choose files or folders, or drag them here.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customURLs, id: \.self) { url in
                        Text(url.path)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer()
            Button("Choose…") { chooseCustom() }
                .buttonStyle(GlassButtonStyle())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func chooseCustom() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK { customURLs = panel.urls }
    }

    private func scanningPanel(_ running: AntivirusScanMode) -> some View {
        CardSurface(padding: 24, elevation: .flat, tint: tint) {
            HStack(spacing: 22) {
                ZStack {
                    Circle()
                        .stroke(tint.opacity(0.14), lineWidth: 8)
                        .frame(width: 86, height: 86)
                    ProgressView()
                        .controlSize(.large)
                        .tint(tint)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(phaseTitle(store.progress.phase, mode: running))
                        .font(.system(size: 18, weight: .semibold))
                    Text("\(store.progress.filesChecked.formatted()) items checked · \(store.progress.detections.formatted()) to review")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(store.progress.currentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func phaseTitle(_ phase: AntivirusProgress.Phase, mode: AntivirusScanMode) -> String {
        switch phase {
        case .preparing: return String(localized: "Preparing scan")
        case .launchItems: return String(localized: "Checking launch agents and daemons")
        case .files: return String(format: String(localized: "%@ scan in progress"), mode.title)
        case .processes: return String(localized: "Checking running programs")
        }
    }

    private func finishedPanel(_ record: AntivirusScanRecord) -> some View {
        let clean = record.detections == 0
        let iconTint = record.wasCancelled ? Tint.orange : clean ? Tint.green : Tint.orange
        return CardSurface(padding: 18, elevation: .flat, tint: iconTint) {
            HStack(spacing: 16) {
                PremiumIcon(systemName: record.wasCancelled ? "pause.circle.fill" : clean ? "checkmark.shield.fill" : "exclamationmark.shield.fill", tint: iconTint, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.wasCancelled ? "Scan stopped" : clean ? "No threats found" : "Found items that need your decision")
                        .font(.system(size: 17, weight: .semibold))
                    Text("\(record.mode.title) · \(record.filesChecked.formatted()) items checked in \(Duration.seconds(record.duration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: Review

    @ViewBuilder
    private var reviewSection: some View {
        if !store.pending.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("To review", count: store.pending.count, note: "Nothing has been moved. Choose what happens to each item.")
                ForEach(store.pending) { detection in
                    DetectionCard(detection: detection, isBusy: store.busy.contains(detection.id), store: store)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

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

    // MARK: Quarantine · Trusted · History

    private var listsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PillTabBar(
                tabs: ListTab.allCases,
                selection: $listTab,
                title: { $0.title },
                icon: { $0.icon },
                badge: { tab in
                    let count: Int
                    switch tab {
                    case .quarantine: count = store.quarantine.count
                    case .trusted: count = store.trusted.count
                    case .history: count = 0
                    }
                    return count > 0 ? String(count) : nil
                }
            )
            .padding(.top, 8)

            switch listTab {
            case .quarantine: quarantineList
            case .trusted: trustedList
            case .history: historyList
            }
        }
    }

    @ViewBuilder
    private var quarantineList: some View {
        if store.quarantine.isEmpty {
            emptyRow(icon: "archivebox", text: "Quarantine is empty. Items you approve are kept here, locked, until you restore or delete them.")
        } else {
            CardSurface(padding: 0, elevation: .flat) {
                VStack(spacing: 0) {
                    ForEach(Array(store.quarantine.enumerated()), id: \.element.id) { index, record in
                        quarantineRow(record)
                        if index < store.quarantine.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
            }
        }
    }

    private func quarantineRow(_ record: QuarantineRecord) -> some View {
        let busy = store.busy.contains(record.id)
        return HStack(spacing: 12) {
            CategoryBadge(systemName: record.detection.category.icon, tint: record.detection.severityTint, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.detection.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(record.items.map(\.originalPath).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                Text(record.quarantinedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 10)
            if busy { ProgressView().controlSize(.small) }
            Menu {
                Button("Restore") { store.restore(record, andTrust: false) }
                Button("Restore and trust") { store.restore(record, andTrust: true) }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
            Button(role: .destructive) {
                pendingDelete = record
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var trustedList: some View {
        if store.trusted.isEmpty {
            emptyRow(icon: "checkmark.seal", text: "Nothing trusted yet. Trusted files, folders and developers are skipped by every scan.")
        } else {
            CardSurface(padding: 0, elevation: .flat) {
                VStack(spacing: 0) {
                    ForEach(Array(store.trusted.enumerated()), id: \.element.id) { index, rule in
                        HStack(spacing: 12) {
                            StatusChip(label: rule.kind.label, systemImage: rule.kind.icon, tint: tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.label)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if rule.kind != .path {
                                    Text(rule.value)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Button("Remove") { store.removeTrust(rule) }
                                .buttonStyle(GlassButtonStyle())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if index < store.trusted.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if store.history.isEmpty {
            emptyRow(icon: "clock.arrow.circlepath", text: "No scans yet.")
        } else {
            CardSurface(padding: 0, elevation: .flat) {
                VStack(spacing: 0) {
                    ForEach(Array(store.history.prefix(20).enumerated()), id: \.element.id) { index, record in
                        HStack(spacing: 12) {
                            Image(systemName: record.mode.icon)
                                .foregroundStyle(tint)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(record.mode.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                    if record.wasScheduled {
                                        StatusChip(label: String(localized: "Automatic"), systemImage: "calendar", tint: Tint.blue)
                                    }
                                    if record.wasCancelled {
                                        StatusChip(label: String(localized: "Stopped"), systemImage: "pause", tint: Tint.orange)
                                    }
                                }
                                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(record.filesChecked.formatted()) items")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            StatusChip(
                                label: record.detections == 0 ? String(localized: "Clean") : String(format: String(localized: "%lld found"), Int64(record.detections)),
                                tint: record.detections == 0 ? Tint.green : Tint.orange
                            )
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if index < min(store.history.count, 20) - 1 { Divider().padding(.leading, 48) }
                    }
                }
            }
        }
    }

    private func emptyRow(icon: String, text: LocalizedStringKey) -> some View {
        ProtectionFootnote(icon: icon, text: text)
            .padding(.vertical, 6)
    }
}

// MARK: - Mode tile

private struct ModeTile: View {
    let mode: AntivirusScanMode
    let isSelected: Bool
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: mode.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? tint : .white.opacity(0.75))
                    Spacer()
                    Text(mode.durationHint)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(mode.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(mode.scopeDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.14) : Color.white.opacity(hovering ? 0.07 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.75) : Color.white.opacity(0.08), lineWidth: isSelected ? 1.2 : 0.6)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Detection card

private struct DetectionCard: View {
    let detection: Detection
    let isBusy: Bool
    let store: AntivirusStore
    @State private var expanded = false

    var body: some View {
        CardSurface(padding: 0, elevation: .flat, tint: detection.severityTint) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    CategoryBadge(systemName: detection.category.icon, tint: detection.severityTint, size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(detection.name)
                                .font(.system(size: 14, weight: .semibold))
                            StatusChip(label: detection.severityLabel, systemImage: detection.severity == .high ? "exclamationmark.triangle.fill" : "questionmark", tint: detection.severityTint)
                        }
                        Text(detection.reason)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(MotionTokens.gentle) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide details" : "Show details")
                }
                .padding(14)

                VStack(spacing: 0) {
                    ForEach(detection.components) { component in
                        componentRow(component)
                    }
                }
                .padding(.horizontal, 14)

                if expanded { details.padding(.horizontal, 14).padding(.top, 8) }

                Divider().padding(.top, 10)
                actions.padding(14)
            }
        }
    }

    private func componentRow(_ component: ThreatComponent) -> some View {
        HStack(spacing: 10) {
            FileIcon(path: component.path, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(component.archiveEntry.map { "\(URL(fileURLWithPath: component.path).lastPathComponent) › \($0)" } ?? URL(fileURLWithPath: component.path).lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(component.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(component.role.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: component.path)])
            } label: {
                Image(systemName: "arrow.forward.square")
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 5)
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Detected by").foregroundStyle(.secondary)
                Text("\(detection.source.label) · \(detection.rule)")
            }
            if let signing = detection.signing {
                GridRow {
                    Text("Signature").foregroundStyle(.secondary)
                    Text(signing.label)
                }
            }
            ForEach(detection.components.filter { $0.sha256 != nil }) { component in
                GridRow {
                    Text("SHA-256").foregroundStyle(.secondary)
                    Text(component.sha256 ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            GridRow {
                Text("Found").foregroundStyle(.secondary)
                Text("\(detection.detectedAt.formatted(date: .abbreviated, time: .shortened)) · \(detection.mode.title)")
            }
        }
        .font(.system(size: 11.5))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Text(proposal)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            if isBusy { ProgressView().controlSize(.small) }
            Menu {
                Button("Trust this file (by fingerprint)") { store.trust(detection, by: .hash) }
                    .disabled(!detection.components.contains { $0.sha256 != nil })
                Button("Trust this location") { store.trust(detection, by: .path) }
                if let team = detection.signing?.teamID {
                    Button("Trust developer \(team)") { store.trust(detection, by: .teamID) }
                }
            } label: {
                Text("Trust")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isBusy)
            Button("Ignore") { store.dismiss(detection) }
                .buttonStyle(GlassButtonStyle())
                .disabled(isBusy)
                .help("Leave it as it is this time")
            Button {
                store.quarantine(detection)
            } label: {
                Label("Move to Quarantine", systemImage: "archivebox.fill")
            }
            .buttonStyle(GlassProminentButtonStyle())
            .disabled(isBusy)
        }
    }

    /// Exactly what "Move to Quarantine" will do.
    private var proposal: String {
        let launchItems = detection.launchItems.count
        let files = detection.components.count
        if launchItems > 0 {
            return String(format: String(localized: "Will unload %lld launch item(s), stop running copies and move %lld item(s) to quarantine."), Int64(launchItems), Int64(files))
        }
        return String(format: String(localized: "Will stop running copies and move %lld item(s) to quarantine. You can restore them later."), Int64(files))
    }
}

// MARK: - Labels

extension AntivirusScanMode {
    var title: String {
        switch self {
        case .quick: return String(localized: "Quick")
        case .balanced: return String(localized: "Balanced")
        case .deep: return String(localized: "Deep")
        case .custom: return String(localized: "Custom")
        }
    }

    var icon: String {
        switch self {
        case .quick: return "hare.fill"
        case .balanced: return "scalemass.fill"
        case .deep: return "magnifyingglass.circle.fill"
        case .custom: return "folder.fill"
        }
    }

    var durationHint: String {
        switch self {
        case .quick: return String(localized: "~1 min")
        case .balanced: return String(localized: "~4 min")
        case .deep: return String(localized: "~7 min+")
        case .custom: return String(localized: "Varies")
        }
    }

    var scopeDescription: String {
        switch self {
        case .quick: return String(localized: "Downloads, Application Support, launch agents and what they start, opened disk images.")
        case .balanced: return String(localized: "Quick, plus every app, system extensions, shared folders and running programs.")
        case .deep: return String(localized: "Balanced, plus your whole Library, Documents, Desktop, the Trash and ZIP archives.")
        case .custom: return String(localized: "Only the files and folders you choose, archives included.")
        }
    }
}

extension ThreatCategory {
    var icon: String {
        switch self {
        case .testFile: return "testtube.2"
        case .knownMalware: return "ladybug.fill"
        case .adware: return "megaphone.fill"
        case .persistence: return "arrow.triangle.2.circlepath"
        case .unsignedProgram: return "signature"
        case .script: return "terminal.fill"
        }
    }
}

extension Detection {
    var severityTint: Color {
        if category == .testFile { return SectionPalette.antivirus.accent }
        return severity == .high ? Tint.red : Tint.orange
    }

    var severityLabel: String {
        if category == .testFile { return String(localized: "Test") }
        return severity == .high ? String(localized: "Threat") : String(localized: "Suspicious")
    }
}

extension DetectionSource {
    var label: String {
        switch self {
        case .testSignature: return String(localized: "Test signature")
        case .fileHash: return String(localized: "File fingerprint")
        case .familyName: return String(localized: "Adware family name")
        case .launchItem: return String(localized: "Launch item check")
        case .codeSignature: return String(localized: "Code signature")
        case .scriptContent: return String(localized: "Script content")
        }
    }
}

extension SigningStatus {
    var label: String {
        switch self {
        case .apple: return String(localized: "Apple")
        case .developerID(let team): return String(format: String(localized: "Developer ID (%@)"), team)
        case .adHoc: return String(localized: "Ad-hoc (no developer identity)")
        case .unsigned: return String(localized: "Not signed")
        case .invalid: return String(localized: "Signature invalid")
        }
    }
}

extension ThreatComponent.Role {
    var label: String {
        switch self {
        case .file: return String(localized: "File")
        case .appBundle: return String(localized: "App")
        case .launchItem: return String(localized: "Launch item")
        case .program: return String(localized: "Program")
        case .archive: return String(localized: "Archive")
        }
    }
}

extension TrustRule.Kind {
    var label: String {
        switch self {
        case .hash: return String(localized: "Fingerprint")
        case .path: return String(localized: "Location")
        case .teamID: return String(localized: "Developer")
        }
    }

    var icon: String {
        switch self {
        case .hash: return "number"
        case .path: return "folder"
        case .teamID: return "person.crop.square"
        }
    }
}
