//
//  Data.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/5/24.
//

import SwiftUI
import SwiftData

@MainActor
final class AppPreferences: ObservableObject {
    enum LayoutType {
        case mac, phone, pad, unknown
    }

    @AppStorage("systemPrompt") var systemPrompt = "you are a helpful assistant"
    @AppStorage("appTintColor") var appTintColor: AppTintColor = .monochrome
    @AppStorage("appFontDesign") var appFontDesign: AppFontDesign = .standard
    @AppStorage("appFontSize") var appFontSize: AppFontSize = .medium
    @AppStorage("appFontWidth") var appFontWidth: AppFontWidth = .standard
    @AppStorage("appColorScheme") var appColorScheme: AppColorScheme = .system
    @AppStorage("autoTitleDelay") var autoTitleDelay: AutoTitleDelay = .thirtySeconds
    @AppStorage("currentModelName") var currentModelName: String?
    @AppStorage("localhostServerEnabled") var localhostServerEnabled = false
    @AppStorage("localhostServerPort") var localhostServerPort = 58_627
    @AppStorage("shouldPlayHaptics") var shouldPlayHaptics = true
    @AppStorage("numberOfVisits") var numberOfVisits = 0
    @AppStorage("numberOfVisitsOfLastRequest") var numberOfVisitsOfLastRequest = 0
    @AppStorage("ragTopK") var ragTopK = 5

    private let defaults: UserDefaults
    private let installedModelsKey = "installedModels"
    private let customHFModelsKey = "customHFModels"

    @Published var installedModels: [String] = [] {
        didSet { persist(installedModels, key: installedModelsKey) }
    }

    @Published var customHFModels: [String] = [] {
        didSet { persist(customHFModels, key: customHFModelsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        installedModels = loadValue([String].self, forKey: installedModelsKey) ?? []
        customHFModels = loadValue([String].self, forKey: customHFModelsKey) ?? []
    }

    var userInterfaceIdiom: LayoutType {
        #if os(macOS)
        .mac
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #else
        .unknown
        #endif
    }

    var availableMemory: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    func addCustomHFModel(_ repoId: String) {
        guard !customHFModels.contains(repoId) else { return }
        customHFModels.append(repoId)
    }

    func incrementNumberOfVisits() {
        numberOfVisits += 1
    }

    func playHaptic() {
        guard shouldPlayHaptics else { return }
        #if os(iOS)
        let impact = UIImpactFeedbackGenerator(style: .soft)
        impact.impactOccurred()
        #endif
    }

    func addInstalledModel(_ model: String) {
        guard !installedModels.contains(model) else { return }
        installedModels.append(model)
    }

    func removeInstalledModel(_ model: String, settings: ModelSettingsStore) {
        installedModels.removeAll { $0 == model }
        customHFModels.removeAll { $0 == model }
        settings.removeAll(for: model)
        if currentModelName == model {
            currentModelName = installedModels.first
        }
        let dir = LunarHubDownloader.downloadBase.appendingPathComponent("models/\(model)")
        try? FileManager.default.removeItem(at: dir)
    }

    func getMoonPhaseIcon() -> String {
        let currentDate = Date()
        let baseDate = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 6))!
        let daysSinceBaseDate = Calendar.current.dateComponents([.day], from: baseDate, to: currentDate).day!
        let moonCycleLength = 29.53
        let daysIntoCycle = Double(daysSinceBaseDate).truncatingRemainder(dividingBy: moonCycleLength)

        switch daysIntoCycle {
        case 0..<1.8457:
            return "moonphase.new.moon"
        case 1.8457..<5.536:
            return "moonphase.waxing.crescent"
        case 5.536..<9.228:
            return "moonphase.first.quarter"
        case 9.228..<12.919:
            return "moonphase.waxing.gibbous"
        case 12.919..<16.610:
            return "moonphase.full.moon"
        case 16.610..<20.302:
            return "moonphase.waning.gibbous"
        case 20.302..<23.993:
            return "moonphase.last.quarter"
        case 23.993..<27.684:
            return "moonphase.waning.crescent"
        default:
            return "moonphase.new.moon"
        }
    }

