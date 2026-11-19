import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Conversation with the Assistant, through Apple's on-device model (Apple
// Intelligence, macOS 26 or later). The diagnosis itself stays on fixed rules
// (`AssistantRules`). MacDash gathers every fact itself (the analysis, and a
// fresh reading of the Mac with each question) and the model only puts them
// into words: the small on-device model is good at wording and unreliable at
// deciding when to fetch something. It has no tools and never acts; every
// move still goes through the Assistant's own Review button.
// Nothing leaves the Mac, and nothing runs until the person asks something.

/// One line of the conversation.
struct AssistantChatMessage: Identifiable, Equatable {
    enum Role { case person, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

@MainActor
final class AssistantChat: ObservableObject {
    static let shared = AssistantChat()

    /// Whether the conversation can be offered, and if not, why.
    enum Availability: Equatable {
        case available
        case needsNewerMacOS
        case deviceNotEligible
        case appleIntelligenceOff
        case modelNotReady
        case languageNotSupported

        var explanation: String? {
            switch self {
            case .available: return nil
            case .needsNewerMacOS: return String(localized: "Chat needs macOS 26 or later with Apple Intelligence.")
            case .deviceNotEligible: return String(localized: "This Mac can't run Apple Intelligence.")
            case .appleIntelligenceOff: return String(localized: "Turn on Apple Intelligence in System Settings to chat with the Assistant.")
            case .modelNotReady: return String(localized: "Apple Intelligence is still getting ready. Try again in a few minutes.")
            case .languageNotSupported: return String(localized: "The on-device model doesn't support this language yet.")
            }
        }
    }

    @Published private(set) var messages: [AssistantChatMessage] = []
    @Published private(set) var isResponding = false
    @Published private(set) var availability: Availability = .needsNewerMacOS
    @Published var notice: String?

    /// The analysis the conversation is about; nil before the first one.
    private var report: AssistantReport?
    /// A `LanguageModelSession` wrapper on macOS 26+, kept untyped so this
    /// class still builds for macOS 13.
    private var session: AnyObject?
    private var task: Task<Void, Never>?

    private init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        // Demo mode shows a fictional conversation and never loads the model.
        if DemoMode.isActive { availability = .available; return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            availability = AssistantModelSession.availability(language: Self.answerLanguage.locale)
            return
        }
        #endif
        availability = .needsNewerMacOS
    }

    /// Opening the chat starts a fresh conversation about this analysis
    /// (or about none) and gets the model ready.
    func begin(_ report: AssistantReport?) {
        self.report = report
        startOver()
        if DemoMode.isActive, report != nil { messages = AssistantDemo.conversation }
        prepare()
    }

    /// Closing the chat forgets it: no message, question or session is kept.
    func end() {
        startOver()
        report = nil
    }

    func startOver() {
        task?.cancel()
        task = nil
        isResponding = false
        messages = []
        notice = nil
        session = nil
    }

    /// Loads the model ahead of the first question, so the first answer comes sooner.
    func prepare() {
        guard !DemoMode.isActive else { return }
        refreshAvailability()
        guard availability == .available else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { currentSession()?.prewarm() }
        #endif
    }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding, !DemoMode.isActive else { return }
        refreshAvailability()
        guard availability == .available else { return }
        notice = nil
        messages.append(AssistantChatMessage(role: .person, text: question))
        messages.append(AssistantChatMessage(role: .assistant, text: ""))
        let answerID = messages[messages.count - 1].id
        isResponding = true

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let session = currentSession() {
            task = Task { [weak self] in
                do {
                    try await session.answer(question) { partial in
                        self?.update(answerID, with: partial)
                    }
                } catch is CancellationError {
                } catch {
                    self?.fail(answerID, error)
                }
                self?.finish(answerID)
            }
            return
        }
        #endif
        finish(answerID)
    }

    func stop() {
        task?.cancel()
    }

    // MARK: - Private

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func currentSession() -> AssistantModelSession? {
        if let session = session as? AssistantModelSession { return session }
        let created = AssistantModelSession(report: report, language: Self.answerLanguage.name)
        session = created
        return created
    }
    #endif

