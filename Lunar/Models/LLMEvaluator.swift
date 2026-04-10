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

@Observable
@MainActor
class LLMEvaluator {
    var running = false
    var cancelled = false
    var output = ""
    var modelInfo = ""
    var stat = ""
    var progress = 0.0
    var thinkingTime: TimeInterval?
    var collapsed: Bool = false
    var isThinking: Bool = false

    var lastTokensPerSecond: Double = 0
    var lastTokenCount: Int = 0
    var lastTimeToFirstToken: TimeInterval = 0

    var elapsedTime: TimeInterval? {
        if let startTime {
            return Date().timeIntervalSince(startTime)
        }

        return nil
    }

    private var startTime: Date?

    var modelConfiguration = ModelConfiguration.defaultModel

    func switchModel(_ model: ModelConfiguration) async {
        progress = 0.0 // reset progress
        loadState = .idle
        modelConfiguration = model
        _ = try? await load(modelName: model.name)
    }

    let maxTokens = 4096

    private func generateParameters(for modelName: String) -> GenerateParameters {
        let (temp, topP, _) = perModelParams(modelName)
        return GenerateParameters(temperature: temp, topP: topP)
    }

    private func perModelParams(_ modelName: String) -> (Float, Float, Int) {
        let temp = readFloatDict("modelTemperature")[modelName] ?? 0.5
        let topP = readFloatDict("modelTopP")[modelName] ?? 1.0
        let topK = readIntDict("modelTopK")[modelName] ?? 40
        return (temp, topP, topK)
    }

    private func readFloatDict(_ key: String) -> [String: Float] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: Float].self, from: data) else { return [:] }
        return dict
    }

    private func readIntDict(_ key: String) -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return dict
    }

    /// update the display every N tokens -- 4 looks like it updates continuously
    /// and is low overhead.  observed ~15% reduction in tokens/s when updating
    /// on every token
    let displayEveryNTokens = 4

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
        guard let model = ModelConfiguration.getModelByName(modelName) else {
            throw LLMEvaluatorError.modelNotFound(modelName)
        }

        switch loadState {
        case .idle, .failed, .loadedPython:
            loadState = .loading

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
                return modelContainer
            } catch {
                loadState = .failed
                throw error
            }

        case .loading:
            // Already loading — wait and retry
            throw LLMEvaluatorError.modelNotFound(modelName)

        case let .loaded(modelContainer):
            return modelContainer
        }
    }

    func stop() {
        isThinking = false
        cancelled = true
    }

    func generate(modelName: String, thread: Thread, systemPrompt: String) async -> String {
        guard !running else { return "" }

        running = true
        cancelled = false
        output = ""
        startTime = Date()

        // Per-model backend routing. On macOS the user can pick MLX LM (Python)
        // for any installed model in Settings → Models → <model>.
        #if os(macOS)
        if selectedBackend(for: modelName) == .pythonMLX {
            await runPythonBackend(modelName: modelName, thread: thread, systemPrompt: systemPrompt)
            running = false
            return output
        }
        #endif

        do {
            let modelContainer = try await load(modelName: modelName)

            // augment the prompt as needed
            let reasoningEnabled = readReasoningEnabled(for: modelName)
            let promptHistory = await modelContainer.configuration.getPromptHistory(thread: thread, systemPrompt: systemPrompt, reasoningEnabled: reasoningEnabled)

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

            var accumulated = ""
            var tokenCount = 0
            var tps: Double = 0
            var firstTokenTime: Date?
            streamLoop: for await event in stream {
                if cancelled { break }
                switch event {
                case .chunk(let text):
                    if firstTokenTime == nil { firstTokenTime = Date() }
                    accumulated += text
                    tokenCount += 1
                    if let stop = stopSequences.first(where: { accumulated.contains($0) }) {
                        if let r = accumulated.range(of: stop) {
                            accumulated = String(accumulated[..<r.lowerBound])
                        }
                        break streamLoop
                    }
                    if tokenCount % displayEveryNTokens == 0 {
                        self.output = accumulated
                    }
                    if tokenCount >= maxTokens { break }
                case .info(let info):
                    tps = info.tokensPerSecond
                case .toolCall:
                    break
                }
            }
            output = accumulated
            lastTokensPerSecond = tps
            lastTokenCount = tokenCount
            if let start = startTime, let firstToken = firstTokenTime {
                lastTimeToFirstToken = firstToken.timeIntervalSince(start)
            }
            stat = " Tokens/second: \(String(format: "%.3f", tps))"

        } catch {
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
            print("[generateSilent] Python direct HTTP error: \(error.localizedDescription)")
        }
        return nil
    }
    #endif

    private func readReasoningEnabled(for modelName: String) -> Bool {
        if let data = UserDefaults.standard.data(forKey: "modelReasoningEnabled"),
           let dict = try? JSONDecoder().decode([String: Bool].self, from: data),
           let value = dict[modelName] {
            return value
        }
        return SuggestedModelsCatalog.first(matching: modelName)?.isReasoning ?? false
    }

    private func selectedBackend(for modelName: String) -> BackendKind {
        if let data = UserDefaults.standard.data(forKey: "modelBackends"),
           let dict = try? JSONDecoder().decode([String: String].self, from: data),
           let raw = dict[modelName],
           let kind = BackendKind(rawValue: raw) {
            return kind
        }
        return .mlxSwift
    }

    #if os(macOS)
    private func runPythonBackend(modelName: String, thread: Thread, systemPrompt: String) async {
        loadState = .loading
        let backend = BackendRouter.shared.backend(for: .pythonMLX)
        var turns: [ChatTurn] = [ChatTurn(role: "system", content: systemPrompt)]
        for m in thread.sortedMessages {
            turns.append(ChatTurn(role: m.role.rawValue, content: m.content))
        }
        let streamStart = Date()
        var firstTokenTime: Date?
        var tokenCount = 0
        do {
            let stream = backend.generate(
                modelName: modelName,
                messages: turns,
                params: {
                    let p = perModelParams(modelName)
                    return GenerateParams(temperature: p.0, topP: p.1, topK: p.2, maxTokens: maxTokens)
                }()
            )
            for try await chunk in stream {
                if cancelled { backend.cancel(); break }
                if firstTokenTime == nil {
                    firstTokenTime = Date()
                    loadState = .loadedPython
                }
                tokenCount += 1
                self.output = chunk
            }
            if case .loading = loadState { loadState = .loadedPython }
        } catch {
            self.output = "Failed: \(error.localizedDescription)"
            loadState = .failed
        }
        let elapsed = Date().timeIntervalSince(streamStart)
        lastTokenCount = tokenCount
        lastTokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0
        lastTimeToFirstToken = firstTokenTime?.timeIntervalSince(streamStart) ?? 0
    }
    #endif
}