    private func persist<Value: Encodable>(_ value: Value, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func loadValue<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct ModelGenerationSettings {
    let systemPrompt: String
    let temperature: Float
    let topP: Float
    let topK: Int
    let contextWindow: Int
    let reasoningEnabled: Bool
    let backend: BackendKind
}

@MainActor
final class ModelSettingsStore: ObservableObject {
    private enum Keys {
        static let modelBackends = "modelBackends"
        static let displayNameOverrides = "modelDisplayNameOverrides"
        static let modelTemperature = "modelTemperature"
        static let modelTopK = "modelTopK"
        static let modelTopP = "modelTopP"
        static let modelContextWindow = "modelContextWindow"
        static let modelReasoningEnabled = "modelReasoningEnabled"
        static let modelPrefillStepSize = "modelPrefillStepSize"
        static let modelPromptCacheGB = "modelPromptCacheGB"
        static let modelRAGEnabled = "modelRAGEnabled"
        static let modelSystemPrompts = "modelSystemPrompts"
    }

    private let defaults: UserDefaults

    @Published var modelRAGEnabled: [String: Bool] = [:] {
        didSet { persist(modelRAGEnabled, key: Keys.modelRAGEnabled) }
    }

    @Published var modelPrefillStepSize: [String: Int] = [:] {
        didSet { persist(modelPrefillStepSize, key: Keys.modelPrefillStepSize) }
    }

    @Published var modelPromptCacheGB: [String: Int] = [:] {
        didSet { persist(modelPromptCacheGB, key: Keys.modelPromptCacheGB) }
    }

    @Published var modelReasoningEnabled: [String: Bool] = [:] {
        didSet { persist(modelReasoningEnabled, key: Keys.modelReasoningEnabled) }
    }

    @Published var modelContextWindow: [String: Int] = [:] {
        didSet { persist(modelContextWindow, key: Keys.modelContextWindow) }
    }

    @Published var modelSystemPrompts: [String: String] = [:] {
        didSet { persist(modelSystemPrompts, key: Keys.modelSystemPrompts) }
    }

    @Published var displayNameOverrides: [String: String] = [:] {
        didSet { persist(displayNameOverrides, key: Keys.displayNameOverrides) }
    }

    @Published var modelTemperature: [String: Float] = [:] {
        didSet { persist(modelTemperature, key: Keys.modelTemperature) }
    }

    @Published var modelTopK: [String: Int] = [:] {
        didSet { persist(modelTopK, key: Keys.modelTopK) }
    }

    @Published var modelTopP: [String: Float] = [:] {
        didSet { persist(modelTopP, key: Keys.modelTopP) }
    }

    @Published var modelBackends: [String: String] = [:] {
        didSet { persist(modelBackends, key: Keys.modelBackends) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        modelBackends = loadValue([String: String].self, forKey: Keys.modelBackends) ?? [:]
        displayNameOverrides = loadValue([String: String].self, forKey: Keys.displayNameOverrides) ?? [:]
        modelTemperature = loadValue([String: Float].self, forKey: Keys.modelTemperature) ?? [:]
        modelTopK = loadValue([String: Int].self, forKey: Keys.modelTopK) ?? [:]
        modelTopP = loadValue([String: Float].self, forKey: Keys.modelTopP) ?? [:]
        modelContextWindow = loadValue([String: Int].self, forKey: Keys.modelContextWindow) ?? [:]
        modelSystemPrompts = loadValue([String: String].self, forKey: Keys.modelSystemPrompts) ?? [:]
        modelReasoningEnabled = loadValue([String: Bool].self, forKey: Keys.modelReasoningEnabled) ?? [:]
        modelPrefillStepSize = loadValue([String: Int].self, forKey: Keys.modelPrefillStepSize) ?? [:]
        modelPromptCacheGB = loadValue([String: Int].self, forKey: Keys.modelPromptCacheGB) ?? [:]
        modelRAGEnabled = loadValue([String: Bool].self, forKey: Keys.modelRAGEnabled) ?? [:]
    }

    func generationSettings(for modelName: String, defaultSystemPrompt: String) -> ModelGenerationSettings {
        ModelGenerationSettings(
            systemPrompt: systemPrompt(for: modelName, default: defaultSystemPrompt),
            temperature: temperature(for: modelName),
            topP: topP(for: modelName),
            topK: topK(for: modelName),
            contextWindow: contextWindow(for: modelName),
            reasoningEnabled: isReasoningEnabled(for: modelName),
            backend: backend(for: modelName)
        )
    }

    func systemPrompt(for modelName: String, default defaultPrompt: String) -> String {
        if let prompt = modelSystemPrompts[modelName], !prompt.isEmpty {
            return prompt
        }
        return defaultPrompt
    }

    func setSystemPrompt(_ value: String, for modelName: String) {
        if value.isEmpty {
            modelSystemPrompts.removeValue(forKey: modelName)
        } else {
            modelSystemPrompts[modelName] = value
        }
    }

    func temperature(for modelName: String) -> Float { modelTemperature[modelName] ?? 0.5 }
    func topK(for modelName: String) -> Int { modelTopK[modelName] ?? 40 }
    func topP(for modelName: String) -> Float { modelTopP[modelName] ?? 1.0 }
    func contextWindow(for modelName: String) -> Int { modelContextWindow[modelName] ?? 4096 }

    func setTemperature(_ value: Float, for modelName: String) { modelTemperature[modelName] = value }
    func setTopK(_ value: Int, for modelName: String) { modelTopK[modelName] = value }
    func setTopP(_ value: Float, for modelName: String) { modelTopP[modelName] = value }
    func setContextWindow(_ value: Int, for modelName: String) { modelContextWindow[modelName] = value }

    func prefillStepSize(for modelName: String) -> Int { modelPrefillStepSize[modelName] ?? 8192 }
    func promptCacheGB(for modelName: String) -> Int { modelPromptCacheGB[modelName] ?? 8 }
    func setPrefillStepSize(_ value: Int, for modelName: String) { modelPrefillStepSize[modelName] = value }
    func setPromptCacheGB(_ value: Int, for modelName: String) { modelPromptCacheGB[modelName] = value }

    func isRAGEnabled(for modelName: String) -> Bool { modelRAGEnabled[modelName] ?? false }
    func setRAGEnabled(_ value: Bool, for modelName: String) { modelRAGEnabled[modelName] = value }

    func isReasoningEnabled(for modelName: String) -> Bool {
        if let override = modelReasoningEnabled[modelName] { return override }
        return SuggestedModelsCatalog.first(matching: modelName)?.isReasoning ?? false
    }

    func setReasoningEnabled(_ value: Bool, for modelName: String) {
        modelReasoningEnabled[modelName] = value
    }

    func setDisplayNameOverride(_ name: String?, for modelName: String) {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            displayNameOverrides[modelName] = name
        } else {
            displayNameOverrides.removeValue(forKey: modelName)
        }
    }

    func displayName(for modelName: String) -> String {
        if let override = displayNameOverrides[modelName], !override.isEmpty {
            return override
        }
        return modelName.replacingOccurrences(of: "mlx-community/", with: "").lowercased()
    }

    func huggingFaceURL(for modelName: String) -> URL? {
        URL(string: "https://huggingface.co/\(modelName)")
    }

    func modelSizeGB(for modelName: String) -> Double? {
        let dir = LunarHubDownloader.downloadBase.appendingPathComponent("models/\(modelName)")
        if let bytes = directorySize(dir), bytes > 0 {
            return Double(bytes) / 1_073_741_824.0
        }
        return SuggestedModelsCatalog.first(matching: modelName)?.sizeGB
    }

    func backend(for modelName: String) -> BackendKind {
        if let raw = modelBackends[modelName], let kind = BackendKind(rawValue: raw) {
            return kind
        }
        return .mlxSwift
    }

    func setBackend(_ kind: BackendKind, for modelName: String) {
        modelBackends[modelName] = kind.rawValue
    }

    func removeAll(for modelName: String) {
        modelBackends.removeValue(forKey: modelName)
        displayNameOverrides.removeValue(forKey: modelName)
        modelTemperature.removeValue(forKey: modelName)
        modelTopK.removeValue(forKey: modelName)
        modelTopP.removeValue(forKey: modelName)
        modelContextWindow.removeValue(forKey: modelName)
        modelReasoningEnabled.removeValue(forKey: modelName)
        modelPrefillStepSize.removeValue(forKey: modelName)
        modelPromptCacheGB.removeValue(forKey: modelName)
        modelRAGEnabled.removeValue(forKey: modelName)
        modelSystemPrompts.removeValue(forKey: modelName)
    }

    private func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func persist<Value: Encodable>(_ value: Value, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func loadValue<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum Role: String, Codable {
    case assistant
    case user
    case system
}

@Model
class Message {
    @Attribute(.unique) var id: UUID
    var role: Role
    var content: String
    var timestamp: Date
    var generatingTime: TimeInterval?
    var tokensPerSecond: Double?
    var tokenCount: Int?
    var timeToFirstToken: TimeInterval?

    @Relationship(inverse: \Thread.messages) var thread: Thread?

    init(role: Role, content: String, thread: Thread? = nil, generatingTime: TimeInterval? = nil, tokensPerSecond: Double? = nil, tokenCount: Int? = nil, timeToFirstToken: TimeInterval? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.thread = thread
        self.generatingTime = generatingTime
        self.tokensPerSecond = tokensPerSecond
        self.tokenCount = tokenCount
        self.timeToFirstToken = timeToFirstToken
    }
}

@Model
final class Thread {
    @Attribute(.unique) var id: UUID
    var title: String?
    var modelName: String?
    var timestamp: Date
    var ragEnabled: Bool?

    @Relationship var messages: [Message] = []

    var sortedMessages: [Message] {
        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    init(modelName: String? = nil) {
        self.id = UUID()
        self.modelName = modelName
        self.timestamp = Date()
        self.ragEnabled = nil
    }
}

enum AutoTitleDelay: String, CaseIterable, Identifiable {
    case off, thirtySeconds, twoMinutes, fiveMinutes, tenMinutes
    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self {
        case .off:           return nil
        case .thirtySeconds: return 30
        case .twoMinutes:    return 120
        case .fiveMinutes:   return 300
        case .tenMinutes:    return 600
        }
    }
    var label: String {
        switch self {
        case .off:           return "off"
        case .thirtySeconds: return "30 seconds"
        case .twoMinutes:    return "2 minutes"
        case .fiveMinutes:   return "5 minutes"
        case .tenMinutes:    return "10 minutes"
        }
    }
}

enum AppColorScheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppTintColor: String, CaseIterable {
    case monochrome, blue, brown, gray, green, indigo, mint, orange, pink, purple, red, teal, yellow
    
    func getColor() -> Color {
        switch self {
        case .monochrome:
            .appAccent
        case .blue:
            .blue
        case .red:
            .red
        case .green:
            .green
        case .yellow:
            .yellow
        case .brown:
            .brown
        case .gray:
            .gray
        case .indigo:
            .indigo
        case .mint:
            .mint
        case .orange:
            .orange
        case .pink:
            .pink
        case .purple:
            .purple
        case .teal:
            .teal
        }
    }
}

enum AppFontDesign: String, CaseIterable {
    case standard, monospaced, rounded, serif
    
    func getFontDesign() -> Font.Design {
        switch self {
        case .standard:
            .default
        case .monospaced:
            .monospaced
        case .rounded:
            .rounded
        case .serif:
            .serif
        }
    }
}

enum AppFontWidth: String, CaseIterable {
    case compressed, condensed, expanded, standard
    
    func getFontWidth() -> Font.Width {
        switch self {
        case .compressed:
            .compressed
        case .condensed:
            .condensed
        case .expanded:
            .expanded
        case .standard:
            .standard
        }
    }
}

enum AppFontSize: String, CaseIterable {
    case xsmall, small, medium, large, xlarge
    
    func getFontSize() -> DynamicTypeSize {
        switch self {
        case .xsmall:
            .xSmall
        case .small:
            .small
        case .medium:
            .medium
        case .large:
            .large
        case .xlarge:
            .xLarge
        }
    }
}
