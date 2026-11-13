import AppKit
import Foundation

/// Runs analyses, keeps their reports and carries out what the person
/// confirms. It does nothing on its own: no timer, no folder watching, no
/// work at launch. Reports are small JSON files, one per analysis, read only
/// when the Assistant is opened.
@MainActor
final class AssistantStore: ObservableObject {
    static let shared = AssistantStore()

    enum Phase: Equatable {
        case idle
        case analyzing
        case results
    }

    struct Message: Equatable {
        let text: String
        var isError = false
        /// True after items moved, to offer opening the Trash.
        var offersTrash = false
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var step: AssistantStep = .disk
    @Published private(set) var stepDetail = ""
    /// The analysis made in this session. Only this one can be acted on, and
    /// each action checks its items again first. Reports in `history` are
    /// records and never run anything.
    @Published private(set) var live: AssistantReport?
    @Published private(set) var history: [AssistantReport] = []
    @Published private(set) var isHistoryLoaded = false
    /// Items checked again, waiting for confirmation.
    @Published var plan: AssistantPlan?
    @Published private(set) var checkingID: String?
    @Published private(set) var isMoving = false
    @Published var message: Message?
    /// Set when MacDash reopened to apply Full Disk Access from this screen:
    /// the analysis starts as soon as the screen shows.
    @Published var analyzeWhenShown = false

    /// Older reports are removed automatically beyond this many.
    static let reportLimit = 100
    /// When the last analysis finished, for the toolbar panel's suggestion.
    static let lastAnalysisKey = "assistant.lastAnalysis"

    private let folder: URL
    private let home: String
    private var cancelFlag: AssistantCancelFlag?
    private var analysisID = UUID()

    init(folder: URL? = nil, home: String? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? support.appendingPathComponent("MacDash/Assistant", isDirectory: true)
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    }

    // MARK: - Analysis

