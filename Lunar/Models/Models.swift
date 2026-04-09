//
//  Models.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import Foundation
import MLXLMCommon

public extension ModelConfiguration {
    enum ModelType {
        case regular, reasoning
    }

    var modelType: ModelType {
        let isReasoning = SuggestedModelsCatalog.first(matching: name)?.isReasoning ?? false
        return isReasoning ? .reasoning : .regular
    }

    func modelType(reasoningEnabled: Bool) -> ModelType {
        return reasoningEnabled ? .reasoning : .regular
    }
}

extension ModelConfiguration {
    public static var availableModels: [ModelConfiguration] = SuggestedModelsCatalog.all.map {
        ModelConfiguration(id: $0.repoId)
    }

    public static var defaultModel: ModelConfiguration {
        availableModels.first ?? ModelConfiguration(id: "mlx-community/Llama-3.2-1B-Instruct-4bit")
    }

    public static func getModelByName(_ name: String) -> ModelConfiguration? {
        if let model = availableModels.first(where: { $0.name == name }) {
            return model
        }
        return nil
    }

    func getPromptHistory(thread: Thread, systemPrompt: String, reasoningEnabled: Bool? = nil) -> [[String: String]] {
        var history: [[String: String]] = []
        let isReasoning = reasoningEnabled ?? (modelType == .reasoning)

        // system prompt
        history.append([
            "role": "system",
            "content": systemPrompt,
        ])

        // messages
        for message in thread.sortedMessages {
            let role = message.role.rawValue
            history.append([
                "role": role,
                "content": formatForTokenizer(message.content, reasoningEnabled: isReasoning), // remove reasoning part
            ])
        }

        return history
    }

    // TODO: Remove this function when Jinja gets updated
    func formatForTokenizer(_ message: String, reasoningEnabled: Bool? = nil) -> String {
        let isReasoning = reasoningEnabled ?? (modelType == .reasoning)
        if isReasoning {
            let pattern = "<think>.*?(</think>|$)"
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
                let range = NSRange(location: 0, length: message.utf16.count)
                let formattedMessage = regex.stringByReplacingMatches(in: message, options: [], range: range, withTemplate: "")
                return " " + formattedMessage
            } catch {
                return " " + message
            }
        }
        return message
    }

    /// Returns the model's approximate size, in GB.
    public var modelSize: Decimal? {
        SuggestedModelsCatalog.first(matching: name).map { Decimal($0.sizeGB) }
    }
}