    private func update(_ id: UUID, with text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func finish(_ id: UUID) {
        // An answer that never started is dropped rather than left empty.
        if let index = messages.firstIndex(where: { $0.id == id }), messages[index].text.isEmpty {
            messages.remove(at: index)
        }
        isResponding = false
        task = nil
    }

    private func fail(_ id: UUID, _ error: Error) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                // The model's memory is full: carry on in a fresh conversation.
                session = nil
                notice = String(localized: "The conversation got too long, so it started over.")
            case .guardrailViolation, .refusal:
                notice = String(localized: "The Assistant can't answer that.")
            case .unsupportedLanguageOrLocale:
                availability = .languageNotSupported
            case .assetsUnavailable:
                availability = .modelNotReady
            default:
                notice = String(localized: "The Assistant couldn't answer. Try again.")
            }
            return
        }
        #endif
        notice = String(localized: "The Assistant couldn't answer. Try again.")
    }

    /// The language MacDash shows, which is the language the answers come in.
    static var answerLanguage: (locale: Locale, name: String) {
        let code: String
        switch AppLanguage.current {
        case .system: code = Bundle.main.preferredLocalizations.first ?? "en"
        case let language: code = language.rawValue
        }
        let locale = Locale(identifier: code)
        let name = Locale(identifier: "en").localizedString(forIdentifier: code) ?? "English"
        return (locale, name)
    }
}

// MARK: - What the model is told

/// The facts the model starts from: the analysis in plain lines. Kept short,
/// since the on-device model's memory is small; the files behind each
/// recommendation are read on request (`findingDetails`).
enum AssistantChatFacts {
    /// Which Mac this is, so answers can be about this one.
    static var identity: String {
        let info = MacSystemInfo.current
        return "This Mac: \(info.productFamily), \(info.chip), \(info.memory) of memory, \(info.osVersion)."
    }

    static func instructions(report: AssistantReport?, language: String, now: Date = Date()) -> String {
        // The names exactly as the person sees them on screen.
        let review = reviewLabel
        let screens = ["Smart Care", "Applications", "Space Lens", "Processes", "Drive Offload"]
            .map { String(localized: String.LocalizationValue($0)) }
            .joined(separator: ", ")
        return """
        You are the Assistant inside MacDash, the Mac cleaning app the person is using right now. \
        You run on this Mac with Apple Intelligence; nothing leaves the Mac.

        Rules:
        - You explain and advise. You cannot delete, move, quit or change anything, and never say or imply you did. \
        When asked to do something, say plainly that the person does it in MacDash: the "\(review)" button \
        on a recommendation on this screen, or one of these screens: \(screens).
        - Use only the facts below and the live reading sent with each question. \
        Never invent sizes, files, apps or numbers. If something isn't there, say so.
        - Be brief: at most five short sentences or a short list, in plain words without jargon.
        - Always answer in \(language).

        \(identity)
        \(summary(report: report, now: now))
        """
    }

    /// One question as the model receives it: the person's words after a
    /// fresh reading of the Mac, so questions about speed get real numbers.
    static func prompt(question: String, activity: String) -> String {
        """
        Live reading of this Mac right now:
        \(activity)

        Question: \(question)
        """
    }

