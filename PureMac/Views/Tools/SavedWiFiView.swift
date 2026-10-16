import AppKit
import SwiftUI

@MainActor
final class SavedWiFiModel: ObservableObject {
    /// One model for the whole session, so passwords already approved stay
    /// on screen when you come back to this tab instead of asking again.
    static let shared = SavedWiFiModel()

    enum State {
        case idle
        case loading
        case loaded(SavedWiFiNetworks.Listing)
    }

    @Published private(set) var state: State = .idle
    @Published var selection: Set<String> = []
    @Published private(set) var isForgetting = false
    @Published private(set) var connection: SavedWiFiNetworks.ConnectionDetails?
    /// Passwords by SSID, kept in memory until hidden or MacFresh quits.
    @Published private(set) var passwords: [String: String] = [:]
    /// Networks whose password is being read right now.
    @Published private(set) var revealing: Set<String> = []
    /// Networks with no stored password (open networks, or saved elsewhere).
    @Published private(set) var missingPasswords: Set<String> = []
    private var revealTask: Task<Void, Never>?
    @Published var notice: (text: String, isError: Bool)?

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var networks: [SavedWiFiNetwork] {
        if case .loaded(let listing) = state { return listing.networks }
        return []
    }

    var currentSSID: String? {
        if case .loaded(let listing) = state { return listing.currentSSID }
        return nil
    }

    var selectedNetworks: [SavedWiFiNetwork] {
        networks.filter { selection.contains($0.id) }
    }

    func loadIfNeeded() {
        if case .idle = state { load() }
    }

    func load() {
        guard !isLoading else { return }
        state = .loading
        Task {
            // The list comes first; the slower link details follow.
            let listing = await SavedWiFiNetworks.list()
            state = .loaded(listing)
            let ids = Set(listing.networks.map(\.id))
            selection = selection.intersection(ids)
            if listing.hasWiFi {
                connection = await SavedWiFiNetworks.connectionDetails()
            }
        }
    }

    /// Reads one network's password; macOS asks the user to approve it.
    func reveal(_ network: SavedWiFiNetwork) {
        guard revealTask == nil, !revealing.contains(network.ssid) else { return }
        revealTask = Task { [weak self] in
            _ = await self?.read(network)
            self?.revealTask = nil
        }
    }

    func stopRevealing() {
        revealTask?.cancel()
        revealTask = nil
    }

    /// Returns false when the user cancelled, so a batch can stop.
    private func read(_ network: SavedWiFiNetwork) async -> Bool {
        revealing.insert(network.ssid)
        defer { revealing.remove(network.ssid) }
        do {
            passwords[network.ssid] = try await SavedWiFiNetworks.password(for: network.ssid)
            return true
        } catch SavedWiFiNetworks.PasswordError.cancelled {
            return false
        } catch SavedWiFiNetworks.PasswordError.notFound {
            missingPasswords.insert(network.ssid)
            return true
        } catch {
            notice = (error.localizedDescription, true)
            return false
        }
    }

    /// Passwords live in memory only while they are shown.
    func hideAllPasswords() {
        stopRevealing()
        passwords = [:]
        missingPasswords = []
    }

    func forgetSelected() {
        let targets = selectedNetworks
        guard !targets.isEmpty, !isForgetting else { return }
        isForgetting = true
        Task {
            do {
                try await SavedWiFiNetworks.forget(targets)
                let listing = await SavedWiFiNetworks.list()
                let remaining = Set(listing.networks.map(\.id))
                let forgotten = targets.filter { !remaining.contains($0.id) }.count
                withAnimation(MotionTokens.gentle) { state = .loaded(listing) }
                selection = selection.intersection(remaining)
                if forgotten == targets.count {
                    notice = (forgotten == 1
                              ? String(localized: "1 network was forgotten.")
                              : String(format: String(localized: "%lld networks were forgotten."), Int64(forgotten)), false)
                } else {
                    notice = (String(format: String(localized: "%lld of %lld networks were forgotten. macOS kept the rest."), Int64(forgotten), Int64(targets.count)), true)
                }
            } catch SavedWiFiNetworks.ForgetError.cancelled {
                notice = nil
            } catch {
                notice = (error.localizedDescription, true)
            }
            isForgetting = false
        }
    }
}

