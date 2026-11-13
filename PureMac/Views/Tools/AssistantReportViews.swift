import AppKit
import SwiftUI

// MARK: - One finding

/// A finding with what it covers. In the current analysis it carries its
/// actions; in a report from the history it is a record and has none.
struct AssistantFindingCard: View {
    struct Actions {
        var isChecking = false
        var isBusy = false
        var review: () -> Void = {}
        var openTool: () -> Void = {}
        var ignore: () -> Void = {}
        var restore: () -> Void = {}
    }

    let finding: AssistantFinding
    let accent: Color
    var actions: Actions?

    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let listed = 10
    private var tint: Color { AssistantFormat.tint(finding.severity, accent: accent) }

    var body: some View {
        // One line until opened: the title says what, the button says what to do.
        VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Button(action: toggle) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: finding.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(finding.status.isOpen ? tint : Color.white.opacity(0.4))
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill((finding.status.isOpen ? tint : Color.white).opacity(0.13)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(finding.title)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                statusLine
                            }
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Shows what it covers"))

                    primaryAction
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(isOpen ? "Hide details" : "Show details"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if isOpen {
                    Divider().opacity(0.25)
                    details
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .transition(.opacity)
                }
        }
        .background(GlassPanelBackground(cornerRadius: 14))
        .overlay(alignment: .leading) {
            if finding.status.isOpen {
                Capsule().fill(tint).frame(width: 3).padding(.vertical, 12).padding(.leading, 1)
            }
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : MotionTokens.snappy) { isOpen.toggle() }
    }

