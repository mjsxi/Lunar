import SwiftData
import SwiftUI

@MainActor
@Observable
final class ChatSessionController {
    var currentThread: Thread?
    var prompt = ""
    var generatingThreadID: UUID?
    var activeErrorMessage: String?
    var showingErrorAlert = false
    var pendingRAGOverride: Bool?

    @ObservationIgnored private var preferences: AppPreferences?
    @ObservationIgnored private var modelSettings: ModelSettingsStore?
    @ObservationIgnored private var knowledgeBase: KnowledgeBaseIndex?
    @ObservationIgnored private var usageStats: UsageStatsStore?
    @ObservationIgnored private var llm: LLMEvaluator?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var titleTasks: [UUID: Task<Void, Never>] = [:]

    deinit {
        titleTasks.values.forEach { $0.cancel() }
    }

    func configure(
        preferences: AppPreferences,
        modelSettings: ModelSettingsStore,
        knowledgeBase: KnowledgeBaseIndex,
        usageStats: UsageStatsStore,
        llm: LLMEvaluator,
        modelContext: ModelContext
    ) {
        self.preferences = preferences
        self.modelSettings = modelSettings
        self.knowledgeBase = knowledgeBase
        self.usageStats = usageStats
        self.llm = llm
        self.modelContext = modelContext
    }

    var isPromptEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var chatTitle: String {
        guard let preferences else { return "chat" }
        if let modelName = currentThread?.modelName ?? preferences.currentModelName, !modelName.isEmpty {
            let displayName = modelSettings?.displayName(for: modelName) ?? modelName
            return isModelMismatch ? "\(displayName) ♦" : displayName
        }
        return "chat"
    }

    var inputPlaceholder: String {
        if isModelMismatch, let modelName = currentThread?.modelName {
            return "this chat requires \(modelSettings?.displayName(for: modelName) ?? modelName)"
        }
        return "message"
    }

    var isModelMismatch: Bool {
        guard let threadModel = currentThread?.modelName,
              let activeModel = preferences?.currentModelName else {
            return false
        }
        return threadModel != activeModel
    }

    var isRAGActiveForChat: Bool {
        if let thread = currentThread, let override = thread.ragEnabled {
            return override
        }
        if let pendingRAGOverride {
            return pendingRAGOverride
        }
        return defaultRAGEnabledForCurrentContext
    }

    func selectThread(_ thread: Thread?) {
        currentThread = thread
        pendingRAGOverride = nil
        if let thread {
            maybeScheduleTitleSummary(for: thread, immediate: true)
        }
    }

    func startNewChat() {
        currentThread = nil
        pendingRAGOverride = nil
    }

    func toggleRAGForCurrentChat() {
        if let thread = currentThread {
            let newValue = !isRAGActiveForChat
            thread.ragEnabled = newValue == defaultRAGEnabled(for: thread.modelName) ? nil : newValue
            return
        }

        let newValue = !isRAGActiveForChat
        pendingRAGOverride = newValue == defaultRAGEnabledForCurrentContext ? nil : newValue
    }

    func stopGeneration() {
        llm?.stop()
    }

    func sendCurrentPrompt() async {
        guard !isPromptEmpty else { return }
        guard let preferences,
              let modelSettings,
              let knowledgeBase,
              let llm,
              let modelContext else {
            return
        }
        guard let modelName = preferences.currentModelName else {
            presentError("no model is selected")
            return
        }
        guard !isModelMismatch else { return }

        let messageText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = ""

        let thread = ensureThread(modelName: modelName, using: modelContext)
        generatingThreadID = thread.id

        preferences.playHaptic()
        persist(Message(role: .user, content: messageText, thread: thread), using: modelContext)

        let output = await llm.generate(
            modelName: modelName,
            thread: thread,
            systemPrompt: modelSettings.systemPrompt(for: modelName, default: preferences.systemPrompt),
            knowledgeBase: isRAGActiveForChat ? knowledgeBase : nil
        )

        if shouldRecordUsageStats(for: output, tokenCount: llm.lastTokenCount) {
            usageStats?.recordGeneration(
                tokenCount: llm.lastTokenCount,
                tokensPerSecond: llm.lastTokensPerSecond,
                generatingTime: llm.thinkingTime,
                timeToFirstToken: llm.lastTimeToFirstToken
            )
        }

        persist(
            Message(
                role: .assistant,
                content: output,
                thread: thread,
                generatingTime: llm.thinkingTime,
                tokensPerSecond: llm.lastTokensPerSecond,
                tokenCount: llm.lastTokenCount,
                timeToFirstToken: llm.lastTimeToFirstToken
            ),
            using: modelContext
        )

        generatingThreadID = nil
        maybeScheduleTitleSummary(for: thread)
    }

