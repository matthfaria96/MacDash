import AppKit
import SwiftUI

/// Reads the disks and the backup for the Health card: when the card opens,
/// when a disk is plugged in or out, and every few minutes while Processes is
/// open and in front. Nothing runs anywhere else.
@MainActor
final class HealthModel: ObservableObject {
    @Published private(set) var facts: DeviceHealthFacts?
    @Published private(set) var isReading = false

    static let interval: UInt64 = 180_000_000_000

    func refresh() async {
        guard !isReading else { return }
        isReading = true
        facts = await Task.detached(priority: .utility) { DeviceHealthReader.read() }.value
        isReading = false
    }

    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: Self.interval)
        }
    }
}

/// "Should I worry?" in one card: a verdict for the whole Mac, then one chip
/// per disk, the backup, memory and temperature. A chip unfolds what was
/// measured and what to do.
struct HealthOverview: View {
    @ObservedObject var performance: PerformanceModel
    let isActive: Bool
    @StateObject private var model = HealthModel()
    @State private var selected: String?

    private var report: HealthReport? {
        model.facts.map {
            DeviceHealthRules.report($0, memory: performance.snapshot, thermal: performance.thermalState, temperature: performance.temperature)
        }
    }

    var body: some View {
        CardSurface(padding: 18, tint: report.map { $0.level.tint }) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let report {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 8)], spacing: 8) {
                        ForEach(report.items) { item in
                            HealthChip(item: item, isSelected: selected == item.id) {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                                    selected = selected == item.id ? nil : item.id
                                }
                            }
                        }
                    }
                    if let item = report.items.first(where: { $0.id == selected }) {
                        HealthDetail(item: item)
                            .id(item.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 8)], spacing: 8) {
                        ForEach(0..<4, id: \.self) { _ in SkeletonBlock(height: 58, corner: 12) }
                    }
                }
            }
        }
        .animation(MotionTokens.gentle, value: report?.items.map(\.id))
        #if DEBUG
        // `-DebugHealth backup` (or `drive:disk0`, `memory`, `temperature`) opens that item's details.
        .onAppear { selected = selected ?? UserDefaults.standard.string(forKey: "DebugHealth") }
        #endif
        .task(id: isActive) {
            if isActive {
                await model.watch()
            } else if model.facts == nil {
                await model.refresh()
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await model.refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            let level = report?.level ?? .good
            PremiumIcon(systemName: level.symbol, tint: report == nil ? Color.white.opacity(0.4) : level.tint, size: 34, style: .glass)
            VStack(alignment: .leading, spacing: 2) {
                Text("Health")
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.5))
                Text(verbatim: report?.headline ?? String(localized: "Checking your disks…"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if let detail = report?.detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.refresh() }
            } label: {
                Group {
                    if model.isReading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(model.isReading)
            .help("Check again")
            .accessibilityLabel("Check again")
        }
    }
}

extension HealthLevel {
    var tint: Color {
        switch self {
        case .good: return Tint.green
        case .watch: return Tint.yellow
        case .act: return Tint.red
        }
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.shield.fill"
        case .watch: return "exclamationmark.triangle.fill"
        case .act: return "xmark.octagon.fill"
        }
    }
}

/// One item: icon, name, a colored status and one quiet line. A drive that
/// reports its wear also gets a thin bar of the life it has left.
private struct HealthChip: View {
    let item: HealthItem
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.level.tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(item.level.tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle().fill(item.level.tint).frame(width: 6, height: 6)
                        Text(verbatim: item.status)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(item.level.tint)
                            .lineLimit(1)
                    }
                    Text(verbatim: item.caption)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                    if let life = item.lifeLeft {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 2.5)
                            .overlay(alignment: .leading) {
                                GeometryReader { geometry in
                                    // The bar shows wear alone: a full but young disk keeps a green bar.
                                    Capsule()
                                        .fill((life <= 0 ? HealthLevel.act : life <= 0.2 ? .watch : .good).tint.opacity(0.85))
                                        .frame(width: max(2, geometry.size.width * min(1, max(0, life))))
                                }
                            }
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering || isSelected ? 0.7 : 0.3))
                    .rotationEffect(.degrees(isSelected ? 180 : 0))
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                ZStack {
                    shape.fill(Color.white.opacity(hovering ? 0.065 : 0.035))
                    if isSelected {
                        shape.strokeBorder(item.level.tint.opacity(0.7), lineWidth: 1)
                    } else {
                        shape.strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(MotionTokens.snappy, value: hovering)
        .help(isSelected ? "Close the details" : "Show the details")
        .accessibilityElement(children: .combine)
    }
}

/// What was measured and what to do, under the chips.
private struct HealthDetail: View {
    let item: HealthItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.level.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.level.tint)
                    .frame(width: 16)
                Text(verbatim: item.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if !item.facts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                    ForEach(item.facts) { fact in
                        HStack(spacing: 8) {
                            Capsule().fill(fact.level == .good ? Color.white.opacity(0.3) : fact.level.tint).frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: fact.value)
                                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text(verbatim: fact.label)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
                    }
                }
            }
            if !item.advice.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What to do")
                        .font(.system(size: 10.5, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.45))
                    ForEach(item.advice, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(item.level == .good ? Color.white.opacity(0.4) : item.level.tint)
                                .padding(.top, 3)
                            Text(verbatim: line)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let action = item.action {
                HStack {
                    Spacer()
                    switch action {
                    case .openTimeMachine:
                        Button("Open Time Machine Settings") { SystemInspectionModel.openTimeMachineSettings() }
                            .buttonStyle(GlassButtonStyle())
                    case .grantFullDiskAccess:
                        Button("Allow Full Disk Access") { FullDiskAccessManager.shared.openFullDiskAccessSettings() }
                            .buttonStyle(GlassButtonStyle())
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(item.level.tint.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(item.level.tint.opacity(0.18), lineWidth: 0.6))
    }
}
