import SwiftUI

/// What opens the chat: the analysis it is about and, when a suggestion was
/// clicked, the question to ask straight away.
struct AssistantChatRequest: Identifiable {
    let id = UUID()
    let report: AssistantReport?
    var question: String? = nil
}

/// "Ask the Assistant" on the Assistant screen: one card that opens the
/// conversation in its own window, with a few questions to start from. The
/// card holds no conversation itself.
struct AssistantChatLauncher: View {
    let report: AssistantReport?
    let accent: Color
    let open: (AssistantChatRequest) -> Void

    @ObservedObject private var chat = AssistantChat.shared
    @State private var hovering = false

    var body: some View {
        AssistantPanel(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    open(AssistantChatRequest(report: report))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(accent.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ask the Assistant")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                            Text(chat.availability.explanation ?? String(localized: "Apple Intelligence, on this Mac. It explains; only you act."))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if isAvailable {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(accent.opacity(hovering ? 1 : 0.7))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0.07)))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)

                if isAvailable {
                    HStack(spacing: 8) {
                        ForEach(AssistantChatSheet.suggestions(for: report), id: \.self) { suggestion in
                            Button {
                                open(AssistantChatRequest(report: report, question: suggestion))
                            } label: {
                                Text(suggestion)
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.white.opacity(0.07)))
                                    .overlay(Capsule().strokeBorder(accent.opacity(0.25), lineWidth: 0.8))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        // Only whether chat is possible is checked here; the model itself
        // loads when the conversation opens.
        .onAppear { chat.refreshAvailability() }
    }

    private var isAvailable: Bool { chat.availability == .available }
}

/// The conversation, in its own window over the Assistant: about the analysis
/// on screen and what the Mac is doing now, answered by Apple's on-device
/// model. Closing it forgets everything; nothing is saved. The findings and
/// their Review buttons stay the only way anything gets cleaned.
struct AssistantChatSheet: View {
    let request: AssistantChatRequest
    let accent: Color
    let close: () -> Void

    @ObservedObject private var chat = AssistantChat.shared
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func suggestions(for report: AssistantReport?) -> [String] {
        report == nil
            ? [String(localized: "Why is my Mac slow?"), String(localized: "What is using memory right now?")]
            : [String(localized: "What should I do first?"), String(localized: "What is using the most space?"), String(localized: "Why is my Mac slow?")]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 14)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.6)
            conversation
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.6)
            VStack(alignment: .leading, spacing: 8) {
                if let notice = chat.notice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(Tint.yellow.opacity(0.9))
                }
                input
                Label("Nothing from this conversation is kept after you close it.", systemImage: "lock")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 600)
        .background {
            ZStack {
                SectionPalette.assistant.deep
                RadialGradient(colors: [SectionPalette.assistantGlow[0].opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
                RadialGradient(colors: [SectionPalette.assistantGlow[2].opacity(0.1), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 480)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: chat.messages)
        .onAppear {
            chat.begin(request.report)
            if let question = request.question {
                chat.send(question)
            } else {
                inputFocused = true
            }
        }
        // Closing forgets the conversation, however the window was closed.
        .onDisappear { chat.end() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask the Assistant")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("Apple Intelligence, on this Mac. It explains; only you act.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 8)
            if !chat.messages.isEmpty {
                Button {
                    chat.startOver()
                    draft = ""
                    inputFocused = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("New conversation")
                .accessibilityLabel("New conversation")
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(GlassIconButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Close. The conversation isn't kept.")
            .accessibilityLabel("Close")
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let explanation = chat.availability.explanation {
                        Label(explanation, systemImage: "info.circle")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if chat.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(chat.messages) { message in
                            bubble(message)
                                .id(message.id)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.messages) { messages in
                guard let last = messages.last else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// Before the first question: what it knows, and a few to start from.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.report == nil
                 ? "Ask about what your Mac is doing right now."
                 : "Ask about this analysis or about what your Mac is doing right now.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.suggestions(for: request.report), id: \.self) { suggestion in
                    Button {
                        chat.send(suggestion)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(accent)
                            Text(suggestion)
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent.opacity(0.2), lineWidth: 0.8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: AssistantChatMessage) -> some View {
        switch message.role {
        case .person:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.opacity(0.16)))
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.top, 3)
                if message.text.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Thinking…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                } else {
                    Text(Self.formatted(message.text))
                        .font(.system(size: 13))
                        .lineSpacing(2.5)
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 40)
            }
        }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about your Mac…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.3)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(inputFocused ? accent.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                )
                .disabled(chat.availability != .available)
            if chat.isResponding {
                Button(action: chat.stop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .help("Stop")
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? accent : Color.white.opacity(0.25))
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send")
                .accessibilityLabel("Send")
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend, !chat.isResponding else { return }
        chat.send(draft)
        draft = ""
    }

    /// The model writes light Markdown (bold, lists); show it as such.
    static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