    func analyze() {
        guard phase != .analyzing else { return }
        message = nil
        plan = nil
        let id = UUID()
        analysisID = id
        phase = .analyzing
        step = .disk
        stepDetail = ""
        if DemoMode.isActive { runDemo(id); return }

        let flag = AssistantCancelFlag()
        cancelFlag = flag
        let home = home
        let folder = folder
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
        let months = UnusedAppsFinder.configuredMonths
        let started = Date()
        let reporter = ProgressReporter { [weak self] step, detail in
            Task { @MainActor [weak self] in
                guard let self, self.analysisID == id, self.phase == .analyzing else { return }
                self.step = step
                self.stepDetail = detail
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let options = AssistantScanner.Options(
                home: home,
                applicationRoots: ["/Applications", home + "/Applications"],
                fullDiskAccess: FullDiskAccessManager.shared.hasFullDiskAccess,
                runningAppPaths: running,
                unusedMonths: months
            )
            let facts = AssistantScanner.gather(options, cancel: flag) { reporter.report($0, $1) }
            let earlier = Self.readReports(in: folder)
            let report = facts.map {
                AssistantRules.report(
                    from: $0,
                    baselines: earlier.map { AssistantRules.Baseline(date: $0.date, diskFree: $0.diskFree, folderSizes: $0.folderSizes) },
                    duration: Date().timeIntervalSince(started),
                    appVersion: AppVersion.marketing
                )
            }
            await self?.finishAnalysis(report, id: id, earlier: earlier)
        }
    }

    func cancel() {
        guard phase == .analyzing else { return }
        cancelFlag?.cancel()
        analysisID = UUID()
        phase = live == nil ? .idle : .results
    }

    /// Leaves the results screen. The report stays in the history.
    func startOver() {
        guard phase == .results, !isMoving else { return }
        live = nil
        plan = nil
        message = nil
        phase = .idle
    }

    private func finishAnalysis(_ report: AssistantReport?, id: UUID, earlier: [AssistantReport]) {
        guard analysisID == id else { return }
        cancelFlag = nil
        guard let report else {
            phase = live == nil ? .idle : .results
            return
        }
        live = report
        history = [report] + earlier.filter { $0.id != report.id }
        isHistoryLoaded = true
        save(report)
        prune()
        phase = .results
        UserDefaults.standard.set(report.date, forKey: Self.lastAnalysisKey)
        UsageStats.shared.recordScan(.assistant, filesChecked: report.filesChecked)
    }

    // MARK: - Acting on a finding

    /// Checks the finding's items again and presents them for confirmation.
    func review(_ findingID: String) {
        guard checkingID == nil, !isMoving,
              let finding = live?.findings.first(where: { $0.id == findingID }), finding.action == .trash else { return }
        message = nil
        if DemoMode.isActive {
            // Demo: the list is shown as it is; nothing on the Mac is read.
            plan = AssistantPlan(findingID: finding.id, title: finding.title, checkedAt: Date(), items: finding.targets.map {
                AssistantPlanItem(target: $0, size: $0.size, state: .ready, selected: $0.suggested)
            })
            return
        }
        check(finding, keeping: nil)
    }

    private func check(_ finding: AssistantFinding, keeping selection: Set<String>?) {
        checkingID = finding.id
        let context = makeContext()
        Task.detached(priority: .userInitiated) { [weak self] in
            var fresh = AssistantExecutor.check(finding, context: context)
            if let selection {
                for index in fresh.items.indices where fresh.items[index].state == .ready {
                    fresh.items[index].selected = selection.contains(fresh.items[index].id)
                }
            }
            let plan = fresh
            await MainActor.run {
                guard let self, self.checkingID == finding.id else { return }
                self.checkingID = nil
                self.plan = plan
            }
        }
    }

    /// Moves the ticked items to the Trash. A check older than a few minutes
    /// is repeated first, and the list is shown again instead.
    func confirm() {
        guard let plan, !isMoving, checkingID == nil,
              let finding = live?.findings.first(where: { $0.id == plan.findingID }) else { return }
        if DemoMode.isActive { self.plan = nil; return }  // demo: never touch the Mac
        let chosen = plan.selected
        guard !chosen.isEmpty else { return }
        guard plan.isFresh() else {
            message = Message(text: String(localized: "That check was a few minutes old, so everything was checked again. Review the list before continuing."))
            check(finding, keeping: Set(chosen.map(\.id)))
            return
        }
        isMoving = true
        let context = makeContext()
        Task.detached(priority: .userInitiated) { [weak self] in
            let record = AssistantExecutor.moveToTrash(chosen, finding: finding, context: context)
            await self?.apply(record)
        }
    }

    private func apply(_ record: AssistantActionRecord) {
        isMoving = false
        plan = nil
        let moved = Set(record.movedPaths)
        let outcome: String
        if record.moved > 0 {
            var text = String(format: String(localized: "Moved to the Trash: %lld (%@)."), Int64(record.moved), AssistantRules.format(record.bytes))
            if !record.skipped.isEmpty {
                text += " " + String(format: String(localized: "%lld could not be moved."), Int64(record.skipped.count))
            }
            outcome = text
        } else {
            outcome = String(format: String(localized: "Nothing was moved: %@"), record.skipped.first?.reason ?? "")
        }
        update(record.findingID, record: record) { finding in
            finding.targets.removeAll { moved.contains($0.path) }
            finding.total = max(0, finding.total - record.bytes)
            finding.reclaimable = finding.targets.filter(\.suggested).reduce(0) { $0 + $1.size }
            finding.outcome = outcome
            if record.moved > 0 {
                finding.status = finding.targets.isEmpty && finding.omittedCount == 0 ? .done : .partial
            }
        }
        message = record.moved > 0
            ? Message(text: outcome + " " + String(localized: "The space comes back when you empty the Trash."), offersTrash: true)
            : Message(text: outcome, isError: true)
        if record.moved > 0 { Haptics.successWithSound() }
    }

    func ignore(_ findingID: String) {
        guard let finding = live?.findings.first(where: { $0.id == findingID }), finding.status.isOpen else { return }
        let record = AssistantActionRecord(date: Date(), findingID: findingID, findingTitle: finding.title, kind: .ignore)
        update(findingID, record: record) { $0.status = .ignored }
    }

    /// Brings an ignored or handed-over finding back to the open list.
    func restore(_ findingID: String) {
        guard let finding = live?.findings.first(where: { $0.id == findingID }),
              finding.status == .ignored || finding.status == .opened else { return }
        let record = AssistantActionRecord(date: Date(), findingID: findingID, findingTitle: finding.title, kind: .restore)
        update(findingID, record: record) { $0.status = .pending }
    }

    /// Notes that the finding went to another tool, and says which screen to open.
    func handOver(_ findingID: String) -> AppSection? {
        guard let finding = live?.findings.first(where: { $0.id == findingID }), let tool = finding.tool else { return nil }
        let record = AssistantActionRecord(date: Date(), findingID: findingID, findingTitle: finding.title, kind: .openTool)
        update(findingID, record: record) { finding in
            finding.status = .opened
            finding.outcome = String(format: String(localized: "Continued in %@"), tool.title)
        }
        return tool.section
    }

    private func update(_ findingID: String, record: AssistantActionRecord?, _ change: (inout AssistantFinding) -> Void) {
        guard var report = live, let index = report.findings.firstIndex(where: { $0.id == findingID }) else { return }
        change(&report.findings[index])
        if let record { report.actions.append(record) }
        live = report
        if let position = history.firstIndex(where: { $0.id == report.id }) { history[position] = report }
        save(report)
    }

    private func makeContext() -> AssistantExecutor.Context {
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AssistantRunningApp? in
            guard let url = app.bundleURL else { return nil }
            return AssistantRunningApp(
                bundleID: app.bundleIdentifier ?? "",
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                path: url.resolvingSymlinksInPath().path
            )
        }
        return AssistantExecutor.Context(
            home: home,
            runningApps: apps,
            ownBundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            exclusions: CleanupExclusions.paths()
        )
    }

