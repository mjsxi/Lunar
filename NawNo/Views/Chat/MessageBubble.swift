import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var isStreaming = false
    @State private var thinkingExpanded = false

    private var parsed: (thinking: String?, content: String) {
        // Use thinkingContent if already parsed upstream
        if let thinking = message.thinkingContent, !thinking.isEmpty {
            return (thinking, message.content)
        }
        // Otherwise parse thinking tags from content directly
        if message.role == .assistant,
           message.content.contains("<think>") || message.content.contains("</think>") {
            return Self.extractThinking(from: message.content)
        }
        return (nil, message.content)
    }

    private static func extractThinking(from text: String) -> (thinking: String?, content: String) {
        // Case 1: Has <think>...</think>
        if let startRange = text.range(of: "<think>") {
            let before = String(text[text.startIndex..<startRange.lowerBound])
            if let endRange = text.range(of: "</think>", range: startRange.upperBound..<text.endIndex) {
                let thinking = String(text[startRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let after = String(text[endRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let content = (before.trimmingCharacters(in: .whitespacesAndNewlines) + " " + after).trimmingCharacters(in: .whitespacesAndNewlines)
                return (thinking.isEmpty ? nil : thinking, content)
            }
            // Unclosed <think> — treat rest as thinking
            let thinking = String(text[startRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (thinking.isEmpty ? nil : thinking, before.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Case 2: Only </think> (tokenizer stripped <think> as special token)
        if let endRange = text.range(of: "</think>") {
            let thinking = String(text[text.startIndex..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(text[endRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (thinking.isEmpty ? nil : thinking, content)
        }
        return (nil, text)
    }

    var body: some View {
        let parts = parsed
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 12) {
            if message.role == .user {
                Text(message.content)
                    .textSelection(.enabled)
                    .lineSpacing(3.5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            } else {
                if let thinking = parts.thinking {
                    ThinkingDisclosure(
                        content: thinking,
                        isExpanded: isStreaming && parts.content.isEmpty ? .constant(true) : $thinkingExpanded,
                        isStreaming: isStreaming
                    )
                    .padding(.horizontal, 12)
                }

                if !parts.content.isEmpty {
                    MarkdownTextView(markdown: parts.content)
                        .padding(.horizontal, 12)
                }
            }

            if let stats = message.stats {
                HStack(spacing: 8) {
                    Label(stats.formattedTPS, systemImage: "speedometer")
                    Label("\(stats.totalTokens) tokens", systemImage: "number")
                    Label(stats.formattedTTFT, systemImage: "clock")
                    Label(stats.formattedTotal, systemImage: "timer")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 12)
            }
        }
        .frame(maxWidth: 550, alignment: message.role == .user ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 16)
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return .accentColor
        case .assistant:
            return Color(.controlBackgroundColor)
        case .system:
            return .orange.opacity(0.2)
        }
    }
}

struct ThinkingDisclosure: View {
    let content: String
    @Binding var isExpanded: Bool
    var isStreaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)

                    if isStreaming && isExpanded {
                        HStack(spacing: 4) {
                            Text("Thinking")
                            ProgressView()
                                .controlSize(.mini)
                        }
                    } else {
                        Text("Thought")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                MarkdownTextView(markdown: content, fontSize: 12, textColor: .secondaryLabelColor)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
