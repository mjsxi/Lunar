import Combine
import Foundation

private struct UsageStatsSnapshot: Codable {
    var totalGeneratedTokens: Int64 = 0
    var totalResponses: Int = 0
    var totalGenerationTime: TimeInterval = 0
    var totalTimeToFirstToken: TimeInterval = 0
    var totalTTFTSamples: Int = 0
    var peakTokensPerSecond: Double = 0
    var lastUpdatedAt: Date?
    var hasBootstrappedFromMessages = false
}

@MainActor
final class UsageStatsStore: ObservableObject {
    @Published private var snapshot: UsageStatsSnapshot

    private let defaults: UserDefaults
    private let statsKey = "usageStats"
    private let integerFormatter: NumberFormatter

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.integerFormatter = NumberFormatter()
        integerFormatter.numberStyle = .decimal
        snapshot = defaults.data(forKey: statsKey)
            .flatMap { try? JSONDecoder().decode(UsageStatsSnapshot.self, from: $0) }
            ?? UsageStatsSnapshot()
    }

    var totalGeneratedTokens: Int64 { snapshot.totalGeneratedTokens }
    var totalResponses: Int { snapshot.totalResponses }
    var totalGenerationTime: TimeInterval { snapshot.totalGenerationTime }
    var peakTokensPerSecond: Double { snapshot.peakTokensPerSecond }
    var lastUpdatedAt: Date? { snapshot.lastUpdatedAt }
    var hasBootstrappedFromMessages: Bool { snapshot.hasBootstrappedFromMessages }
    var hasRecordedStats: Bool { snapshot.totalResponses > 0 || snapshot.totalGeneratedTokens > 0 }

    var averageTokensPerSecond: Double {
        guard snapshot.totalGenerationTime > 0 else { return 0 }
        return Double(snapshot.totalGeneratedTokens) / snapshot.totalGenerationTime
    }

    var averageTokensPerResponse: Double {
        guard snapshot.totalResponses > 0 else { return 0 }
        return Double(snapshot.totalGeneratedTokens) / Double(snapshot.totalResponses)
    }

    var averageTimeToFirstToken: TimeInterval {
        guard snapshot.totalTTFTSamples > 0 else { return 0 }
        return snapshot.totalTimeToFirstToken / Double(snapshot.totalTTFTSamples)
    }

    var totalGeneratedTokensFormatted: String {
        integerFormatter.string(from: NSNumber(value: totalGeneratedTokens)) ?? "\(totalGeneratedTokens)"
    }

    var totalResponsesFormatted: String {
        integerFormatter.string(from: NSNumber(value: totalResponses)) ?? "\(totalResponses)"
    }

    var averageTokensPerSecondFormatted: String {
        speedString(averageTokensPerSecond)
    }

    var peakTokensPerSecondFormatted: String {
        speedString(peakTokensPerSecond)
    }

    var averageTokensPerResponseFormatted: String {
        numberString(averageTokensPerResponse)
    }

    var averageTimeToFirstTokenFormatted: String {
        durationString(averageTimeToFirstToken)
    }

    func recordGeneration(
        tokenCount: Int,
        tokensPerSecond: Double?,
        generatingTime: TimeInterval?,
        timeToFirstToken: TimeInterval?
    ) {
        guard tokenCount > 0 else { return }

        snapshot.totalGeneratedTokens += Int64(tokenCount)
        snapshot.totalResponses += 1

        if let effectiveGenerationTime = effectiveGenerationTime(
            tokenCount: tokenCount,
            tokensPerSecond: tokensPerSecond,
            generatingTime: generatingTime
        ) {
            snapshot.totalGenerationTime += effectiveGenerationTime
        }

        if let timeToFirstToken, timeToFirstToken > 0 {
            snapshot.totalTimeToFirstToken += timeToFirstToken
            snapshot.totalTTFTSamples += 1
        }

        if let tokensPerSecond, tokensPerSecond.isFinite {
            snapshot.peakTokensPerSecond = max(snapshot.peakTokensPerSecond, tokensPerSecond)
        }

        snapshot.lastUpdatedAt = Date()
        persist()
    }

    func bootstrapIfNeeded(from messages: [Message]) {
        guard !snapshot.hasBootstrappedFromMessages else { return }

        var mostRecentTrackedMessageAt: Date?
        for message in messages where message.role == .assistant {
            guard shouldTrack(message), let tokenCount = message.tokenCount, tokenCount > 0 else { continue }
            snapshot.totalGeneratedTokens += Int64(tokenCount)
            snapshot.totalResponses += 1

            if let effectiveGenerationTime = effectiveGenerationTime(
                tokenCount: tokenCount,
                tokensPerSecond: message.tokensPerSecond,
                generatingTime: message.generatingTime
            ) {
                snapshot.totalGenerationTime += effectiveGenerationTime
            }

            if let timeToFirstToken = message.timeToFirstToken, timeToFirstToken > 0 {
                snapshot.totalTimeToFirstToken += timeToFirstToken
                snapshot.totalTTFTSamples += 1
            }

            if let tokensPerSecond = message.tokensPerSecond, tokensPerSecond.isFinite {
                snapshot.peakTokensPerSecond = max(snapshot.peakTokensPerSecond, tokensPerSecond)
            }

            mostRecentTrackedMessageAt = max(mostRecentTrackedMessageAt ?? message.timestamp, message.timestamp)
        }

        snapshot.hasBootstrappedFromMessages = true
        snapshot.lastUpdatedAt = snapshot.lastUpdatedAt ?? mostRecentTrackedMessageAt
        persist()
    }

    func reset() {
        snapshot = UsageStatsSnapshot(hasBootstrappedFromMessages: true)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: statsKey)
    }

    private func speedString(_ value: Double) -> String {
        "\(numberString(value)) tok/s"
    }

    private func durationString(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }

    private func numberString(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func effectiveGenerationTime(
        tokenCount: Int,
        tokensPerSecond: Double?,
        generatingTime: TimeInterval?
    ) -> TimeInterval? {
        if let generatingTime, generatingTime > 0 {
            return generatingTime
        }

        guard let tokensPerSecond, tokensPerSecond.isFinite, tokensPerSecond > 0 else { return nil }
        return Double(tokenCount) / tokensPerSecond
    }

    private func shouldTrack(_ message: Message) -> Bool {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.hasPrefix("Failed:")
    }
}
