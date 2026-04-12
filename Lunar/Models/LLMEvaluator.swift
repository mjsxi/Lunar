//
//  LLMEvaluator.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom
import SwiftUI

enum LLMEvaluatorError: Error {
    case modelNotFound(String)
}

enum StreamedAssistantPhase: Sendable {
    case nonReasoning
    case thinkingInProgress
    case thinkingComplete
}

@Observable
@MainActor
class LLMEvaluator {
    @ObservationIgnored private var modelSettingsStore: ModelSettingsStore?

    var running = false
    var cancelled = false
    var output = ""
    var modelInfo = ""
    var stat = ""
    var progress = 0.0
    var thinkingTime: TimeInterval?
    var collapsed: Bool = false
    var isThinking: Bool = false
    var streamedVisibleOutput = ""
    var streamedAssistantPhase: StreamedAssistantPhase = .nonReasoning

    var lastTokensPerSecond: Double = 0
    var lastTokenCount: Int = 0
    var lastTimeToFirstToken: TimeInterval = 0
    var lastLoadDuration: TimeInterval = 0

    var elapsedTime: TimeInterval? {
        if let startTime {
            return Date().timeIntervalSince(startTime)
        }

        return nil
    }

    private var startTime: Date?

    var modelConfiguration = ModelConfiguration.defaultModel

    init(modelSettingsStore: ModelSettingsStore? = nil) {
        self.modelSettingsStore = modelSettingsStore
    }

    func bind(modelSettingsStore: ModelSettingsStore) {
        self.modelSettingsStore = modelSettingsStore
    }

    func switchModel(_ model: ModelConfiguration) async {
        progress = 0.0 // reset progress
        loadState = .idle
        modelConfiguration = model

        // Release previous model memory before loading the new one
        MLX.Memory.clearCache()

        #if os(macOS)
        if generationSettings(for: model.name, defaultSystemPrompt: "").backend == .pythonMLX {
            await loadPythonBackend(modelName: model.name)
            return
        }
        #endif

        _ = try? await load(modelName: model.name)
    }

    /// String-based overload for callers that don't have access to MLXLMCommon types.
    func switchModel(named modelName: String) async {
        let model = ModelConfiguration.getOrRegister(modelName)
        await switchModel(model)
    }

    let maxTokens = 4096

    private func generateParameters(for modelName: String) -> GenerateParameters {
        let settings = generationSettings(for: modelName, defaultSystemPrompt: "")
        return GenerateParameters(temperature: settings.temperature, topP: settings.topP)
    }

    /// update the display every N tokens -- 4 looks like it updates continuously
    /// and is low overhead.  observed ~15% reduction in tokens/s when updating
    /// on every token
    let displayEveryNTokens = 4
    let reasoningDisplayEveryNTokens = 16
    let displayUpdateInterval: TimeInterval = 0.12

    enum LoadState {
        case idle
        case loading
        case loaded(ModelContainer)
        case loadedPython
        case failed
    }

    var statusColor: Color {
        switch loadState {
        case .idle, .loading: return .yellow
        case .loaded, .loadedPython: return .green
        case .failed: return .red
        }
    }

    var loadState = LoadState.idle

    /// load and return the model -- can be called multiple times, subsequent calls will
    /// just return the loaded model
    func load(modelName: String) async throws -> ModelContainer {
        let model = ModelConfiguration.getOrRegister(modelName)

        switch loadState {
        case .idle, .failed, .loadedPython:
            loadState = .loading
            let loadStart = Date()

            // limit the buffer cache
            MLX.Memory.cacheLimit = 20 * 1024 * 1024

            do {
                let modelContainer = try await LLMModelFactory.shared.loadContainer(
                    from: LunarHubDownloader(),
                    using: LunarTokenizerLoader(),
                    configuration: model,
                    progressHandler: { [modelConfiguration] progress in
                        Task { @MainActor in
                            self.modelInfo =
                                "Downloading \(modelConfiguration.name): \(Int(progress.fractionCompleted * 100))%"
                            self.progress = progress.fractionCompleted
                        }
                    }
                )
                modelInfo =
                    "Loaded \(modelConfiguration.id).  Weights: \(MLX.Memory.activeMemory / 1024 / 1024)M"
                loadState = .loaded(modelContainer)
                lastLoadDuration = Date().timeIntervalSince(loadStart)
                return modelContainer
            } catch {
                loadState = .failed
                lastLoadDuration = Date().timeIntervalSince(loadStart)
                throw error
            }

        case .loading:
            // Already loading — wait for it to finish
            let waitStart = Date()
            for _ in 0..<300 { // up to ~30s
                try await Task.sleep(nanoseconds: 100_000_000)
                if case let .loaded(modelContainer) = loadState {
                    lastLoadDuration = Date().timeIntervalSince(waitStart)
                    return modelContainer
                }
                if case .failed = loadState {
                    // Previous load failed; reset and try again
                    return try await load(modelName: modelName)
                }
                if case .idle = loadState {
                    return try await load(modelName: modelName)
                }
            }
            // Timed out waiting — reset and try fresh
            loadState = .idle
            return try await load(modelName: modelName)

        case let .loaded(modelContainer):
            lastLoadDuration = 0
            return modelContainer
        }
    }

