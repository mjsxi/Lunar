//
//  Data.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/5/24.
//

import SwiftUI
import SwiftData

class AppManager: ObservableObject {
    @AppStorage("systemPrompt") var systemPrompt = "you are a helpful assistant"
    @AppStorage("appTintColor") var appTintColor: AppTintColor = .monochrome
    @AppStorage("appFontDesign") var appFontDesign: AppFontDesign = .standard
    @AppStorage("appFontSize") var appFontSize: AppFontSize = .medium
    @AppStorage("appFontWidth") var appFontWidth: AppFontWidth = .standard
    @AppStorage("appColorScheme") var appColorScheme: AppColorScheme = .system
    @AppStorage("autoTitleDelay") var autoTitleDelay: AutoTitleDelay = .thirtySeconds
    @AppStorage("currentModelName") var currentModelName: String?
    @AppStorage("shouldPlayHaptics") var shouldPlayHaptics = true
    @AppStorage("numberOfVisits") var numberOfVisits = 0
    @AppStorage("numberOfVisitsOfLastRequest") var numberOfVisitsOfLastRequest = 0
    
    var userInterfaceIdiom: LayoutType {
        #if os(macOS)
        return .mac
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #else
        return .unknown
        #endif
    }
    
    var availableMemory: Double {
        let ramInBytes = ProcessInfo.processInfo.physicalMemory
        let ramInGB = Double(ramInBytes) / (1024 * 1024 * 1024)
        return ramInGB
    }

    enum LayoutType {
        case mac, phone, pad, unknown
    }
        
    private let installedModelsKey = "installedModels"
    private let customHFModelsKey = "customHFModels"
    private let modelBackendsKey = "modelBackends"
    private let displayNameOverridesKey = "modelDisplayNameOverrides"
    private let modelTemperatureKey = "modelTemperature"
    private let modelTopKKey = "modelTopK"
    private let modelTopPKey = "modelTopP"
    private let modelContextWindowKey = "modelContextWindow"
    private let modelReasoningEnabledKey = "modelReasoningEnabled"
    private let modelPrefillStepSizeKey = "modelPrefillStepSize"
    private let modelPromptCacheGBKey = "modelPromptCacheGB"

