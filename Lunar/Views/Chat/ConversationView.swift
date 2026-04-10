//
//  ConversationView.swift
//  fullmoon
//
//  Created by Xavier on 16/12/2024.
//

import MarkdownUI
import SwiftUI

extension TimeInterval {
    var formatted: String {
        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }
}

struct MessageView: View {
    @Environment(LLMEvaluator.self) var llm
    @Environment(\.self) private var environment
    @State private var collapsed = true
    let message: Message

    /// Pick black or white based on the resolved accent color's relative
    /// luminance, so the user-bubble text always has solid contrast against
    /// whichever theme color the OS is using.
    var userBubbleTextColor: Color {
        let resolved = Color.appAccent.resolve(in: environment)
        // sRGB → linear, then Rec. 709 luminance.
        func lin(_ c: Float) -> Float {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let L = 0.2126 * lin(resolved.red) + 0.7152 * lin(resolved.green) + 0.0722 * lin(resolved.blue)
        return L > 0.5 ? .black : .white
    }

    var isThinking: Bool {
        !message.content.contains("</think>")
    }

    func processThinkingContent(_ content: String) -> (String?, String?) {
        guard let startRange = content.range(of: "<think>") else {
            // No <think> tag, return entire content as the second part
            return (nil, content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let endRange = content.range(of: "</think>") else {
            // No </think> tag, return content after <think> without the tag
            let thinking = String(content[startRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (thinking, nil)
        }

        let thinking = String(content[startRange.upperBound ..< endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let afterThink = String(content[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        return (thinking, afterThink.isEmpty ? nil : afterThink)
    }

    var time: String {
        if isThinking, llm.running, let elapsedTime = llm.elapsedTime {
            if isThinking {
                return "(\(elapsedTime.formatted))"
            }
            if let thinkingTime = llm.thinkingTime {
                return thinkingTime.formatted
            }
        } else if let generatingTime = message.generatingTime {
            return "\(generatingTime.formatted)"
        }

        return "0s"
    }

    var thinkingLabel: some View {
        HStack {
            Button {
                collapsed.toggle()
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 12))
                    .fontWeight(.medium)
            }

            Text("\(isThinking ? "thinking..." : "thought for") \(time)")
                .italic()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer() }

            if message.role == .assistant {
                let (thinking, afterThink) = processThinkingContent(message.content)
                VStack(alignment: .leading, spacing: 16) {
                    if let thinking {
                        VStack(alignment: .leading, spacing: 12) {
                            thinkingLabel
                            if !collapsed {
                                if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack(spacing: 12) {
                                        Capsule()
                                            .frame(width: 2)
                                            .padding(.vertical, 1)
                                            .foregroundStyle(.fill)
                                        Markdown(thinking)
                                            .textSelection(.enabled)
                                            .markdownTextStyle {
                                                ForegroundColor(.secondary)
                                            }
                                    }
                                    .padding(.leading, 5)
                                }
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture {
                            collapsed.toggle()
                            if isThinking {
                                llm.collapsed = collapsed
                            }
                        }
                    }

                    if let afterThink {
                        Markdown(afterThink)
                            .textSelection(.enabled)
                    }
                }
                .padding(.trailing, 48)
            } else {
                Markdown(message.content)
                    .textSelection(.enabled)
                #if os(iOS)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                #else
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                #endif
                    .foregroundStyle(userBubbleTextColor)
                    .markdownTextStyle { ForegroundColor(userBubbleTextColor) }
                    .background(Color.appAccent)
                #if os(iOS)
                    .mask(RoundedRectangle(cornerRadius: 24))
                #elseif os(macOS)
                    .mask(RoundedRectangle(cornerRadius: 16))
                #endif
                    .padding(.leading, 48)
            }

            if message.role == .assistant { Spacer() }
        }
        .onAppear {
            if llm.running {
                collapsed = false
            }
        }
        .onChange(of: llm.elapsedTime) {
            if isThinking {
                llm.thinkingTime = llm.elapsedTime
            }
        }
        .onChange(of: isThinking) {
            if llm.running {
                llm.isThinking = isThinking
            }
        }
    }

    let platformBackgroundColor: Color = {
        #if os(iOS)
        return Color(UIColor.secondarySystemBackground)
        #elseif os(macOS)
        return Color(NSColor.secondarySystemFill)
        #endif
    }()
}

struct ConversationView: View {
    @Environment(LLMEvaluator.self) var llm
    @EnvironmentObject var appManager: AppManager
    let thread: Thread
    let generatingThreadID: UUID?

    @State private var scrollID: String?
    @State private var scrollInterrupted = false
    @State private var streamStartedAt: Date?
    @State private var showStreamingBubble = false

    var body: some View {
        ScrollViewReader { scrollView in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(thread.sortedMessages) { message in
                        VStack(alignment: .leading, spacing: 12) {
                            MessageView(message: message)
                            if message.role == .assistant,
                               let tps = message.tokensPerSecond,
                               let count = message.tokenCount,
                               let ttft = message.timeToFirstToken {
                                HStack(spacing: 12) {
                                    Text("\(String(format: "%.1f", tps)) tok/s")
                                    Text("\(count) tokens")
                                    Text("TTFT \(String(format: "%.2f", ttft))s")
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: 550, alignment: message.role == .user ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                        .padding()
                        .id(message.id.uuidString)
                    }

                    if showStreamingBubble && llm.running && !llm.output.isEmpty && thread.id == generatingThreadID {
                        MessageView(message: Message(role: .assistant, content: llm.output))
                            .frame(maxWidth: 550, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .id("output")
                    }

                    Rectangle()
                        .fill(.clear)
                        .frame(height: 1)
                        .id("bottom")
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollID, anchor: .bottom)
            .onChange(of: thread.sortedMessages.count) { _, _ in
                scrollInterrupted = false
                withAnimation { scrollView.scrollTo("bottom") }
            }
            .onChange(of: llm.running) { _, isRunning in
                if isRunning {
                    streamStartedAt = Date()
                    showStreamingBubble = false
                    Task {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if llm.running && thread.id == generatingThreadID {
                            showStreamingBubble = true
                        }
                    }
                } else {
                    showStreamingBubble = false
                    streamStartedAt = nil
                }
            }
            .onChange(of: llm.output) { _, _ in
                if showStreamingBubble && !scrollInterrupted {
                    scrollView.scrollTo("bottom")
                }
                if !llm.isThinking {
                    appManager.playHaptic()
                }
            }
            .onChange(of: showStreamingBubble) { _, visible in
                if visible {
                    scrollView.scrollTo("bottom")
                }
            }
            .onChange(of: scrollID) { _, _ in
                if llm.running {
                    scrollInterrupted = true
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

#Preview {
    ConversationView(thread: Thread(), generatingThreadID: nil)
        .environment(LLMEvaluator())
        .environmentObject(AppManager())
}