    func stop() {
        isThinking = false
        cancelled = true
    }

    func generate(modelName: String, snapshot: ThreadSnapshot, systemPrompt: String, knowledgeBase: KnowledgeBaseIndex? = nil) async -> String {
        guard !running else { return "" }

        running = true
        cancelled = false
        output = ""
        streamedVisibleOutput = ""
        startTime = Date()
        let settings = generationSettings(for: modelName, defaultSystemPrompt: systemPrompt)
        thinkingTime = nil
        isThinking = false
        streamedAssistantPhase = settings.reasoningEnabled ? .thinkingInProgress : .nonReasoning
        lastTokensPerSecond = 0
        lastTokenCount = 0
        lastTimeToFirstToken = 0
        lastLoadDuration = 0
        let requestStart = startTime ?? Date()

        var ragResults: [DocumentChunk] = []
        let ragStart = Date()
        if let kb = knowledgeBase, kb.hasIndex {
            let lastUserMessage = snapshot.messages.last(where: { $0.role == "user" })?.content ?? ""
            if !lastUserMessage.isEmpty {
                let ragTopK = UserDefaults.standard.integer(forKey: "ragTopK")
                let topK = ragTopK > 0 ? ragTopK : 5
                ragResults = kb.query(lastUserMessage, topK: topK)
            }
        }
        let preparedPrompt = await PromptPreparer.shared.prepare(
            snapshot: snapshot,
            systemPrompt: systemPrompt,
            reasoningEnabled: settings.reasoningEnabled,
            contextWindow: settings.contextWindow,
            ragResults: ragResults,
            ragQueryDuration: Date().timeIntervalSince(ragStart)
        )

        // Per-model backend routing. On macOS the user can pick MLX LM (Python)
        // for any installed model in Settings → Models → <model>.
        #if os(macOS)
        if settings.backend == .pythonMLX {
            await runPythonBackend(
                modelName: modelName,
                preparedPrompt: preparedPrompt,
                settings: settings,
                requestStart: requestStart
            )
            running = false
            return output
        }
        #endif

        do {
            let modelContainer = try await load(modelName: modelName)
            let reasoningEnabled = settings.reasoningEnabled
            let promptHistory = preparedPrompt.messages.map {
                ["role": $0.role, "content": $0.content]
            }

            if reasoningEnabled {
                isThinking = true
            }

            // each time you generate you will get something new
            MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))

            let parameters = generateParameters(for: modelName)
            let stream: AsyncStream<Generation> = try await modelContainer.perform { context in
                let input = try await context.processor.prepare(input: .init(messages: promptHistory))
                return try MLXLMCommon.generate(
                    input: input, parameters: parameters, context: context
                )
            }

            // Stop sequences a few popular models leak as plain text when
            // their tokenizer config doesn't pin them as EOS (e.g. Gemma's
            // <end_of_turn>, ChatML's <|im_end|>, Llama 3's <|eot_id|>).
            let stopSequences = ["<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<|end|>"]