    @ViewBuilder
    private var statusLine: some View {
        let chip = statusChip
        if chip != nil || finding.outcome != nil {
            HStack(spacing: 8) {
                if let chip { chip }
                if let outcome = finding.outcome {
                    Text(outcome)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.top, 3)
        }
    }

    private var statusChip: StatusChip? {
        switch finding.status {
        case .done: return StatusChip(label: String(localized: "Done"), systemImage: "checkmark", tint: Tint.green)
        case .partial: return StatusChip(label: String(localized: "Partly done"), systemImage: "circle.lefthalf.filled", tint: Tint.yellow)
        case .ignored: return StatusChip(label: String(localized: "Ignored"), systemImage: "eye.slash", tint: Color.white.opacity(0.6))
        case .opened: return StatusChip(label: String(localized: "Handed over"), systemImage: "arrow.up.forward", tint: Tint.blue)
        case .pending:
            // In a past report an open suggestion is only a note: its files must be checked anew.
            guard actions == nil, finding.action != .advice else { return nil }
            return StatusChip(label: String(localized: "Needs a new check"), systemImage: "clock", tint: Tint.orange)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        // The size stands on its own only when the title doesn't already say it.
        if finding.total > 0, !finding.title.contains(AssistantRules.format(finding.total)) {
            Text(AssistantRules.format(finding.total))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(finding.status.isOpen ? .primary : .secondary)
                .frame(minWidth: 66, alignment: .trailing)
        }
        if let actions, finding.status.isOpen {
            switch finding.action {
            case .trash:
                Button(action: actions.review) {
                    HStack(spacing: 6) {
                        if actions.isChecking { ProgressView().controlSize(.mini) }
                        Text(actions.isChecking ? "Checking…" : "Review…")
                    }
                }
                .buttonStyle(GlassProminentButtonStyle())
                .disabled(actions.isBusy || finding.targets.isEmpty)
                .help("Checks the files again and shows what would move to the Trash")
            case .openTool:
                if let tool = finding.tool {
                    Button(String(format: String(localized: "Open %@"), tool.title), action: actions.openTool)
                        .buttonStyle(GlassButtonStyle())
                        .disabled(actions.isBusy)
                }
            case .advice:
                EmptyView()
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(finding.explanation)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Label {
                Text(finding.recommendation)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lightbulb.fill").font(.system(size: 11)).foregroundStyle(tint)
            }

            if !finding.targets.isEmpty {
                VStack(spacing: 0) {
                    ForEach(finding.targets.prefix(Self.listed)) { target in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.label)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !target.note.isEmpty {
                                    Text(target.note)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(AssistantRules.format(target.size))
                                .font(.system(size: 12, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        .help(AssistantFormat.path(target.path))
                        .contextMenu {
                            if !DemoMode.isActive {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)]) }
                            }
                        }
                    }
                }
                let hidden = finding.targets.count - min(finding.targets.count, Self.listed) + finding.omittedCount
                if hidden > 0 {
                    Text(String(format: String(localized: "and %lld more"), Int64(hidden)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }

            if let actions {
                HStack {
                    Spacer()
                    if finding.status.isOpen {
                        Button("Ignore", action: actions.ignore)
                            .buttonStyle(GlassButtonStyle())
                            .disabled(actions.isBusy)
                            .help("Leaves it as it is and notes that in the report")
                    } else if finding.status == .ignored || finding.status == .opened {
                        Button("Bring Back", action: actions.restore)
                            .buttonStyle(GlassButtonStyle())
                            .disabled(actions.isBusy)
                    }
                }
            }
        }
    }
}

// MARK: - Confirming

/// The fresh check of a finding's items, shown before anything moves.
struct AssistantPlanSheet: View {
    @ObservedObject var store: AssistantStore
    let accent: Color

    var body: some View {
        if let plan = store.plan {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    CategoryBadge(systemName: "trash.fill", tint: accent, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Move these items to the Trash?")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Everything was checked again just now. Only selected items move, each one is checked once more as it goes, and you can put them back from the Trash.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if plan.ready.isEmpty {
                    Text("Nothing here can move right now.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        Text(String(format: String(localized: "%lld of %lld selected"), Int64(plan.selected.count), Int64(plan.ready.count)))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Select All") { setAll(true) }.buttonStyle(.link).font(.system(size: 12))
                        Button("Select None") { setAll(false) }.buttonStyle(.link).font(.system(size: 12))
                    }
                }

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(plan.ready) { item in readyRow(item) }
                        if !plan.unavailable.isEmpty {
                            Text("Left out")
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.6)
                                .textCase(.uppercase)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, plan.ready.isEmpty ? 0 : 12)
                                .padding(.bottom, 4)
                            ForEach(plan.unavailable) { item in unavailableRow(item) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)
                .background(GlassPanelBackground(cornerRadius: 12))

                HStack(spacing: 10) {
                    Text(AssistantRules.format(plan.selectedBytes))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if store.isMoving || store.checkingID != nil { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { store.plan = nil }
                        .keyboardShortcut(.cancelAction)
                        .disabled(store.isMoving)
                    Button("Move to Trash") { store.confirm() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(GlassProminentButtonStyle())
                        .disabled(plan.selected.isEmpty || store.isMoving || store.checkingID != nil)
                }
            }
            .padding(22)
            .frame(width: 580)
        }
    }

    private func setAll(_ selected: Bool) {
        guard var plan = store.plan else { return }
        for index in plan.items.indices where plan.items[index].state == .ready { plan.items[index].selected = selected }
        store.plan = plan
    }

    private func binding(_ item: AssistantPlanItem) -> Binding<Bool> {
        Binding(
            get: { store.plan?.items.first { $0.id == item.id }?.selected ?? false },
            set: { value in
                guard var plan = store.plan, let index = plan.items.firstIndex(where: { $0.id == item.id }) else { return }
                plan.items[index].selected = value
                store.plan = plan
            }
        )
    }

    private func readyRow(_ item: AssistantPlanItem) -> some View {
        Toggle(isOn: binding(item)) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.target.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.target.note.isEmpty ? AssistantFormat.path(item.target.path) : item.target.note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(AssistantRules.format(item.size))
                    .font(.system(size: 12, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(AnimatedCheckboxStyle(tint: accent))
        .padding(.vertical, 5)
        .disabled(store.isMoving)
        .help(AssistantFormat.path(item.target.path))
        .contextMenu {
            if !DemoMode.isActive {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.target.path)]) }
            }
        }
    }

    private func unavailableRow(_ item: AssistantPlanItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "minus.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.target.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.state.reason ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tint.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .help(AssistantFormat.path(item.target.path))
    }
}

// MARK: - History

/// Past reports: a list, and one report opened as a read-only record.
struct AssistantHistoryView: View {
    @ObservedObject var store: AssistantStore
    @Binding var openedReportID: UUID?
    let accent: Color
    let analyzeAgain: () -> Void
    var showDetails: (AssistantReport) -> Void = { _ in }

    @State private var pendingDelete: AssistantReport?
    @State private var confirmsDeleteAll = false

