//
//  MLXSwiftBackend.swift
//  Lunar
//
//  Wraps the existing LLMEvaluator (which already drives mlx-swift) behind
//  the InferenceBackend protocol. Most code paths in the app still talk to
//  LLMEvaluator directly; this wrapper exists so that code which wants the
//  abstract API (e.g. future refactors) has a single place to plug in.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom

@MainActor
final class MLXSwiftBackend: @preconcurrency InferenceBackend {
    private var loadedContainer: ModelContainer?
    private var loadedName: String?
    private var cancelled = false

    func unload() {
        loadedContainer = nil
        loadedName = nil
        MLX.Memory.clearCache()
    }

    func load(modelName: String, progress: @escaping (Double) -> Void) async throws {
        if loadedName == modelName, loadedContainer != nil { return }
        // Release the previous model before loading a new one
        unload()
        let config = ModelConfiguration.getOrRegister(modelName)
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        let container = try await LLMModelFactory.shared.loadContainer(
            from: LunarHubDownloader(),
            using: LunarTokenizerLoader(),
            configuration: config,
            progressHandler: { p in
                Task { @MainActor in progress(p.fractionCompleted) }
            }
        )
        loadedContainer = container
        loadedName = modelName
    }

    func generate(modelName: String,
                  messages: [ChatTurn],
                  params: GenerateParams) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    try await self.load(modelName: modelName) { _ in }
                    guard let container = self.loadedContainer else {
                        continuation.finish(throwing: LLMEvaluatorError.modelNotFound(modelName))
                        return
                    }
                    self.cancelled = false
                    let history = messages.map { ["role": $0.role, "content": $0.content] }
                    MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))
                    let parameters = GenerateParameters(temperature: params.temperature, topP: params.topP)

                    var accumulated = ""
                    let stream: AsyncStream<Generation> = try await container.perform { context in
                        let input = try await context.processor.prepare(input: .init(messages: history))
                        return try MLXLMCommon.generate(
                            input: input, parameters: parameters, context: context
                        )
                    }
                    var tokenCount = 0
                    for await event in stream {
                        if self.cancelled { break }
                        switch event {
                        case .chunk(let text):
                            accumulated += text
                            continuation.yield(accumulated)
                            tokenCount += 1
                            if tokenCount >= params.maxTokens { break }
                        case .info, .toolCall:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func cancel() {
        Task { @MainActor in self.cancelled = true }
    }
}

extension ModelConfiguration {
    /// Look up a model by name; if it's a HF repo we don't know about yet,
    /// register a fresh ModelConfiguration on the fly.
    static func getOrRegister(_ name: String) -> ModelConfiguration {
        if let existing = getModelByName(name) { return existing }
        let cfg = ModelConfiguration(id: name)
        availableModels.append(cfg)
        return cfg
    }
}