            let renderer = StreamingResponseRenderer(
                reasoningEnabled: reasoningEnabled,
                normalBatchSize: displayEveryNTokens,
                reasoningBatchSize: reasoningDisplayEveryNTokens,
                publishInterval: displayUpdateInterval
            )
            var tps: Double = 0
            var firstTokenTime: Date?
            var firstVisibleTime: Date?
            streamLoop: for await event in stream {
                if cancelled { break }
                switch event {
                case .chunk(let text):
                    if firstTokenTime == nil { firstTokenTime = Date() }
                    let update = await renderer.append(delta: text, at: Date())
                    let accumulated = update.fullOutput
                    if let stop = stopSequences.first(where: { accumulated.contains($0) }) {
                        if let r = accumulated.range(of: stop) {
                            let trimmed = String(accumulated[..<r.lowerBound])
                            let trimmedUpdate = await renderer.replace(fullOutput: trimmed, at: Date(), forcePublish: true)
                            applyStreamingUpdate(trimmedUpdate)
                        }
                        break streamLoop
                    }
                    if update.shouldPublish {
                        applyStreamingUpdate(update)
                        if firstVisibleTime == nil {
                            firstVisibleTime = Date()
                        }
                    }
                    if update.tokenCount >= maxTokens { break }
                case .info(let info):
                    tps = info.tokensPerSecond
                case .toolCall:
                    break
                }
            }
            let finalUpdate = await renderer.finish(at: Date())
            applyStreamingUpdate(finalUpdate)
            if firstVisibleTime == nil, !finalUpdate.visibleOutput.isEmpty {
                firstVisibleTime = Date()
            }
            output = finalUpdate.fullOutput
            streamedVisibleOutput = finalUpdate.visibleOutput
            streamedAssistantPhase = finalUpdate.phase
            lastTokensPerSecond = tps
            lastTokenCount = finalUpdate.tokenCount
            if let start = startTime, let firstToken = firstTokenTime {
                lastTimeToFirstToken = firstToken.timeIntervalSince(start)
            }
            stat = " Tokens/second: \(String(format: "%.3f", tps))"
            logTiming(
                modelName: modelName,
                backend: settings.backend,
                preparedPrompt: preparedPrompt,
                requestStart: requestStart,
                firstTokenTime: firstTokenTime,
                firstVisibleTime: firstVisibleTime,
                backendLoadTime: lastLoadDuration,
                coldStart: lastLoadDuration > 0
            )

        } catch {
            AppLogger.inference.error("generation failed for \(modelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            output = "Failed: \(error)"
        }

        running = false
        return output
    }

    /// Off-screen, single-shot generation. Does not touch `output`, `running`,
    /// `isThinking`, `stat`, or `progress`. Used for background tasks like
    /// auto-titling a chat.
    func generateSilent(
        modelName: String,
        transcript: [(role: String, content: String)],
        systemPrompt: String,
        maxTokens: Int = 32
    ) async -> String? {
        // Wait until any visible generation finishes so we don't fight over
        // the model container on @MainActor.
        while running {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Try MLX Swift in-process first.
        do {
            let modelContainer = try await load(modelName: modelName)
            var history: [[String: String]] = [["role": "system", "content": systemPrompt]]
            for t in transcript {
                history.append(["role": t.role, "content": t.content])
            }
            let promptHistory = history
            MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))
            let parameters = GenerateParameters(temperature: 0.3, topP: 1.0)
            let stream: AsyncStream<Generation> = try await modelContainer.perform { context in
                let input = try await context.processor.prepare(input: .init(messages: promptHistory))
                return try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
            }
            var accumulated = ""
            var tokenCount = 0
            for await event in stream {
                switch event {
                case .chunk(let text):
                    accumulated += text
                    tokenCount += 1
                    if tokenCount >= maxTokens { return accumulated }
                case .info, .toolCall:
                    break
                }
            }
            return accumulated.isEmpty ? nil : accumulated
        } catch {
            // MLX Swift failed (model may not be supported) — try Python fallback.
            #if os(macOS)
            return await generateSilentViaPython(modelName: modelName, transcript: transcript, systemPrompt: systemPrompt, maxTokens: maxTokens)
            #else
            return nil
            #endif
        }
    }

    #if os(macOS)
    /// Python fallback for generateSilent. Makes a direct non-streaming HTTP
    /// call to the already-running mlx_lm.server. If the server is dead,
    /// returns nil immediately (no restart attempt, no 120 s timeout).
    private func generateSilentViaPython(
        modelName: String,
        transcript: [(role: String, content: String)],
        systemPrompt: String,
        maxTokens: Int
    ) async -> String? {
        let backend = BackendRouter.shared.backend(for: .pythonMLX) as? PythonMLXBackend
        guard let port = backend?.serverPort,
              backend?.serverProcess?.isRunning == true else { return nil }

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        for t in transcript { messages.append(["role": t.role, "content": t.content]) }

        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": maxTokens,
            "stream": false
        ]

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        } catch {
            AppLogger.pythonBackend.error("silent python generation failed for \(modelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }
    #endif

    private func generationSettings(for modelName: String, defaultSystemPrompt: String) -> ModelGenerationSettings {
        modelSettingsStore?.generationSettings(for: modelName, defaultSystemPrompt: defaultSystemPrompt)
            ?? ModelGenerationSettings(
                systemPrompt: defaultSystemPrompt,
                temperature: 0.5,
                topP: 1.0,
                topK: 40,
                contextWindow: 4096,
                reasoningEnabled: SuggestedModelsCatalog.first(matching: modelName)?.isReasoning ?? false,
                backend: .mlxSwift
            )
    }

    #if os(macOS)
    /// Pre-loads the Python MLX server so the status indicator turns green
    /// before the user sends a message.
    private func loadPythonBackend(modelName: String) async {
        loadState = .loading
        let backend = BackendRouter.shared.backend(for: .pythonMLX)
        do {
            try await backend.load(modelName: modelName) { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }
            loadState = .loadedPython
            modelInfo = "Loaded \(modelName) (Python)"
        } catch {
            loadState = .failed
            modelInfo = "Failed: \(error.localizedDescription)"
        }
    }

    /// Kills the Python server and restarts it for the current model.
    func restartPythonBackend() async {
        let backend = BackendRouter.shared.backend(for: .pythonMLX) as? PythonMLXBackend
        await backend?.stopServer()
        await loadPythonBackend(modelName: modelConfiguration.name)
    }

    private func runPythonBackend(
        modelName: String,
        preparedPrompt: PreparedPrompt,
        settings: ModelGenerationSettings,
        requestStart: Date
    ) async {
        if case .loadedPython = loadState {
            // Already pre-loaded; keep green indicator
        } else {
            loadState = .loading
        }
        let backend = BackendRouter.shared.backend(for: .pythonMLX)
        let coldStart = (backend as? PythonMLXBackend).map {
            $0.loadedModelName != modelName || $0.serverProcess?.isRunning != true
        } ?? false
        let renderer = StreamingResponseRenderer(
            reasoningEnabled: settings.reasoningEnabled,
            normalBatchSize: displayEveryNTokens,
            reasoningBatchSize: reasoningDisplayEveryNTokens,
            publishInterval: displayUpdateInterval
        )
        var firstTokenTime: Date?
        var firstVisibleTime: Date?
        do {
            let stream = backend.generate(
                modelName: modelName,
                messages: preparedPrompt.messages,
                params: GenerateParams(
                    temperature: settings.temperature,
                    topP: settings.topP,
                    topK: settings.topK,
                    maxTokens: maxTokens
                )
            )
            for try await chunk in stream {
                if cancelled { backend.cancel(); break }
                let update = await renderer.replace(fullOutput: chunk, at: Date())
                if firstTokenTime == nil {
                    firstTokenTime = Date()
                    loadState = .loadedPython
                }
                if update.shouldPublish {
                    applyStreamingUpdate(update)
                }
                if firstVisibleTime == nil, !update.visibleOutput.isEmpty {
                    firstVisibleTime = Date()
                }
            }
            if case .loading = loadState { loadState = .loadedPython }
        } catch {
            self.output = "Failed: \(error.localizedDescription)"
            loadState = .failed
        }
        let finalUpdate = await renderer.finish(at: Date())
        applyStreamingUpdate(finalUpdate)
        let elapsed = Date().timeIntervalSince(requestStart)
        if firstVisibleTime == nil, !finalUpdate.visibleOutput.isEmpty {
            firstVisibleTime = Date()
        }
        lastTokenCount = finalUpdate.tokenCount
        lastTokensPerSecond = elapsed > 0 ? Double(finalUpdate.tokenCount) / elapsed : 0
        lastTimeToFirstToken = firstTokenTime?.timeIntervalSince(requestStart) ?? 0
        logTiming(
            modelName: modelName,
            backend: settings.backend,
            preparedPrompt: preparedPrompt,
            requestStart: requestStart,
            firstTokenTime: firstTokenTime,
            firstVisibleTime: firstVisibleTime,
            backendLoadTime: (backend as? PythonMLXBackend)?.lastLoadDuration ?? 0,
            coldStart: coldStart
        )
    }

    private func applyStreamingUpdate(_ update: StreamingRenderUpdate) {
        output = update.fullOutput
        streamedVisibleOutput = update.visibleOutput
        streamedAssistantPhase = update.phase
        isThinking = update.phase == .thinkingInProgress
    }

    #endif

    private func logTiming(
        modelName: String,
        backend: BackendKind,
        preparedPrompt: PreparedPrompt,
        requestStart: Date,
        firstTokenTime: Date?,
        firstVisibleTime: Date?,
        backendLoadTime: TimeInterval,
        coldStart: Bool
    ) {
        let ttft = firstTokenTime?.timeIntervalSince(requestStart) ?? 0
        let firstVisible = firstVisibleTime?.timeIntervalSince(requestStart) ?? 0
        let message = "timing model=\(modelName) backend=\(backend.rawValue) prompt=\(formatDuration(preparedPrompt.timing.total))s rag=\(formatDuration(preparedPrompt.timing.ragQuery))s load=\(formatDuration(backendLoadTime))s ttft=\(formatDuration(ttft))s firstVisible=\(formatDuration(firstVisible))s estPromptTokens=\(preparedPrompt.estimatedPromptTokens) droppedTurns=\(preparedPrompt.droppedMessageCount) ragChunks=\(preparedPrompt.includedRAGChunks) coldStart=\(coldStart)"
        AppLogger.inference.info("\(message, privacy: .public)")
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }
}

private struct StreamingRenderUpdate: Sendable {
    let fullOutput: String
    let visibleOutput: String
    let phase: StreamedAssistantPhase
    let tokenCount: Int
    let shouldPublish: Bool
}

private actor StreamingResponseRenderer {
    private let reasoningEnabled: Bool
    private let normalBatchSize: Int
    private let reasoningBatchSize: Int
    private let publishInterval: TimeInterval

    private var fullOutput = ""
    private var visibleOutput = ""
    private var phase: StreamedAssistantPhase
    private var tokenCount = 0
    private var tokensSincePublish = 0
    private var lastPublishAt: Date?
    private var didInjectThinkTag = false

    init(
        reasoningEnabled: Bool,
        normalBatchSize: Int,
        reasoningBatchSize: Int,
        publishInterval: TimeInterval
    ) {
        self.reasoningEnabled = reasoningEnabled
        self.normalBatchSize = normalBatchSize
        self.reasoningBatchSize = reasoningBatchSize
        self.publishInterval = publishInterval
        self.phase = reasoningEnabled ? .thinkingInProgress : .nonReasoning
    }

    func append(delta: String, at timestamp: Date) -> StreamingRenderUpdate {
        fullOutput += delta
        tokenCount += 1
        tokensSincePublish += 1
        normalizeReasoningPrefixIfNeeded()
        refreshPhase()
        return makeUpdate(at: timestamp, forcePublish: tokenCount == 1)
    }

    func replace(fullOutput newValue: String, at timestamp: Date, forcePublish: Bool = false) -> StreamingRenderUpdate {
        if newValue.hasPrefix(fullOutput) {
            let suffix = String(newValue.dropFirst(fullOutput.count))
            if !suffix.isEmpty {
                return append(delta: suffix, at: timestamp)
            }
        }

        fullOutput = newValue
        tokenCount += 1
        tokensSincePublish += 1
        normalizeReasoningPrefixIfNeeded()
        refreshPhase()
        return makeUpdate(at: timestamp, forcePublish: forcePublish || tokenCount == 1)
    }

    func finish(at timestamp: Date) -> StreamingRenderUpdate {
        refreshPhase()
        visibleOutput = fullOutput
        lastPublishAt = timestamp
        tokensSincePublish = 0
        return StreamingRenderUpdate(
            fullOutput: fullOutput,
            visibleOutput: visibleOutput,
            phase: phase == .thinkingInProgress ? .thinkingComplete : phase,
            tokenCount: tokenCount,
            shouldPublish: true
        )
    }

    private func normalizeReasoningPrefixIfNeeded() {
        guard reasoningEnabled, !didInjectThinkTag, !fullOutput.isEmpty else { return }
        if !fullOutput.hasPrefix("<think>") {
            fullOutput = "<think>\n" + fullOutput
            didInjectThinkTag = true
        }
    }

    private func refreshPhase() {
        guard reasoningEnabled else {
            phase = .nonReasoning
            visibleOutput = fullOutput
            return
        }

        if fullOutput.contains("</think>") {
            phase = .thinkingComplete
            visibleOutput = fullOutput
        } else {
            phase = .thinkingInProgress
            visibleOutput = ""
        }
    }

    private func makeUpdate(at timestamp: Date, forcePublish: Bool) -> StreamingRenderUpdate {
        let batchSize = phase == .thinkingInProgress ? reasoningBatchSize : normalBatchSize
        let intervalReached: Bool
        if let lastPublishAt {
            intervalReached = timestamp.timeIntervalSince(lastPublishAt) >= publishInterval
        } else {
            intervalReached = true
        }
        let shouldPublish = forcePublish || tokensSincePublish >= batchSize || intervalReached
        if shouldPublish {
            lastPublishAt = timestamp
            tokensSincePublish = 0
        }
        return StreamingRenderUpdate(
            fullOutput: fullOutput,
            visibleOutput: visibleOutput,
            phase: phase,
            tokenCount: tokenCount,
            shouldPublish: shouldPublish
        )
    }
}
