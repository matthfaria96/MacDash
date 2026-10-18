import AppKit
import SwiftUI

/// The toolbar button that opens the Assistant.
struct AssistantToolbarButton: View {
    @Binding var isOpen: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.82)) {
                isOpen.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .semibold))
                Text("Assistant")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
        }
        .help("Your MacDash activity at a glance")
        .accessibilityLabel("Assistant")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

/// A small glass card that grows out of the toolbar's top-right corner with
/// how long MacDash has been around and what it has done. Plain type and
/// thin rules, no decoration.
struct AssistantPanel: View {
    @ObservedObject private var stats = UsageStats.shared
    @EnvironmentObject private var appState: AppState
    let tint: Color
    var navigate: (AppSection) -> Void = { _ in }
    let close: () -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(stats.daysWithMacTidy == 1
                     ? String(localized: "1 day with MacDash")
                     : String(format: String(localized: "%lld days with MacDash"), Int64(stats.daysWithMacTidy)))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                Text(String(format: String(localized: "Since %@"), stats.firstUse.formatted(date: .long, time: .omitted)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.bottom, 14)

            AssistantSuggestionsCarousel(tint: tint, navigate: navigate, close: close)
                .padding(.bottom, 12)
                .modifier(Rise(appeared: appeared, delay: 0.03))

            VStack(spacing: 0) {
                row("Space cleaned", stats.bytesCleaned > 0 ? ByteCountFormatter.string(fromByteCount: stats.bytesCleaned, countStyle: .file) : "0 GB")
                divider
                row("Tasks run", stats.tasksRun.formatted())
                divider
                row("Files checked last time", stats.lastFilesChecked.formatted())
                divider
                row("Free on this Mac", appState.diskInfo.formattedFree)
            }
            .modifier(Rise(appeared: appeared, delay: 0.05))

            lastActivity
                .padding(.top, 14)
                .modifier(Rise(appeared: appeared, delay: 0.12))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 300)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.22))
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3).delay(0.06)) { appeared = true }
        }
        .onExitCommand(perform: close)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.75)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.vertical, 9)
    }

    private var lastActivity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Last activity")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            if let date = stats.lastActivity {
                Text(stats.lastActivityKind?.title ?? String(localized: "Activity"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(date, style: .relative)
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            } else {
                Text("No scan or cleanup yet")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Suggestions

/// One thing the Assistant suggests doing next.
private struct AssistantSuggestion: Identifiable {
    let id: String
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let actionTitle: LocalizedStringKey
    /// Remembered across launches once handled; otherwise only for this session.
    var remembers = true
    /// Closes the Assistant after running, for actions that open a sheet.
    var closesPanel = false
    let run: () -> Void
}

/// Suggestions one at a time: run one or skip it and the next slides in.
/// Handled suggestions stay away for a few days, then come back if they
/// still apply.
private struct AssistantSuggestionsCarousel: View {
    @EnvironmentObject private var appState: AppState
    let tint: Color
    let navigate: (AppSection) -> Void
    let close: () -> Void

    @State private var index = 0
    @State private var forward = true
    @State private var completingID: String?
    /// The panel is rebuilt every time it opens, so this-session choices live
    /// outside the view.
    private static var sessionMemory: Set<String> = []
    @State private var sessionHandled: Set<String> = AssistantSuggestionsCarousel.sessionMemory
    @State private var handled: [String: Date] = AssistantSuggestionsCarousel.loadHandled()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let handledKey = "assistant.handledSuggestions"
    private static let doneCooldown: TimeInterval = 7 * 24 * 3600
    private static let skipCooldown: TimeInterval = 3 * 24 * 3600

    var body: some View {
        let list = visible
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Suggestions")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if list.count > 1 {
                    pager(count: list.count)
                }
            }

            ZStack {
                if let suggestion = list[safe: currentIndex(in: list)] {
                    card(suggestion, count: list.count)
                        .id(suggestion.id)
                        .transition(slide)
                } else {
                    allSet
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: Pieces

    private func card(_ suggestion: AssistantSuggestion, count: Int) -> some View {
        let completing = completingID == suggestion.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [suggestion.tint, suggestion.tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: completing ? "checkmark" : suggestion.icon)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
                .frame(width: 28, height: 28)
                .shadow(color: suggestion.tint.opacity(0.45), radius: 5, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(suggestion.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Skip") { finish(suggestion, done: false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .disabled(completingID != nil)
                Spacer()
                Button {
                    suggestion.run()
                    if suggestion.closesPanel {
                        finish(suggestion, done: true, animated: false)
                        close()
                    } else {
                        finish(suggestion, done: true)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: completing ? "checkmark" : "play.fill")
                            .font(.system(size: 8.5, weight: .bold))
                        Text(completing ? "Done" : suggestion.actionTitle)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(completing ? Tint.green : Color.white.opacity(0.92)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(completingID != nil)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [suggestion.tint.opacity(0.2), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.7)
        }
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: completing)
    }

    /// Dots for each suggestion with arrows to browse them.
    private func pager(count: Int) -> some View {
        let current = min(index, count - 1)
        return HStack(spacing: 5) {
            arrow("chevron.left", enabled: current > 0) { step(-1, count: count) }
            HStack(spacing: 3) {
                ForEach(0..<min(count, 6), id: \.self) { dot in
                    Capsule()
                        .fill(Color.white.opacity(dot == min(current, 5) ? 0.85 : 0.22))
                        .frame(width: dot == min(current, 5) ? 12 : 4, height: 4)
                }
            }
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: current)
            arrow("chevron.right", enabled: current < count - 1) { step(1, count: count) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(format: String(localized: "Suggestion %lld of %lld"), Int64(current + 1), Int64(count))))
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.7 : 0.2))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || completingID != nil)
    }

    private var allSet: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 16))
                .foregroundStyle(Tint.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("You're all set")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("New suggestions appear as your Mac changes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private var slide: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // MARK: State

    private func currentIndex(in list: [AssistantSuggestion]) -> Int {
        min(index, max(list.count - 1, 0))
    }

    private func step(_ delta: Int, count: Int) {
        forward = delta > 0
        withAnimation(reduceMotion ? nil : MotionTokens.gentle) {
            index = min(max(index + delta, 0), count - 1)
        }
    }

    /// Marks a suggestion handled; the list shrinks, so the same index now
    /// shows the next one. Running briefly shows a check first.
    private func finish(_ suggestion: AssistantSuggestion, done: Bool, animated: Bool = true) {
        let apply = {
            forward = true
            withAnimation(reduceMotion || !animated ? nil : MotionTokens.gentle) {
                completingID = nil
                if suggestion.remembers {
                    let cooldown = done ? Self.doneCooldown : Self.skipCooldown
                    // Stored as "visible again" time so each outcome keeps its own wait.
                    handled[suggestion.id] = Date().addingTimeInterval(cooldown)
                    UserDefaults.standard.set(handled, forKey: Self.handledKey)
                } else {
                    sessionHandled.insert(suggestion.id)
                    Self.sessionMemory = sessionHandled
                }
            }
        }
        guard done, animated else { apply(); return }
        withAnimation(reduceMotion ? nil : MotionTokens.snappy) { completingID = suggestion.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: apply)
    }

    private static func loadHandled() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: handledKey) as? [String: Date] ?? [:]
        return raw.filter { $0.value > Date() }
    }

    private var visible: [AssistantSuggestion] {
        let now = Date()
        return all.filter { suggestion in
            !sessionHandled.contains(suggestion.id) && (handled[suggestion.id].map { $0 <= now } ?? true)
        }
    }

    // MARK: Catalog

    /// Most urgent first. Each entry only appears while it applies.
    private var all: [AssistantSuggestion] {
        var list: [AssistantSuggestion] = []
        let careState = appState.scanState(in: .smartCare)

        if !appState.hasFullDiskAccess {
            list.append(AssistantSuggestion(
                id: "fullDiskAccess",
                icon: "lock.shield.fill",
                tint: Tint.orange,
                title: String(localized: "Turn on Full Disk Access"),
                detail: String(localized: "Lets scans reach protected caches and app data."),
                actionTitle: "Set up",
                remembers: false,
                closesPanel: true
            ) {
                PermissionCoordinator.shared.requestAccess(context: .general) {
                    appState.checkFullDiskAccess()
                }
            })
        }

        let threats = AntivirusStore.shared.pending.count
        if threats > 0 {
            list.append(AssistantSuggestion(
                id: "reviewThreats",
                icon: "shield.lefthalf.filled",
                tint: SectionPalette.antivirus.accent,
                title: String(localized: "Review possible threats"),
                detail: String(format: String(localized: "%lld items are waiting for your decision. Nothing was moved."), Int64(threats)),
                actionTitle: "Review",
                remembers: false
            ) { navigate(.antivirus) })
        }

        if careState == .completed, appState.smartCareSelectedSize > 0 {
            list.append(AssistantSuggestion(
                id: "cleanSmartCare",
                icon: "sparkles",
                tint: SectionPalette.smartCare.accent,
                title: String(format: String(localized: "Clean %@ of junk"), ByteCountFormatter.string(fromByteCount: appState.smartCareSelectedSize, countStyle: .file)),
                detail: String(localized: "Smart Care results are ready to review."),
                actionTitle: "Open",
                remembers: false
            ) { navigate(.smartCare) })
        }

        if careState == .idle, !appState.scanState.isActive {
            list.append(AssistantSuggestion(
                id: "smartScan",
                icon: "desktopcomputer",
                tint: SectionPalette.smartCare.accent,
                title: String(localized: "Run Smart Care"),
                detail: String(localized: "Junk and known threats in one quick pass."),
                actionTitle: "Scan",
                remembers: false
            ) {
                navigate(.smartCare)
                appState.startSmartScan()
            })
        }

        let disk = appState.diskInfo
        if disk.totalSpace > 0, Double(disk.freeSpace) / Double(disk.totalSpace) < 0.15 {
            list.append(AssistantSuggestion(
                id: "spaceLens",
                icon: "chart.pie.fill",
                tint: SectionPalette.forSection(.spaceLens).accent,
                title: String(localized: "Find what fills your disk"),
                detail: String(format: String(localized: "Only %@ free. Space Lens maps the biggest folders."), disk.formattedFree),
                actionTitle: "Open"
            ) { navigate(.spaceLens) })
        }

        list.append(AssistantSuggestion(
            id: "appUpdates",
            icon: "arrow.down.circle.fill",
            tint: SectionPalette.apps.accent,
            title: String(localized: "Check for app updates"),
            detail: String(localized: "See which of your apps have a newer version."),
            actionTitle: "Check"
        ) {
            appState.applicationsTab = .updates
            navigate(.apps)
        })

        list.append(AssistantSuggestion(
            id: "startupItems",
            icon: "power",
            tint: SectionPalette.apps.accent,
            title: String(localized: "Review startup items"),
            detail: String(localized: "Fewer items starting with your Mac means a faster login."),
            actionTitle: "Review"
        ) {
            appState.applicationsTab = .startup
            navigate(.apps)
        })

        list.append(AssistantSuggestion(
            id: "unusedApps",
            icon: "app.dashed",
            tint: CleanupBundle.unusedAppsColor,
            title: String(localized: "Find apps you no longer use"),
            detail: String(localized: "Advanced Cleanup lists apps left unopened for months."),
            actionTitle: "Open"
        ) { navigate(.cleanup) })

        list.append(AssistantSuggestion(
            id: "duplicates",
            icon: "doc.on.doc.fill",
            tint: SectionPalette.forSection(.duplicates).accent,
            title: String(localized: "Look for duplicate files"),
            detail: String(localized: "Identical copies often hide in Downloads and Documents."),
            actionTitle: "Open"
        ) { navigate(.duplicates) })

        return list
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Content settles in just after the card opens.
private struct Rise: ViewModifier {
    let appeared: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.28).delay(delay), value: appeared)
    }
}