    static func summary(report: AssistantReport?, now: Date = Date()) -> String {
        guard let report else {
            var lines = ["No analysis has been run yet."]
            if let disk = diskNow() {
                lines.append("Startup disk right now: \(size(disk.free)) free of \(size(disk.total)).")
            }
            return lines.joined(separator: "\n")
        }

        var lines: [String] = []
        let when = RelativeDateTimeFormatter().localizedString(for: report.date, relativeTo: now)
        if let scope = report.scope {
            lines.append("Latest analysis (\(when)) covered one folder: \(abbreviate(scope)), \(size(report.scopeSize ?? 0)).")
        } else {
            lines.append("Latest analysis (\(when)) covered the whole Mac.")
        }
        if report.diskTotal > 0 {
            lines.append("Startup disk: \(size(report.diskFree)) free of \(size(report.diskTotal)).")
        }
        if !report.headline.isEmpty { lines.append("Verdict: \(report.headline)") }
        if report.limitedAccess {
            lines.append("MacDash had no Full Disk Access, so some protected folders were not measured.")
        }

        let usage = report.usage.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.prefix(6)
        if !usage.isEmpty {
            lines.append("Where the space goes:")
            for area in usage {
                let top = area.items.sorted { $0.bytes > $1.bytes }.prefix(3)
                    .map { "\($0.name) \(size($0.bytes))" }.joined(separator: ", ")
                lines.append("- \(area.title): \(size(area.bytes))" + (top.isEmpty ? "" : " (largest: \(top))"))
            }
        }

        let open = report.findings.filter { $0.status.isOpen }.sorted { $0.severity.rank < $1.severity.rank }
        if open.isEmpty {
            lines.append("Recommendations: none open; the Mac is in good shape.")
        } else {
            lines.append("Open recommendations, most urgent first:")
            for finding in open.prefix(10) {
                var line = "- [\(finding.severity.rawValue)] \(finding.title)"
                if finding.reclaimable > 0 { line += ", frees up to \(size(finding.reclaimable))" }
                line += ". \(finding.recommendation)"
                switch finding.action {
                case .trash: line += " Button: \(reviewLabel)."
                case .openTool: if let tool = finding.tool { line += " Done in the \(tool.title) screen." }
                case .advice: break
                }
                lines.append(line)
                let largest = finding.targets.sorted { $0.size > $1.size }.prefix(3)
                if !largest.isEmpty {
                    lines.append("  Largest: " + largest.map { "\($0.label) \(size($0.size)) (\(abbreviate($0.path)))" }.joined(separator: ", ") + ".")
                }
            }
        }
        let handled = report.findings.filter { !$0.status.isOpen }
        if !handled.isEmpty {
            lines.append("Already handled: " + handled.map(\.title).joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// The Review button's label as shown, without its ellipsis.
    static var reviewLabel: String {
        String(localized: "Review…").trimmingCharacters(in: CharacterSet(charactersIn: "…."))
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func diskNow() -> (free: Int64, total: Int64)? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, let total = values?.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }
}

/// What the Mac is doing right now, in lines the model can read: the same
/// reading as the Processes screen, taken twice a second apart so CPU shares
/// are real. Reads only; asks for no permission.
enum MacActivitySnapshot {
    private static var cached: (text: String, at: Date)?

    /// A reading at most 20 seconds old.
    @MainActor
    static func recent() async -> String {
        if let cached, Date().timeIntervalSince(cached.at) < 20 { return cached.text }
        let text = await read()
        cached = (text, Date())
        return text
    }

    @MainActor
    static func read() async -> String {
        let model = PerformanceModel()
        await model.sample()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await model.sample()

        var lines: [String] = []
        lines.append("Powered on for \(MacSystemInfo.uptimeText).")
        lines.append("CPU in use: \(Int((model.cpuTotal * 100).rounded()))%.")
        if let memory = model.snapshot {
            lines.append("Memory: \(bytes(memory.used)) used of \(bytes(memory.total)), pressure \(memory.pressure.label.lowercased()), swap \(bytes(memory.swapUsed)).")
        }
        if let temperature = model.temperature {
            lines.append("Chip temperature: \(Int(temperature.rounded())) °C.")
        }
        switch model.thermalState {
        case .serious, .critical: lines.append("macOS is slowing the Mac down to cool it.")
        default: break
        }
        if !model.openApps.isEmpty {
            lines.append("Open apps, heaviest first:")
            for app in model.openApps.sorted(by: { $0.memoryBytes > $1.memoryBytes }).prefix(8) {
                var line = "- \(app.name): \(bytes(app.memoryBytes)) memory"
                if let cpu = app.cpuFraction { line += ", \(Int((cpu * 100).rounded()))% CPU" }
                lines.append(line)
            }
        }
        if !model.background.isEmpty {
            lines.append("Heavy in the background: " + model.background.map { group in
                var text = "\(group.name) \(bytes(group.bytes))"
                if let cpu = group.cpuFraction { text += " \(Int((cpu * 100).rounded()))% CPU" }
                return text
            }.joined(separator: ", ") + ".")
        }
        let insights = model.insights
        if !insights.isEmpty {
            lines.append("MacDash's own reading: " + insights.map { "\($0.title) \($0.body)" }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}

// MARK: - Apple's on-device model

#if canImport(FoundationModels)
@available(macOS 26.0, *)
final class AssistantModelSession {
    private let session: LanguageModelSession

    init(report: AssistantReport?, language: String) {
        session = LanguageModelSession(
            model: .default,
            instructions: AssistantChatFacts.instructions(report: report, language: language)
        )
    }

    static func availability(language: Locale) -> AssistantChat.Availability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale(language) ? .available : .languageNotSupported
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable: return .modelNotReady
        }
    }

    func prewarm() {
        session.prewarm()
    }

    /// Streams the answer; `partial` gets the whole text so far each time.
    @MainActor
    func answer(_ question: String, partial: @escaping @MainActor (String) -> Void) async throws {
        let activity = await MacActivitySnapshot.recent()
        try Task.checkCancellation()
        let stream = session.streamResponse(
            to: AssistantChatFacts.prompt(question: question, activity: activity),
            options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 500)
        )
        for try await snapshot in stream {
            try Task.checkCancellation()
            partial(snapshot.content)
        }
    }
}

#endif