    func dismissError() {
        showingErrorAlert = false
        activeErrorMessage = nil
    }

    private func ensureThread(modelName: String, using modelContext: ModelContext) -> Thread {
        if let currentThread {
            return currentThread
        }

        let newThread = Thread(modelName: modelName)
        newThread.ragEnabled = pendingRAGOverride
        currentThread = newThread
        pendingRAGOverride = nil
        modelContext.insert(newThread)
        save(modelContext, failureMessage: "couldn't create the chat")
        return newThread
    }

    private var defaultRAGEnabledForCurrentContext: Bool {
        defaultRAGEnabled(for: currentThread?.modelName ?? preferences?.currentModelName)
    }

    private func defaultRAGEnabled(for modelName: String?) -> Bool {
        guard let modelName else { return false }
        return modelSettings?.isRAGEnabled(for: modelName) ?? false
    }

    private func persist(_ message: Message, using modelContext: ModelContext) {
        preferences?.playHaptic()
        modelContext.insert(message)
        save(modelContext, failureMessage: "couldn't save the message")
    }

    private func save(_ modelContext: ModelContext, failureMessage: String) {
        do {
            try modelContext.save()
        } catch {
            presentError("\(failureMessage): \(error.localizedDescription)")
        }
    }

    private func presentError(_ message: String) {
        activeErrorMessage = message
        showingErrorAlert = true
    }

    private func maybeScheduleTitleSummary(for thread: Thread, immediate: Bool = false) {
        guard let preferences,
              let delay = preferences.autoTitleDelay.seconds else { return }
        guard thread.title == nil || thread.title?.isEmpty == true else { return }
        let userCount = thread.sortedMessages.filter { $0.role == .user }.count
        guard userCount >= 2 else { return }
        guard titleTasks[thread.id] == nil else { return }

        titleTasks[thread.id] = Task { [weak self] in
            defer { self?.titleTasks[thread.id] = nil }
            if !immediate {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.runTitleSummary(for: thread)
        }
    }

    private func runTitleSummary(for thread: Thread) async {
        guard let preferences,
              let modelName = preferences.currentModelName,
              let llm,
              let modelContext else { return }

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

        if cleaned.lowercased().hasPrefix("title:") {
            cleaned = String(cleaned.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,!?:;"))
        if let range = cleaned.range(of: "</think>") {
            cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let badPrefixes = [
            "okay", "ok ", "sure", "let me", "let's", "alright",
            "i'll", "i can", "i will", "here's", "here is", "of course",
            "absolutely", "great", "happy to", "no problem", "well,",
            "hi ", "hello", "hey "
        ]
        let lower = cleaned.lowercased()
        guard !badPrefixes.contains(where: { lower.hasPrefix($0) }) else { return }

        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        if words.count > 6 {
            cleaned = words.prefix(6).joined(separator: " ")
        }
        if cleaned.count > 60 {
            cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        guard !cleaned.isEmpty else { return }

        withAnimation(.easeInOut(duration: 0.3)) {
            thread.title = cleaned
        }
        save(modelContext, failureMessage: "couldn't save the chat title")
    }

    private func shouldRecordUsageStats(for output: String, tokenCount: Int) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.hasPrefix("Failed:") else { return false }
        return tokenCount > 0
    }
}
