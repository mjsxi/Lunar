import Foundation

enum BackendType: String, Codable, CaseIterable, Equatable {
    case auto
    case swift
    case python
}

struct ModelSettings: Codable, Equatable {
    var systemPrompt: String
    var contextWindowSize: Int
    var temperature: Float
    var topK: Int
    var topP: Float
    var maxTokens: Int
    var repetitionPenalty: Float
    var repetitionContextSize: Int
    var seed: UInt64?
    var backend: BackendType
    var enableThinking: Bool

    static let defaults = ModelSettings(
        systemPrompt: "You are a helpful assistant.",
        contextWindowSize: 4096,
        temperature: 0.7,
        topK: 40,
        topP: 0.9,
        maxTokens: 2048,
        repetitionPenalty: 1.1,
        repetitionContextSize: 64,
        seed: nil,
        backend: .auto,
        enableThinking: true
    )

    enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case contextWindowSize = "context_window"
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case repetitionPenalty = "repetition_penalty"
        case repetitionContextSize = "repetition_context"
        case seed
        case backend
        case enableThinking = "enable_thinking"
    }

    init(systemPrompt: String, contextWindowSize: Int, temperature: Float, topK: Int, topP: Float, maxTokens: Int, repetitionPenalty: Float, repetitionContextSize: Int, seed: UInt64?, backend: BackendType = .auto, enableThinking: Bool = true) {
        self.systemPrompt = systemPrompt
        self.contextWindowSize = contextWindowSize
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.maxTokens = maxTokens
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.seed = seed
        self.backend = backend
        self.enableThinking = enableThinking
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        contextWindowSize = try container.decode(Int.self, forKey: .contextWindowSize)
        temperature = try container.decode(Float.self, forKey: .temperature)
        topK = try container.decode(Int.self, forKey: .topK)
        topP = try container.decode(Float.self, forKey: .topP)
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        repetitionPenalty = try container.decode(Float.self, forKey: .repetitionPenalty)
        repetitionContextSize = try container.decode(Int.self, forKey: .repetitionContextSize)
        seed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
        backend = try container.decodeIfPresent(BackendType.self, forKey: .backend) ?? .auto
        enableThinking = try container.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? true
    }

    var estimatedSystemPromptTokens: Int {
        max(1, systemPrompt.count / 4)
    }

    var availableContextTokens: Int {
        max(0, contextWindowSize - estimatedSystemPromptTokens)
    }
}

enum SettingsStorage {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static func settingsURL(for model: ModelEntry) -> URL {
        model.directoryURL.appendingPathComponent("nawno_settings.json")
    }

    static func settings(for model: ModelEntry) -> ModelSettings {
        let url = settingsURL(for: model)
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(ModelSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    static func save(_ settings: ModelSettings, for model: ModelEntry) {
        let url = settingsURL(for: model)
        if let data = try? encoder.encode(settings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
