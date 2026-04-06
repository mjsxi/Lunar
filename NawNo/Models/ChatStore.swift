import Foundation

struct SavedChat: Identifiable, Codable {
    let id: UUID
    var title: String
    var modelID: UUID
    var vendor: String
    var modelName: String
    var messages: [SavedMessage]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "New Chat", modelID: UUID, vendor: String, modelName: String, messages: [SavedMessage] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.modelID = modelID
        self.vendor = vendor
        self.modelName = modelName
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

struct SavedMessage: Identifiable, Codable {
    let id: UUID
    var role: String // "user", "assistant", "system"
    var content: String
    var thinkingContent: String?
    var tokensPerSecond: Double?
    var totalTokens: Int?
    var timeToFirstToken: Double?
    var totalTime: Double?

    init(id: UUID = UUID(), role: String, content: String, thinkingContent: String? = nil, stats: GenerationStats? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.thinkingContent = thinkingContent
        self.tokensPerSecond = stats?.tokensPerSecond
        self.totalTokens = stats?.totalTokens
        self.timeToFirstToken = stats?.timeToFirstToken
        self.totalTime = stats?.totalTime
    }

    var toChatMessage: ChatMessage {
        let messageRole: ChatMessage.Role
        switch role {
        case "assistant": messageRole = .assistant
        case "system": messageRole = .system
        default: messageRole = .user
        }

        var stats: GenerationStats?
        if let tps = tokensPerSecond, let tokens = totalTokens {
            stats = GenerationStats(
                tokensPerSecond: tps,
                totalTokens: tokens,
                promptTokens: 0,
                timeToFirstToken: timeToFirstToken ?? 0,
                totalTime: totalTime ?? 0
            )
        }

        // Migrate legacy messages that have <think> tags baked into content
        var finalContent = content
        var finalThinking = thinkingContent
        if finalThinking == nil, content.contains("<think>") || content.contains("</think>") {
            let (parsed, thinking) = Self.extractThinking(from: content)
            finalContent = parsed
            finalThinking = thinking
        }

        return ChatMessage(role: messageRole, content: finalContent, thinkingContent: finalThinking, stats: stats)
    }

    private static func extractThinking(from text: String) -> (content: String, thinking: String?) {
        var thinking = ""
        var content = text

        // Case 1: Has <think>...</think>
        while let startRange = content.range(of: "<think>") {
            let before = String(content[content.startIndex..<startRange.lowerBound])
            if let endRange = content.range(of: "</think>", range: startRange.upperBound..<content.endIndex) {
                thinking += content[startRange.upperBound..<endRange.lowerBound]
                content = before + String(content[endRange.upperBound...])
            } else {
                thinking += content[startRange.upperBound...]
                content = before
                break
            }
        }

        // Case 2: Only </think> (tokenizer stripped <think> as special token)
        if thinking.isEmpty, let endRange = content.range(of: "</think>") {
            thinking = String(content[content.startIndex..<endRange.lowerBound])
            content = String(content[endRange.upperBound...])
        }

        let trimmedThinking = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedContent, trimmedThinking.isEmpty ? nil : trimmedThinking)
    }
}

@MainActor @Observable
final class ChatStore {
    var chats: [SavedChat] = []
    var activeChatID: UUID?

    static var chatsRoot: URL {
        let url = ModelStore.appSupportRoot.appendingPathComponent("Chats")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        loadAll()
    }

    var activeChat: SavedChat? {
        chats.first { $0.id == activeChatID }
    }

    /// Match chats to a model by vendor + displayName, so they survive model re-registration
    func chats(for model: ModelEntry) -> [SavedChat] {
        chats.filter { $0.vendor == model.vendor && $0.modelName == model.displayName }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func createChat(for model: ModelEntry) -> SavedChat {
        let chat = SavedChat(modelID: model.id, vendor: model.vendor, modelName: model.displayName)
        chats.append(chat)
        activeChatID = chat.id
        saveChat(chat)
        return chat
    }

    func updateChat(id: UUID, messages: [ChatMessage]) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }

        // Only update timestamp when message count actually changes (new message sent)
        let hadNewMessages = messages.count != chats[index].messages.count

        chats[index].messages = messages.map { msg in
            SavedMessage(
                id: msg.id,
                role: msg.role == .user ? "user" : msg.role == .assistant ? "assistant" : "system",
                content: msg.content,
                thinkingContent: msg.thinkingContent,
                stats: msg.stats
            )
        }
        if hadNewMessages {
            chats[index].updatedAt = Date()
        }

        // Auto-title from first user message
        if chats[index].title == "New Chat",
           let firstUser = messages.first(where: { $0.role == .user }) {
            let title = String(firstUser.content.prefix(40))
            chats[index].title = title.count < firstUser.content.count ? title + "..." : title
        }

        saveChat(chats[index])
    }

    func deleteChat(id: UUID) {
        guard let chat = chats.first(where: { $0.id == id }) else { return }
        let fileURL = Self.fileURL(for: chat)
        try? FileManager.default.removeItem(at: fileURL)

        // Clean empty model/vendor directories
        let modelDir = fileURL.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: modelDir)
            let vendorDir = modelDir.deletingLastPathComponent()
            if let vc = try? FileManager.default.contentsOfDirectory(atPath: vendorDir.path), vc.isEmpty {
                try? FileManager.default.removeItem(at: vendorDir)
            }
        }

        chats.removeAll { $0.id == id }
        if activeChatID == id {
            activeChatID = nil
        }
    }

    func renameChat(id: UUID, title: String) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].title = title
        saveChat(chats[index])
    }

    // MARK: - Per-file Persistence (Chats/{vendor}/{modelName}/{chatID}.json)

    private static func chatDirectory(vendor: String, modelName: String) -> URL {
        let url = chatsRoot
            .appendingPathComponent(vendor)
            .appendingPathComponent(modelName)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fileURL(for chat: SavedChat) -> URL {
        chatDirectory(vendor: chat.vendor, modelName: chat.modelName)
            .appendingPathComponent("\(chat.id.uuidString).json")
    }

    private func saveChat(_ chat: SavedChat) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(chat) {
            try? data.write(to: Self.fileURL(for: chat), options: .atomic)
        }
    }

    /// Scan Chats/{vendor}/{model}/*.json
    private func loadAll() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fm = FileManager.default

        guard let vendors = try? fm.contentsOfDirectory(atPath: Self.chatsRoot.path) else { return }
        for vendor in vendors where !vendor.hasPrefix(".") {
            let vendorURL = Self.chatsRoot.appendingPathComponent(vendor)
            guard let models = try? fm.contentsOfDirectory(atPath: vendorURL.path) else { continue }
            for model in models where !model.hasPrefix(".") {
                let modelURL = vendorURL.appendingPathComponent(model)
                guard let files = try? fm.contentsOfDirectory(atPath: modelURL.path) else { continue }
                for file in files where file.hasSuffix(".json") {
                    let fileURL = modelURL.appendingPathComponent(file)
                    if let data = try? Data(contentsOf: fileURL),
                       let chat = try? decoder.decode(SavedChat.self, from: data) {
                        chats.append(chat)
                    }
                }
            }
        }
    }
}