/// Protection › Wi-Fi: networks this Mac joins automatically, with a way to
/// forget the ones no longer used.
struct SavedWiFiView: View {
    @ObservedObject var model: SavedWiFiModel
    @State private var confirming = false

    var body: some View {
        ProtectionTabPage {
            ProtectionTabHeader(
                title: "Saved Wi-Fi Networks",
                subtitle: "Networks your Mac joins on its own. Forget the ones you don't use anymore, like hotel, airport or café Wi-Fi.",
                icon: "wifi"
            ) {
                EmptyView()
            }
            if let notice = model.notice {
                NoticeBanner(text: notice.text, isError: notice.isError) { model.notice = nil }
            }
            content
        }
        .safeAreaInset(edge: .bottom) {
            if !model.selection.isEmpty {
                forgetBar
            }
        }
        .task { model.loadIfNeeded() }
        .onDisappear { model.hideAllPasswords() }
        .alert(forgetTitle, isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { model.forgetSelected() }
        } message: {
            Text(forgetMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProtectionStateCard(
                icon: "wifi",
                title: "Reading saved networks",
                message: "Asking macOS for the networks this Mac remembers.",
                isLoading: true
            )
        case .loaded(let listing):
            if !listing.hasWiFi {
                ProtectionStateCard(
                    icon: "wifi.slash",
                    tint: .secondary,
                    title: "No Wi-Fi on this Mac",
                    message: "This Mac has no Wi-Fi hardware, so there are no saved networks."
                )
            } else if listing.networks.isEmpty {
                ProtectionStateCard(
                    icon: "checkmark.seal",
                    tint: Tint.green,
                    title: "No saved networks",
                    message: "Your Mac doesn't remember any Wi-Fi network."
                )
            } else {
                if let connection = model.connection {
                    connectionStrip(connection)
                }
                list(listing)
                ProtectionFootnote(
                    icon: "lock",
                    text: "Forgetting a network asks for your administrator password. You can join it again anytime."
                )
            }
        }
    }

    /// A compact table: every network on one line with its password.
    private func list(_ listing: SavedWiFiNetworks.Listing) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { !model.networks.isEmpty && model.selection.count == model.networks.count },
                    set: { model.selection = $0 ? Set(model.networks.map(\.id)) : [] }
                ))
                .toggleStyle(AnimatedCheckboxStyle(tint: SectionPalette.protection.accent))
                .labelsHidden()
                .disabled(model.isForgetting)
                .accessibilityLabel("Select all")
                Text(listing.networks.count == 1
                     ? String(localized: "1 saved network")
                     : String(format: String(localized: "%lld saved networks"), Int64(listing.networks.count)))
                    .font(.system(size: 12.5, weight: .semibold))
                PasswordInfoButton()
                Spacer()
                if !model.passwords.isEmpty {
                    Button { model.hideAllPasswords() } label: {
                        Label("Hide passwords", systemImage: "eye.slash")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            HStack(spacing: 10) {
                Color.clear.frame(width: 14, height: 1)
                Text("Network").frame(maxWidth: .infinity, alignment: .leading)
                Text("Password").frame(width: 300, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            Divider().opacity(0.4)

            LazyVStack(spacing: 0) {
                ForEach(Array(listing.networks.enumerated()), id: \.element.id) { index, network in
                    WiFiRow(
                        network: network,
                        position: index + 1,
                        isCurrent: network.ssid == listing.currentSSID,
                        password: model.passwords[network.ssid],
                        isMissing: model.missingPasswords.contains(network.ssid),
                        isRevealing: model.revealing.contains(network.ssid),
                        reveal: { model.reveal(network) },
                        isSelected: Binding(
                            get: { model.selection.contains(network.id) },
                            set: { isOn in
                                if isOn { model.selection.insert(network.id) } else { model.selection.remove(network.id) }
                            }
                        ),
                        isDisabled: model.isForgetting,
                        isStriped: index.isMultiple(of: 2)
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .background(GlassPanelBackground(cornerRadius: 18))
    }

    /// The current connection's link in one quiet line of chips.
    private func connectionStrip(_ connection: SavedWiFiNetworks.ConnectionDetails) -> some View {
        let items: [(String, String?)] = [
            ("lock.fill", connection.security),
            ("dot.radiowaves.left.and.right", connection.channel),
            ("wifi", connection.standard),
            ("speedometer", connection.rateMbps.map { "\($0) Mbps" }),
            ("waveform.path", connection.signal),
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Label("Current connection", systemImage: "wifi")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.trailing, 4)
                ForEach(items.filter { $0.1 != nil }, id: \.0) { icon, value in
                    Label(value ?? "", systemImage: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var forgetBar: some View {
        HStack(spacing: 14) {
            Text(model.selection.count == 1
                 ? String(localized: "1 network selected")
                 : String(format: String(localized: "%lld networks selected"), Int64(model.selection.count)))
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button("Clear") { model.selection = [] }
                .buttonStyle(GlassButtonStyle())
                .disabled(model.isForgetting)
            Button {
                confirming = true
            } label: {
                if model.isForgetting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Forget", systemImage: "wifi.slash")
                }
            }
            .buttonStyle(GlassProminentButtonStyle())
            .disabled(model.isForgetting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(GlassPanelBackground(cornerRadius: 18))
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    private var forgetTitle: String {
        model.selection.count == 1
            ? String(localized: "Forget 1 network?")
            : String(format: String(localized: "Forget %lld networks?"), Int64(model.selection.count))
    }

    private var forgetMessage: String {
        if let current = model.currentSSID, model.selectedNetworks.contains(where: { $0.ssid == current }) {
            return String(format: String(localized: "Your Mac will stop joining them on its own, including “%@”, which you're connected to now. macOS asks for an administrator password."), current)
        }
        return String(localized: "Your Mac will stop joining them on its own. macOS asks for an administrator password.")
    }
}

/// One saved network on a single compact line.
private struct WiFiRow: View {
    let network: SavedWiFiNetwork
    let position: Int
    let isCurrent: Bool
    let password: String?
    let isMissing: Bool
    let isRevealing: Bool
    let reveal: () -> Void
    @Binding var isSelected: Bool
    let isDisabled: Bool
    let isStriped: Bool
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(AnimatedCheckboxStyle(tint: SectionPalette.protection.accent))
                .labelsHidden()
                .disabled(isDisabled)
                .accessibilityLabel(network.ssid)
            HStack(spacing: 8) {
                Image(systemName: "wifi")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCurrent ? Tint.green : .white.opacity(0.45))
                Text(network.ssid)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isCurrent {
                    StatusChip(label: String(localized: "Connected"), systemImage: "checkmark", tint: Tint.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let password {
                    Text(password)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(password, forType: .string)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(hovering || copied ? 0.8 : 0))
                    .help("Copy password")
                    .accessibilityLabel("Copy password")
                } else if isRevealing {
                    ProgressView().controlSize(.small)
                } else if isMissing {
                    Text("—")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .help("No password is saved for this network.")
                } else {
                    Text("••••••••")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                    Button(action: reveal) {
                        Image(systemName: "eye")
                            .font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.4))
                    .help("Show password")
                    .accessibilityLabel("Show password")
                }
                Spacer(minLength: 0)
            }
            .frame(width: 300, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.white.opacity(hovering ? 0.07 : (isStriped ? 0.025 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isDisabled { isSelected.toggle() } }
        .onChange(of: password) { _ in copied = false }
    }
}

/// Explains the macOS prompt behind every password: Wi-Fi passwords live in
/// the System keychain, and macOS asks for the Mac account each time.
private struct PasswordInfoButton: View {
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(shown ? 0.95 : 0.6))
        }
        .buttonStyle(.plain)
        .help("How to see a password")
        .accessibilityLabel("How to see a password")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Label("How to see a password", systemImage: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Wi-Fi passwords are protected by macOS. Every time you show one, macOS asks for your Mac account. This is required by Apple, and MacFresh can't skip it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    row("User name", value: MacAccount.shortName)
                    row("Password", value: String(localized: "The one you use to log in to this Mac"))
                }
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Click “Always Allow” and that network won't ask again. macOS asks once per network, so passwords can't all be shown at once.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320, alignment: .leading)
        }
    }

    private func row(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(verbatim: value)
                .font(.system(size: 12, weight: .medium))
                .textSelection(.enabled)
        }
    }
}