    // MARK: - History

    func loadHistory() {
        guard !isHistoryLoaded else { return }
        if DemoMode.isActive {
            history = AssistantDemo.history
            isHistoryLoaded = true
            return
        }
        let folder = folder
        Task.detached(priority: .utility) { [weak self] in
            let reports = Self.readReports(in: folder)
            await MainActor.run {
                guard let self, !self.isHistoryLoaded else { return }
                self.history = reports
                self.isHistoryLoaded = true
            }
        }
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty, !isMoving else { return }
        for report in history where ids.contains(report.id) {
            if !DemoMode.isActive { try? FileManager.default.removeItem(at: Self.file(for: report, in: folder)) }
        }
        history.removeAll { ids.contains($0.id) }
        if let live, ids.contains(live.id) {
            self.live = nil
            plan = nil
            if phase == .results { phase = .idle }
        }
    }

    func deleteAll() {
        delete(Set(history.map(\.id)))
    }

    func deleteOlder(thanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        delete(Set(history.filter { $0.date < cutoff }.map(\.id)))
    }

    private func prune() {
        guard history.count > Self.reportLimit else { return }
        delete(Set(history.dropFirst(Self.reportLimit).map(\.id)))
    }

    private func save(_ report: AssistantReport) {
        guard !DemoMode.isActive else { return }
        Self.write(report, in: folder)
    }

    // MARK: - Files

    nonisolated static func file(for report: AssistantReport, in folder: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "report-\(formatter.string(from: report.date))-\(report.id.uuidString.prefix(8)).json"
        return folder.appendingPathComponent(name)
    }

    nonisolated static func write(_ report: AssistantReport, in folder: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(for: report, in: folder), options: .atomic)
    }

    /// Every report in `folder`, newest first. Files that can't be read are skipped.
    nonisolated static func readReports(in folder: URL) -> [AssistantReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(AssistantReport.self, from: $0) } }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Demo mode (MACDASH_DEMO=1, site screenshots)

    /// Walks through the steps and shows the fictional report. Nothing is read.
    private func runDemo(_ id: UUID) {
        Task { [weak self] in
            for step in AssistantStep.allCases {
                guard let self, self.analysisID == id else { return }
                self.step = step
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            guard let self, self.analysisID == id else { return }
            self.live = AssistantDemo.report
            self.history = AssistantDemo.history
            self.isHistoryLoaded = true
            self.phase = .results
        }
    }
}

/// Passes step changes through at once and paths at most a few times a second.
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStep: AssistantStep?
    private var lastTime = Date.distantPast
    private let send: @Sendable (AssistantStep, String) -> Void

    init(send: @escaping @Sendable (AssistantStep, String) -> Void) {
        self.send = send
    }

    func report(_ step: AssistantStep, _ detail: String) {
        lock.lock()
        let now = Date()
        let pass = step != lastStep || now.timeIntervalSince(lastTime) > 0.12
        if pass {
            lastStep = step
            lastTime = now
        }
        lock.unlock()
        if pass { send(step, detail) }
    }
}
