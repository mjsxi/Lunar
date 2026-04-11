//
//  ChatView.swift
//  fullmoon
//
//  Created by Jordan Singer on 12/3/24.
//

import MarkdownUI
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var appManager: AppManager
    @EnvironmentObject var knowledgeBase: KnowledgeBaseIndex
    @Environment(\.modelContext) var modelContext
    @Binding var currentThread: Thread?
    @Environment(LLMEvaluator.self) var llm
    @Namespace var bottomID
    @State var showModelPicker = false
    @State var showServerError = false
    @State var prompt = ""
    @FocusState.Binding var isPromptFocused: Bool
    @Binding var showChats: Bool
    @Binding var showSettings: Bool
    
    @State var thinkingTime: TimeInterval?
    
    @State private var generatingThreadID: UUID?
    @State private var titlingScheduled: Set<UUID> = []
    @State private var emptyStatePhrase: String = ChatView.emptyStatePhrases.randomElement() ?? "Say something..."
    @State private var moonRotation: Double = 0

    static let emptyStatePhrases: [String] = [
        "Say something...",
        "Well what do you wanna know?",
        "How can I help you today?",
        "What's on your mind?",
        "Ask me anything.",
        "Got a question?",
        "Let's chat.",
        "Where should we start?",
        "Curious about something?",
        "Spit it out, I'm listening."
    ]

    var isPromptEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    let platformBackgroundColor: Color = {
        #if os(iOS)
        return Color(UIColor.secondarySystemBackground)
        #elseif os(macOS)
        return Color(NSColor.secondarySystemFill)
        #endif
    }()

    var chatInput: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField(inputPlaceholder, text: $prompt, axis: .vertical)
                .focused($isPromptFocused)
                .textFieldStyle(.plain)
                .disabled(isModelMismatch)
            #if os(iOS)
                .padding(.horizontal, 16)
            #elseif os(macOS)
                .padding(.horizontal, 12)
                .onSubmit {
                    handleShiftReturn()
                }
                .submitLabel(.send)
            #endif
                .padding(.vertical, 8)
            #if os(iOS)
                .frame(minHeight: 48)
            #elseif os(macOS)
                .frame(minHeight: 32)
            #endif
            #if os(iOS)
            .onSubmit {
                isPromptFocused = true
                generate()
            }
            #endif

            if llm.running {
                stopButton
            } else {
                generateButton
            }
        }
        #if os(iOS)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(platformBackgroundColor)
        )
        #elseif os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.background)
        )
        #endif
    }

    var modelPickerButton: some View {
        Button {
            appManager.playHaptic()
            showModelPicker.toggle()
        } label: {
            Group {
                Image(systemName: "gyroscope")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                #if os(iOS)
                    .frame(width: 16)
                #elseif os(macOS)
                    .frame(width: 12)
                #endif
                    .tint(.primary)
            }
            #if os(iOS)
            .frame(width: 48, height: 48)
            #elseif os(macOS)
            .frame(width: 32, height: 32)
            #endif
            .background(
                Circle()
                    .fill(platformBackgroundColor)
            )
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }

    var generateButton: some View {
        Button {
            generate()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white, isPromptEmpty ? Color.gray : Color.appAccent)
            #if os(iOS)
                .frame(width: 24, height: 24)
            #else
                .frame(width: 16, height: 16)
            #endif
        }
        .disabled(isPromptEmpty || isModelMismatch)
        #if os(iOS)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        #else
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        #endif
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }

    var stopButton: some View {
        Button {
            llm.stop()
        } label: {
            Image(systemName: "stop.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
            #if os(iOS)
                .frame(width: 24, height: 24)
            #else
                .frame(width: 16, height: 16)
            #endif
        }
        .disabled(llm.cancelled)
        #if os(iOS)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        #else
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        #endif
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }

    var chatTitle: String {
        if let name = currentThread?.modelName ?? appManager.currentModelName, !name.isEmpty {
            let displayName = appManager.modelDisplayName(name)
            if isModelMismatch {
                return "\(displayName) ♦"
            }
            return displayName
        }
        return "chat"
    }

    var inputPlaceholder: String {
        if isModelMismatch, let name = currentThread?.modelName {
            return "this chat requires \(appManager.modelDisplayName(name))"
        }
        return "message"
    }

    var isModelMismatch: Bool {
        guard let threadModel = currentThread?.modelName,
              let activeModel = appManager.currentModelName else {
            return false
        }
        return threadModel != activeModel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let currentThread = currentThread {
                    ConversationView(thread: currentThread, generatingThreadID: generatingThreadID)
                } else {
                    Spacer()
                    Text(emptyStatePhrase)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                chatInput
                    .padding()
            }
            .background(
                GeometryReader { geo in
                    Image(.moon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 800)
                        .opacity(currentThread != nil ? 0.2 : 0.5)
                        .animation(.easeInOut(duration: 0.5), value: currentThread != nil)
                        .rotationEffect(.degrees(moonRotation))
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.85 + 100)
                }
            )
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: Color(.windowBackgroundColor), location: 0),
                        .init(color: Color(.windowBackgroundColor).opacity(0.8), location: 0.4),
                        .init(color: Color(.windowBackgroundColor).opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            .onAppear {
                emptyStatePhrase = ChatView.emptyStatePhrases.randomElement() ?? "Say something..."
                moonRotation = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.linear(duration: 540).repeatForever(autoreverses: false)) {
                        moonRotation = 360
                    }
                }
            }
            .navigationTitle(chatTitle)
            .toolbarBackground(.hidden)
            .onChange(of: currentThread?.id) { _, _ in
                if let t = currentThread { maybeScheduleTitleSummary(for: t, immediate: true) }
            }
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .onChange(of: llm.modelInfo) {
                    if case .failed = llm.loadState {
                        showServerError = true
                    }
                }
                .alert("Python Server Failed", isPresented: $showServerError) {
                    Button("Restart Server") {
                        Task {
                            #if os(macOS)
                            await llm.restartPythonBackend()
                            #endif
                        }
                    }
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(llm.modelInfo)
                }
                .sheet(isPresented: $showModelPicker) {
                    NavigationStack {
                        ModelsSettingsView()
                            .environment(llm)
                    }
                    #if os(iOS)
                    .presentationDragIndicator(.visible)
                    .if(appManager.userInterfaceIdiom == .phone) { view in
                        view.presentationDetents([.fraction(0.4)])
                    }
                    #elseif os(macOS)
                    .toolbar {
                        ToolbarItem(placement: .destructiveAction) {
                            Button(action: { showModelPicker.toggle() }) {
                                Text("close")
                            }
                        }
                    }
                    #endif
                }
                .toolbar {
                    #if os(iOS)
                    if appManager.userInterfaceIdiom == .phone {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: {
                                appManager.playHaptic()
                                showChats.toggle()
                            }) {
                                Image(systemName: "list.bullet")
                            }
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            appManager.playHaptic()
                            showModelPicker.toggle()
                        }) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(llm.statusColor)
                                    .frame(width: 8, height: 8)
                                Image(systemName: "gyroscope")
                            }
                            .padding(.leading, 4)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            appManager.playHaptic()
                            showSettings.toggle()
                        }) {
                            Image(systemName: "gearshape")
                        }
                    }
                    #elseif os(macOS)
                    ToolbarItem(id: "models", placement: .primaryAction) {
                        Button {
                            appManager.playHaptic()
                            showModelPicker.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(llm.statusColor)
                                    .frame(width: 8, height: 8)
                                Image(systemName: "gyroscope")
                            }
                            .padding(.leading, 4)
                        }
                        .help("models")
                    }
                    ToolbarItem(id: "settings", placement: .primaryAction) {
                        Button {
                            appManager.playHaptic()
                            showSettings.toggle()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("settings")
                    }
                    #endif
                }
        }
    }

    private func generate() {
        if !isPromptEmpty {
            if currentThread == nil {
                let newThread = Thread(modelName: appManager.currentModelName)
                withAnimation(.easeOut(duration: 0.35)) {
                    currentThread = newThread
                }
                modelContext.insert(newThread)
                try? modelContext.save()
            }

            if let currentThread = currentThread {
                generatingThreadID = currentThread.id
                Task {
                    let message = prompt
                    prompt = ""
                    appManager.playHaptic()
                    sendMessage(Message(role: .user, content: message, thread: currentThread))
                    isPromptFocused = true
                    if let modelName = appManager.currentModelName {
                        let output = await llm.generate(modelName: modelName, thread: currentThread, systemPrompt: appManager.systemPrompt(for: modelName), knowledgeBase: knowledgeBase)
                        sendMessage(Message(role: .assistant, content: output, thread: currentThread, generatingTime: llm.thinkingTime, tokensPerSecond: llm.lastTokensPerSecond, tokenCount: llm.lastTokenCount, timeToFirstToken: llm.lastTimeToFirstToken))
                        generatingThreadID = nil
                        maybeScheduleTitleSummary(for: currentThread)
                    }
                }
            }
        }
    }

    private func sendMessage(_ message: Message) {
        appManager.playHaptic()
        modelContext.insert(message)
        try? modelContext.save()
    }

    private func maybeScheduleTitleSummary(for thread: Thread, immediate: Bool = false) {
        guard appManager.autoTitleDelay.seconds != nil else { return }
        guard thread.title == nil || thread.title?.isEmpty == true else { return }
        let userCount = thread.sortedMessages.filter { $0.role == .user }.count
        guard userCount >= 2 else { return }
        guard !titlingScheduled.contains(thread.id) else { return }
        titlingScheduled.insert(thread.id)
        Task { await runTitleSummary(for: thread, immediate: immediate) }
    }

    private func runTitleSummary(for thread: Thread, immediate: Bool) async {
        guard let delay = appManager.autoTitleDelay.seconds else { return }
        if !immediate {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard let modelName = appManager.currentModelName else { return }

        // Render the conversation as plain text inside ONE user message so
        // the model treats it as material to be summarized, not as a thread
        // it should continue. Small models otherwise just echo their own
        // last reply.
        let convoText = thread.sortedMessages.map { msg -> String in
            let label = msg.role == .user ? "USER" : "ASSISTANT"
            return "\(label): \(msg.content)"
        }.joined(separator: "\n")

        let userPrompt = """
        Below is a conversation between a USER and an ASSISTANT.

        \(convoText)

        TASK: In 5 to 6 words, name the SUBJECT of this conversation \
        (the topic the user is asking about). Do NOT continue the \
        conversation. Do NOT greet. Do NOT use phrases like "Okay", \
        "Sure", "Let me", "Let's", "I can". Reply with the title only — \
        no quotes, no punctuation, no prefix.

        Title:
        """

        let systemPrompt = "You write short, factual chat titles. You never continue conversations. You only output the requested title."

        let raw = await llm.generateSilent(
            modelName: modelName,
            transcript: [(role: "user", content: userPrompt)],
            systemPrompt: systemPrompt,
            maxTokens: 16
        )
        guard var cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        // strip surrounding quotes, leading "Title:", trailing punctuation
        if cleaned.lowercased().hasPrefix("title:") {
            cleaned = String(cleaned.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,!?:;"))
        // strip any <think> blocks reasoning models leak
        if let r = cleaned.range(of: "</think>") {
            cleaned = String(cleaned[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Reject obvious "assistant continuation" outputs — the model
        // ignored the prompt and just kept replying to the conversation.
        let badPrefixes = [
            "okay", "ok ", "sure", "let me", "let's", "alright",
            "i'll", "i can", "i will", "here's", "here is", "of course",
            "absolutely", "great", "happy to", "no problem", "well,",
            "hi ", "hello", "hey "
        ]
        let lower = cleaned.lowercased()
        if badPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return
        }

        // Hard-cap to 6 words.
        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        if words.count > 6 {
            cleaned = words.prefix(6).joined(separator: " ")
        }
        if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces) }
        guard !cleaned.isEmpty else { return }

        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.4)) {
                thread.title = cleaned
            }
            try? modelContext.save()
        }
    }

    #if os(macOS)
    private func handleShiftReturn() {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            prompt.append("\n")
            isPromptFocused = true
        } else {
            generate()
        }
    }
    #endif
}

#Preview {
    @FocusState var isPromptFocused: Bool
    ChatView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false))
        .environmentObject(KnowledgeBaseIndex())
}
