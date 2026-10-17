import AppKit
import SwiftUI

/// Processes: the Mac's vitals as four tiles that unfold into details,
/// anything heavy in the background, then the user's own apps. Sampling only runs while this screen
/// is open and MacDash is the frontmost app.
struct ProcessesView: View {
    @StateObject private var performance = PerformanceModel()
    @State private var appIsActive = NSApplication.shared.isActive
    @State private var isFreeingMemory = false
    @State private var memoryNotice: String?

    private let palette = SectionPalette.processes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FeaturePageHeader(
                    title: Text("Processes"),
                    systemImage: "waveform.path.ecg.rectangle.fill",
                    tint: palette.accent,
                    detail: { Text("How your Mac is doing right now, and what each app you have open is using.") },
                    accessory: { LiveStatusBadge(isCollecting: performance.isCollecting, isActive: appIsActive) }
                )

                if let memoryNotice {
                    NoticeBanner(text: memoryNotice) { self.memoryNotice = nil }
                }
                if let notice = performance.notice {
                    NoticeBanner(text: notice) { performance.notice = nil }
                }

                PerformanceOverview(model: performance)

                if !performance.background.isEmpty {
                    BackgroundActivityCard(model: performance)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                CardSurface(padding: 18, elevation: .standard) {
                    ProcessResourcesView(model: performance, isActive: appIsActive, accessory: AnyView(freeMemoryButton))
                }
            }
            .animation(MotionTokens.gentle, value: performance.background.isEmpty)
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
