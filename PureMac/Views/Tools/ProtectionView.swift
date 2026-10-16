import AppKit
import SwiftUI

/// Keeps the security check's progress and result while the user moves
/// between Protection tabs.
@MainActor
final class ProtectionAuditModel: ObservableObject {
    enum Phase {
        case idle
        case running
        case complete(ProtectionSnapshot)
    }

    @Published private(set) var phase: Phase = .idle

    private let audit: ProtectionAudit
    private var task: Task<Void, Never>?

    init(audit: ProtectionAudit = ProtectionAudit()) {
        self.audit = audit
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    /// Safeguards that are off, once a check has finished.
    var attentionCount: Int? {
        guard case .complete(let snapshot) = phase else { return nil }
        return snapshot.findings.filter { $0.status == .disabled }.count
    }

    /// The check only reads settings, so it runs by itself the first time the tab opens.
    func runIfNeeded() {
        if isIdle { run() }
    }

    func run() {
        guard !isRunning else { return }
        task?.cancel()
        phase = .running
        task = Task { [weak self, audit] in
            let snapshot = await audit.run()
            guard let self, !Task.isCancelled else { return }
            withAnimation(MotionTokens.gentle) { self.phase = .complete(snapshot) }
            self.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        withAnimation(MotionTokens.gentle) { phase = .idle }
    }

    func startOver() {
        withAnimation(MotionTokens.gentle) { phase = .idle }
    }
}

/// Protection › Security: reads the state of the macOS safeguards.
struct ProtectionView: View {
    @ObservedObject var model: ProtectionAuditModel

    private let tint = SectionPalette.protection.accent

    var body: some View {
        ProtectionTabPage {
            header
            content
        }
        .task { model.runIfNeeded() }
    }

    private var header: some View {
        ProtectionTabHeader(
            title: "Security Check",
            subtitle: "Gatekeeper, FileVault, the firewall, System Integrity Protection and XProtect.",
            icon: "checkmark.shield.fill"
        ) {
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .running:
            CardSurface(padding: 0, elevation: .standard, tint: tint) {
                VStack(spacing: 0) {
                    ForEach(Array(ProtectionCheck.allCases.enumerated()), id: \.element.id) { index, check in
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 24)
                            Text(check.title)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("Checking")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)

                        if index < ProtectionCheck.allCases.count - 1 {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }
        case .complete(let snapshot):
            summary(snapshot)

            CardSurface(padding: 0, elevation: .standard) {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.findings.enumerated()), id: \.element.id) { index, finding in
                        ProtectionFindingRow(finding: finding)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)

                        if index < snapshot.findings.count - 1 {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
            }

            ProtectionFootnote(
                icon: "clock",
                text: "Checked \(snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened)). Unknown means the setting could not be confirmed."
            )
        }
    }

    private func summary(_ snapshot: ProtectionSnapshot) -> some View {
        let enabled = snapshot.findings.filter { $0.status == .enabled }.count
        let off = snapshot.findings.filter { $0.status == .disabled }.count
        let allGood = off == 0
        return HStack(spacing: 14) {
            PremiumIcon(systemName: allGood ? "checkmark.seal.fill" : "exclamationmark.triangle.fill", tint: allGood ? Tint.green : Tint.orange, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(allGood ? "Your Mac's safeguards are on" : "Some safeguards are off")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(String(format: String(localized: "%lld of %lld safeguards on"), Int64(enabled), Int64(snapshot.findings.count)))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(GlassPanelBackground(cornerRadius: 16))
    }
}

private struct ProtectionFindingRow: View {
    let finding: ProtectionFinding

    private var symbol: String {
        switch finding.check {
        case .gatekeeper: return "checkmark.shield.fill"
        case .fileVault: return "lock.fill"
        case .firewall: return "network"
        case .systemIntegrityProtection: return "shield.lefthalf.filled"
        case .xProtect: return "ladybug.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Each safeguard has its own icon; green when on, orange when off.
            PremiumIcon(systemName: symbol, tint: finding.status == .unknown ? Color(red: 0.6, green: 0.62, blue: 0.72) : finding.status.tint, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(finding.check.title)
                        .font(.system(size: 13, weight: .semibold))
                    StatusChip(
                        label: finding.status.label(for: finding.check),
                        systemImage: finding.status.chipIcon,
                        tint: finding.status.tint
                    )
                    if let version = finding.version {
                        Text(version)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(finding.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(finding.check.actionTitle) {
                ProtectionNavigation.openAction(for: finding.check)
            }
            .buttonStyle(GlassButtonStyle())
            .controlSize(.small)
        }
    }
}

private enum ProtectionNavigation {
    static func openAction(for check: ProtectionCheck) {
        switch check {
        case .gatekeeper:
            openSettings("com.apple.preference.security")
        case .fileVault:
            openSettings("com.apple.preference.security?FileVault")
        case .firewall:
            openSettings("com.apple.Network-Settings.extension?Firewall")
        case .systemIntegrityProtection:
            openWeb("https://support.apple.com/guide/security/secb7ea06b49/web")
        case .xProtect:
            openSettings("com.apple.Software-Update-Settings.extension")
        }
    }

    static func openSettings(_ destination: String) {
        openWeb("x-apple.systempreferences:\(destination)")
    }

    private static func openWeb(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension ProtectionCheck {
    var title: String {
        switch self {
        case .gatekeeper:
            return String(localized: "Gatekeeper")
        case .fileVault:
            return String(localized: "FileVault")
        case .firewall:
            return String(localized: "Application Firewall")
        case .systemIntegrityProtection:
            return String(localized: "System Integrity Protection")
        case .xProtect:
            return String(localized: "XProtect")
        }
    }

    var actionTitle: String {
        switch self {
        case .gatekeeper:
            return String(localized: "Security Settings")
        case .fileVault:
            return String(localized: "FileVault Settings")
        case .firewall:
            return String(localized: "Firewall Settings")
        case .systemIntegrityProtection:
            return String(localized: "Apple Guide")
        case .xProtect:
            return String(localized: "Software Update")
        }
    }
}

private extension ProtectionStatus {
    var icon: String {
        switch self {
        case .enabled:
            return "checkmark.circle.fill"
        case .disabled:
            return "exclamationmark.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var chipIcon: String {
        switch self {
        case .enabled:
            return "checkmark"
        case .disabled:
            return "exclamationmark"
        case .unknown:
            return "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .enabled:
            return Tint.green
        case .disabled:
            return Tint.orange
        case .unknown:
            return .secondary
        }
    }

    func label(for check: ProtectionCheck) -> String {
        switch (self, check) {
        case (.enabled, .xProtect):
            return String(localized: "Installed")
        case (.enabled, _):
            return String(localized: "On")
        case (.disabled, _):
            return String(localized: "Off")
        case (.unknown, _):
            return String(localized: "Unknown")
        }
    }
}