    var body: some View {
        Group {
            if let id = openedReportID, let report = store.history.first(where: { $0.id == id }) {
                detail(report)
            } else {
                list
            }
        }
        .confirmationDialog(
            "Delete this report?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { report in
            Button("Delete Report", role: .destructive) {
                if openedReportID == report.id { openedReportID = nil }
                store.delete([report.id])
            }
            Button("Cancel", role: .cancel) {}
        } message: { report in
            Text(String(format: String(localized: "The report from %@ is removed. Nothing else on the Mac changes."),
                        report.date.formatted(date: .abbreviated, time: .shortened)))
        }
        .confirmationDialog("Delete all reports?", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                openedReportID = nil
                store.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every report is removed, including the comparison base for what grew. Nothing else on the Mac changes.")
        }
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History").font(.system(size: 16, weight: .semibold))
                    Text(String(format: String(localized: "One report per analysis. MacDash keeps the latest %lld."), Int64(AssistantStore.reportLimit)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !store.history.isEmpty {
                    Menu {
                        Button("Older Than 30 Days") { store.deleteOlder(thanDays: 30) }
                        Button("All Reports…", role: .destructive) { confirmsDeleteAll = true }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if !store.isHistoryLoaded {
                placeholder { ProgressView().controlSize(.small); Text("Loading reports…").foregroundStyle(.secondary) }
            } else if store.history.isEmpty {
                placeholder {
                    Image(systemName: "tray").foregroundStyle(.secondary)
                    Text("No reports yet. Each analysis you run is kept here.").foregroundStyle(.secondary)
                }
            } else {
                CardSurface(padding: 0, elevation: .flat) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.history.enumerated()), id: \.element.id) { index, report in
                            row(report)
                            if index < store.history.count - 1 { Divider().opacity(0.25).padding(.leading, 60) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ report: AssistantReport) -> some View {
        HStack(spacing: 12) {
            Button {
                openedReportID = report.id
            } label: {
                HStack(spacing: 12) {
                    CategoryBadge(systemName: "doc.text.fill", tint: accent, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(report.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 13.5, weight: .semibold))
                            if report.id == store.live?.id {
                                StatusChip(label: String(localized: "Current"), tint: accent)
                            }
                        }
                        Text(report.headline)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(tally(report))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                pendingDelete = report
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GlassIconButtonStyle())
            .help("Delete this report")
            .accessibilityLabel(Text("Delete this report"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func tally(_ report: AssistantReport) -> String {
        String(format: String(localized: "%lld done · %lld ignored · %lld open"),
               Int64(report.count(.done, .opened)), Int64(report.count(.ignored)), Int64(report.count(.pending, .partial)))
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        CardSurface(padding: 16, elevation: .flat) {
            HStack(spacing: 10) {
                content()
                Spacer()
            }
            .font(.system(size: 12.5))
        }
    }

    // MARK: One report

    @ViewBuilder
    private func detail(_ report: AssistantReport) -> some View {
        CardSurface(padding: 16, elevation: .flat, tint: accent) {
            HStack(spacing: 14) {
                CategoryBadge(systemName: "clock.arrow.circlepath", tint: accent, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: String(localized: "Report from %@"), report.date.formatted(date: .long, time: .shortened)))
                        .font(.system(size: 14, weight: .semibold))
                    Text("A record of the Mac at that moment. Files have changed since, so nothing here can be run: a new analysis checks everything as it is now.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    pendingDelete = report
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("Delete this report")
                .accessibilityLabel(Text("Delete this report"))
                Button("Analyze Again", action: analyzeAgain)
                    .buttonStyle(GlassProminentButtonStyle())
            }
        }
        AssistantHealthHero(report: report) { showDetails(report) }
        if !report.findings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("What was found").font(.system(size: 16, weight: .semibold))
                ForEach(report.findings) { finding in
                    AssistantFindingCard(finding: finding, accent: accent, actions: nil)
                }
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("What was done").font(.system(size: 16, weight: .semibold))
            if report.actions.isEmpty {
                placeholder { Text("No action was taken from this report.").foregroundStyle(.secondary) }
            } else {
                CardSurface(padding: 16, elevation: .flat) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(report.actions) { action in actionRow(action) }
                    }
                }
            }
        }
        AssistantUsageBar(report: report)
    }

    private func actionRow(_ action: AssistantActionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(action.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(action.kind == .trash ? Tint.green : Color.white.opacity(0.6))
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(label(action))
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(action.findingTitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                ForEach(action.skipped.prefix(4), id: \.self) { skipped in
                    Text(verbatim: (skipped.path as NSString).lastPathComponent + ": " + skipped.reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tint.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(action.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func symbol(_ kind: AssistantActionRecord.Kind) -> String {
        switch kind {
        case .trash: return "trash.fill"
        case .openTool: return "arrow.up.forward"
        case .ignore: return "eye.slash"
        case .restore: return "arrow.uturn.backward"
        }
    }

    private func label(_ action: AssistantActionRecord) -> String {
        switch action.kind {
        case .trash:
            var text = String(format: String(localized: "Moved to the Trash: %lld (%@)."), Int64(action.moved), AssistantRules.format(action.bytes))
            if !action.skipped.isEmpty {
                text += " " + String(format: String(localized: "%lld could not be moved."), Int64(action.skipped.count))
            }
            return text
        case .openTool: return String(localized: "Continued in another tool")
        case .ignore: return String(localized: "Ignored")
        case .restore: return String(localized: "Brought back to the list")
        }
    }
}