    @Published var modelPrefillStepSize: [String: Int] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(modelPrefillStepSize) {
                UserDefaults.standard.set(data, forKey: modelPrefillStepSizeKey)
            }
        }
    }

    @Published var modelPromptCacheGB: [String: Int] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(modelPromptCacheGB) {
                UserDefaults.standard.set(data, forKey: modelPromptCacheGBKey)
            }
        }
    }

    @Published var modelReasoningEnabled: [String: Bool] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(modelReasoningEnabled) {
                UserDefaults.standard.set(data, forKey: modelReasoningEnabledKey)
            }
        }
    }

    @Published var modelContextWindow: [String: Int] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(modelContextWindow) {
                UserDefaults.standard.set(data, forKey: modelContextWindowKey)
            }
        }
    }
    private let modelSystemPromptsKey = "modelSystemPrompts"

    @Published var modelSystemPrompts: [String: String] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(modelSystemPrompts) {
                UserDefaults.standard.set(data, forKey: modelSystemPromptsKey)
            }
        }
    }

    @Published var displayNameOverrides: [String: String] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(displayNameOverrides) {
                UserDefaults.standard.set(data, forKey: displayNameOverridesKey)
            }
        }
    }

    @Published var modelTemperature: [String: Float] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(modelTemperature) {
                UserDefaults.standard.set(data, forKey: modelTemperatureKey)
            }
        }
    }

    @Published var modelTopK: [String: Int] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(modelTopK) {
                UserDefaults.standard.set(data, forKey: modelTopKKey)
            }
        }
    }

    @Published var modelTopP: [String: Float] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(modelTopP) {
                UserDefaults.standard.set(data, forKey: modelTopPKey)
            }
        }
    }

    @Published var installedModels: [String] = [] {
        didSet { saveInstalledModelsToUserDefaults() }
    }

    /// HuggingFace repo IDs the user has added beyond the curated set.
    @Published var customHFModels: [String] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(customHFModels) {
                UserDefaults.standard.set(data, forKey: customHFModelsKey)
            }
        }
    }

    /// Per-model backend selection. Key = model name (HF repo id).
    @Published var modelBackends: [String: String] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(modelBackends) {
                UserDefaults.standard.set(data, forKey: modelBackendsKey)
            }
        }
    }

    init() {
        loadInstalledModelsFromUserDefaults()
        if let data = UserDefaults.standard.data(forKey: customHFModelsKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            customHFModels = decoded
        }
        if let data = UserDefaults.standard.data(forKey: modelBackendsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            modelBackends = decoded
        }
        if let data = UserDefaults.standard.data(forKey: displayNameOverridesKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            displayNameOverrides = decoded
        }
        if let data = UserDefaults.standard.data(forKey: modelTemperatureKey),
           let decoded = try? JSONDecoder().decode([String: Float].self, from: data) {
            modelTemperature = decoded
        }
        if let data = UserDefaults.standard.data(forKey: modelTopKKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            modelTopK = decoded
        }
        if let data = UserDefaults.standard.data(forKey: modelTopPKey),
           let decoded = try? JSONDecoder().decode([String: Float].self, from: data) {
            modelTopP = decoded
        }
        if let data = UserDefaults.standard.data(forKey: modelContextWindowKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            modelContextWindow = decoded
        }
        if let data = UserDefaults.standard.data(forKey: modelSystemPromptsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            modelSystemPrompts = decoded
        }
        if let data = UserDefaults.standard.data(forKey: modelReasoningEnabledKey),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            modelReasoningEnabled = decoded
        }
        if let data = UserDefaults.standard.data(forKey: modelPrefillStepSizeKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            modelPrefillStepSize = decoded
        }
        if let data = UserDefaults.standard.data(forKey: modelPromptCacheGBKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            modelPromptCacheGB = decoded
        }
    }

    func systemPrompt(for modelName: String) -> String {
        if let p = modelSystemPrompts[modelName], !p.isEmpty { return p }
        return systemPrompt
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

    /// Whether reasoning (think tags) is enabled for a model.
    /// For suggested models, defaults to the catalog's `isReasoning` flag.
    /// For custom HuggingFace models, defaults to `false`.
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

    func huggingFaceURL(for modelName: String) -> URL? {
        URL(string: "https://huggingface.co/\(modelName)")
    }

    /// Returns the on-disk size of a downloaded model in GB, or the catalog size as fallback.
    func modelSizeGB(for modelName: String) -> Double? {
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let dir = docs.appendingPathComponent("huggingface/models/\(modelName)")
            if let bytes = directorySize(dir), bytes > 0 {
                return Double(bytes) / 1_073_741_824.0
            }
        }
        return SuggestedModelsCatalog.first(matching: modelName)?.sizeGB
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

    func backend(for modelName: String) -> BackendKind {
        if let raw = modelBackends[modelName], let kind = BackendKind(rawValue: raw) {
            return kind
        }
        return .mlxSwift
    }

    func setBackend(_ kind: BackendKind, for modelName: String) {
        modelBackends[modelName] = kind.rawValue
    }

    func addCustomHFModel(_ repoId: String) {
        if !customHFModels.contains(repoId) {
            customHFModels.append(repoId)
        }
    }
    
    func incrementNumberOfVisits() {
        numberOfVisits += 1
        print("app visits: \(numberOfVisits)")
    }
    
    // Function to save the array to UserDefaults as JSON
    private func saveInstalledModelsToUserDefaults() {
        if let jsonData = try? JSONEncoder().encode(installedModels) {
            UserDefaults.standard.set(jsonData, forKey: installedModelsKey)
        }
    }
    
    // Function to load the array from UserDefaults
    private func loadInstalledModelsFromUserDefaults() {
        if let jsonData = UserDefaults.standard.data(forKey: installedModelsKey),
           let decodedArray = try? JSONDecoder().decode([String].self, from: jsonData) {
            self.installedModels = decodedArray
        } else {
            self.installedModels = [] // Default to an empty array if there's no data
        }
    }
    
    func playHaptic() {
        if shouldPlayHaptics {
            #if os(iOS)
            let impact = UIImpactFeedbackGenerator(style: .soft)
            impact.impactOccurred()
            #endif
        }
    }
    
    func addInstalledModel(_ model: String) {
        if !installedModels.contains(model) {
            installedModels.append(model)
        }
    }

    func removeInstalledModel(_ model: String) {
        installedModels.removeAll { $0 == model }
        customHFModels.removeAll { $0 == model }
        modelBackends.removeValue(forKey: model)
        modelReasoningEnabled.removeValue(forKey: model)
        if currentModelName == model {
            currentModelName = installedModels.first
        }
        // Best-effort: delete the HuggingFace snapshot cache directory.
        // swift-transformers' HubApi stores under ~/Documents/huggingface/models/<repo>.
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let dir = docs.appendingPathComponent("huggingface/models/\(model)")
            try? FileManager.default.removeItem(at: dir)
        }
    }
    
    func modelDisplayName(_ modelName: String) -> String {
        if let override = displayNameOverrides[modelName], !override.isEmpty {
            return override
        }
        return modelName.replacingOccurrences(of: "mlx-community/", with: "").lowercased()
    }
    
    func getMoonPhaseIcon() -> String {
        // Get current date
        let currentDate = Date()
        
        // Define a base date (known new moon date)
        let baseDate = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 6))!
        
        // Difference in days between the current date and the base date
        let daysSinceBaseDate = Calendar.current.dateComponents([.day], from: baseDate, to: currentDate).day!
        
        // Moon phase repeats approximately every 29.53 days
        let moonCycleLength = 29.53
        let daysIntoCycle = Double(daysSinceBaseDate).truncatingRemainder(dividingBy: moonCycleLength)
        
        // Determine the phase based on how far into the cycle we are
        switch daysIntoCycle {
        case 0..<1.8457:
            return "moonphase.new.moon" // New Moon
        case 1.8457..<5.536:
            return "moonphase.waxing.crescent" // Waxing Crescent
        case 5.536..<9.228:
            return "moonphase.first.quarter" // First Quarter
        case 9.228..<12.919:
            return "moonphase.waxing.gibbous" // Waxing Gibbous
        case 12.919..<16.610:
            return "moonphase.full.moon" // Full Moon
        case 16.610..<20.302:
            return "moonphase.waning.gibbous" // Waning Gibbous
        case 20.302..<23.993:
            return "moonphase.last.quarter" // Last Quarter
        case 23.993..<27.684:
            return "moonphase.waning.crescent" // Waning Crescent
        default:
            return "moonphase.new.moon" // New Moon (fallback)
        }
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

    @Relationship var messages: [Message] = []

    var sortedMessages: [Message] {
        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    init(modelName: String? = nil) {
        self.id = UUID()
        self.modelName = modelName
        self.timestamp = Date()
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
