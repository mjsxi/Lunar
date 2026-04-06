import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: Role
    var content: String
    var thinkingContent: String?
    var stats: GenerationStats?

    enum Role: Equatable {
        case user, assistant, system
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.thinkingContent == rhs.thinkingContent
    }

    var asDict: [String: String] {
        let roleString: String
        switch role {
        case .user: roleString = "user"
        case .assistant: roleString = "assistant"
        case .system: roleString = "system"
        }
        return ["role": roleString, "content": content]
    }
}

struct ChatView: View {
    let model: ModelEntry
    @Binding var messages: [ChatMessage]
    @Environment(LLMService.self) private var llm
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 28) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if llm.isGenerating && (!llm.currentStreamText.isEmpty || !llm.currentThinkingText.isEmpty) {
                            let thinkingEnabled = SettingsStorage.settings(for: model).enableThinking
                            MessageBubble(
                                message: ChatMessage(
                                    role: .assistant,
                                    content: llm.currentStreamText,
                                    thinkingContent: thinkingEnabled && !llm.currentThinkingText.isEmpty ? llm.currentThinkingText : nil
                                ),
                                isStreaming: true
                            )
                            .id("streaming")
                        } else if llm.isGenerating {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Thinking...")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .id("thinking")
                        }
                        Color.clear
                            .frame(height: 8)
                            .id("bottom")
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(llm.isGenerating ? .hidden : .automatic)
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: llm.isGenerating) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: llm.currentStreamText) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: llm.currentThinkingText) { _, _ in
                    scrollToBottom(proxy)
                }
            }

            Divider()
            inputBar
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Type something...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit {
                    sendMessage()
                }

            if llm.isGenerating {
                Button {
                    llm.cancelGeneration()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && llm.isModelLoaded && !llm.isGenerating
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend else { return }

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""

        let settings = SettingsStorage.settings(for: model)

        // Build messages array for MLX
        var mlxMessages: [[String: String]] = []
        if !settings.systemPrompt.isEmpty {
            mlxMessages.append(["role": "system", "content": settings.systemPrompt])
        }
        for msg in messages {
            mlxMessages.append(msg.asDict)
        }

        Task {
            let result = await llm.generate(messages: mlxMessages, settings: settings)
            if !result.response.isEmpty || result.thinking != nil {
                let thinking = settings.enableThinking ? result.thinking?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                messages.append(ChatMessage(
                    role: .assistant,
                    content: result.response.trimmingCharacters(in: .whitespacesAndNewlines),
                    thinkingContent: thinking,
                    stats: result.stats
                ))
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}
