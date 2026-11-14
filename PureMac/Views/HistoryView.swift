import SwiftUI

/// History: everything MacDash keeps about what it has done. What it has
/// cleaned and run on this Mac, and every analysis the Assistant made, each
/// one a record that can be opened or deleted. Nothing here runs anything.
/// It is Settings' companion and shares its look: grouped rows, plain symbols.
struct HistoryView: View {
    var onNavigate: (AppSection) -> Void = { _ in }

    @ObservedObject private var stats = UsageStats.shared
    @ObservedObject private var store = AssistantStore.shared
    @EnvironmentObject private var appState: AppState
    @State private var openedReportID: UUID?
    @State private var detailsReport: AssistantReport?

    static let symbol = "clock.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FeaturePageHeader(
                title: Text("History"),
                systemImage: Self.symbol,
                tint: SectionPalette.settings.accent,
                detail: { Text("What MacDash has done on this Mac, and every analysis it made.") },
                accessory: {
                    if openedReportID != nil {
                        Button {
                            openedReportID = nil
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                }
            )

            if openedReportID != nil {
                // One report, opened as a read-only record.
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) { analyses }
                        .padding(.bottom, 24)
                }
            } else {
                SettingsPage {
                    activity
                    analyses
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 960)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(SectionPalette.settings.accent)
        .onAppear { store.loadHistory() }
        .sheet(item: $detailsReport) { report in
            AssistantDetailsSheet(report: report) { detailsReport = nil }
        }
    }

    private var analyses: some View {
        AssistantHistoryView(
            store: store, openedReportID: $openedReportID, accent: SectionPalette.settings.accent,
            analyzeAgain: analyzeAgain,
            showDetails: { detailsReport = $0 }
        )
    }

    private func analyzeAgain(_ report: AssistantReport) {
        openedReportID = nil
        onNavigate(.assistant)
        if let scope = report.scope { store.analyze(folder: scope) } else { store.analyze() }
    }

    // MARK: - What MacDash has done

    private var since: Text {
        let days = stats.daysWithMacTidy == 1
            ? String(localized: "1 day with MacDash")
            : String(format: String(localized: "%lld days with MacDash"), Int64(stats.daysWithMacTidy))
        let date = String(format: String(localized: "Since %@"), stats.firstUse.formatted(date: .long, time: .omitted))
        return Text(verbatim: days + " · " + date)
    }

    private var activity: some View {
        SettingsSection("Activity", footer: since) {
            SettingsRow("Space cleaned", symbol: "sparkles") {
                Text(verbatim: AssistantRules.format(stats.bytesCleaned)).settingsValue()
            }
            SettingsSeparator(indented: true)
            SettingsRow("Tasks run", symbol: "checklist") {
                Text(verbatim: stats.tasksRun.formatted()).settingsValue()
            }
            SettingsSeparator(indented: true)
            SettingsRow("Files checked last time", symbol: "doc.text.magnifyingglass") {
                Text(verbatim: stats.lastFilesChecked.formatted()).settingsValue()
            }
            SettingsSeparator(indented: true)
            SettingsRow("Free on this Mac", symbol: "internaldrive") {
                Text(verbatim: appState.diskInfo.formattedFree).settingsValue()
            }
            SettingsSeparator(indented: true)
            SettingsRow("Last activity", symbol: "clock") {
                if let date = stats.lastActivity {
                    Text(verbatim: (stats.lastActivityKind?.title ?? String(localized: "Activity")) + " · "
                         + date.formatted(date: .abbreviated, time: .shortened))
                        .settingsValue()
                } else {
                    Text("No scan or cleanup yet").settingsValue()
                }
            }
        }
    }
}
