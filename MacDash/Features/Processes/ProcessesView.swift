import AppKit
import SwiftUI

/// Processes: who this Mac is and how its disk is filled, its vitals as four
/// tiles that unfold into details, the health of its disks and backup,
/// anything heavy in the background, then the user's own apps. Sampling only runs while this screen
/// is open and MacDash is the frontmost app.
///
/// Readings arrive every two seconds, so the page itself never observes the
/// model: each card observes only what it shows (the vitals, the process
/// list, the live badge), and everything else stays still.
struct ProcessesView: View {
    var onNavigate: (AppSection) -> Void = { _ in }
    @StateObject private var performance = PerformanceModel()

    var body: some View {
        ProcessesPage(performance: performance, onNavigate: onNavigate)
            .equatable()
    }
}

private struct ProcessesPage: View, Equatable {
    let performance: PerformanceModel
    let onNavigate: (AppSection) -> Void
    @State private var appIsActive = NSApplication.shared.isActive
    @State private var isFreeingMemory = false
    @State private var memoryNotice: String?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.performance === rhs.performance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MacProfileCard(onNavigate: onNavigate) {
                    LiveBadge(performance: performance, isActive: appIsActive)
                }

                if let memoryNotice {
                    NoticeBanner(text: memoryNotice) { self.memoryNotice = nil }
                }
                PerformanceNotice(performance: performance)

                PerformanceOverview(model: performance)

                HealthOverview(performance: performance, isActive: appIsActive)

                BackgroundActivitySlot(performance: performance)

                CardSurface(padding: 18, elevation: .standard) {
                    ProcessResourcesView(performance: performance, processes: performance.processes,
                                         isActive: appIsActive, accessory: AnyView(freeMemoryButton))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // Sampling restarts whenever MacDash comes back to the front, and
        // stops while it is in the background or this page is closed.
        .task(id: appIsActive) {
            if appIsActive {
                await performance.monitor()
            } else if performance.snapshot == nil {
                // Opened behind another app: one reading, so the page isn't empty.
                await performance.sample()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await performance.sample(readTemperature: false, readProcesses: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appIsActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appIsActive = false }
    }

    /// An icon next to Activity Monitor, above the list of apps.
    private var freeMemoryButton: some View {
        Button {
            freeMemory()
        } label: {
            Group {
                if isFreeingMemory {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "memorychip")
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(GlassButtonStyle())
        .disabled(isFreeingMemory)
        .help("Free up memory: clears inactive memory macOS is holding. Asks for an administrator password.")
        .accessibilityLabel("Free up memory")
    }

    /// Runs `purge`, which writes cached data back and empties inactive memory.
    private func freeMemory() {
        isFreeingMemory = true
        memoryNotice = nil
        let before = performance.snapshot?.free ?? 0
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Int32 in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return -1 }
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await performance.sample(readTemperature: false, readProcesses: true)
            isFreeingMemory = false
            guard result == 0 else { return }
            let after = performance.snapshot?.free ?? 0
            memoryNotice = after > before
                ? String(format: String(localized: "%@ of memory freed."), formatMemory(after - before))
                : String(localized: "Memory was already in good shape.")
        }
    }
}

/// The live badge on the profile card: the only part of that card that
/// follows the readings.
private struct LiveBadge: View {
    @ObservedObject var performance: PerformanceModel
    let isActive: Bool

    var body: some View {
        LiveStatusBadge(isCollecting: performance.isCollecting, isActive: isActive)
    }
}

private struct PerformanceNotice: View {
    @ObservedObject var performance: PerformanceModel

    var body: some View {
        if let notice = performance.notice {
            NoticeBanner(text: notice) { performance.notice = nil }
        }
    }
}

/// "Heavy in the background", shown only while something stands out.
private struct BackgroundActivitySlot: View {
    let performance: PerformanceModel
    @ObservedObject var processes: ProcessReadings

    init(performance: PerformanceModel) {
        self.performance = performance
        processes = performance.processes
    }

    var body: some View {
        // The model changes the list inside an animation, so the card
        // slides in and out.
        if !processes.background.isEmpty {
            BackgroundActivityCard(performance: performance, processes: processes)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
