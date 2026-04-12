//
//  ChatView.swift
//  fullmoon
//
//  Created by Jordan Singer on 12/3/24.
//

import MarkdownUI
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appPreferences: AppPreferences
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    @EnvironmentObject private var knowledgeBase: KnowledgeBaseIndex
    @EnvironmentObject private var localhostServer: LocalhostServerController
    @Environment(LLMEvaluator.self) private var llm

    @Bindable var chatSession: ChatSessionController
    @FocusState.Binding var isPromptFocused: Bool
    @Binding var showChats: Bool
    @Binding var showSettings: Bool

    @State private var showModelPicker = false
    @State private var showServerError = false
    @State private var emptyStatePhrase = ChatView.emptyStatePhrases.randomElement() ?? "Say something..."
    @State private var moonRotation = 0.0

    static let emptyStatePhrases: [String] = [
        "Say something...",
        "Well what do you wanna know?",
        "How can I help you today?",
        "What's on your mind?",
        "Ask me anything.",
        "Got a question?",
        "Let's chat.",
        "Where should we start?",
        "Curious about something?",
        "Spit it out, I'm listening."
    ]

    private var isPromptEmpty: Bool {
        chatSession.isPromptEmpty
    }

    private var platformBackgroundColor: Color {
        #if os(iOS)
        Color(UIColor.secondarySystemBackground)
        #elseif os(macOS)
        Color(NSColor.secondarySystemFill)
        #endif
    }

    private var inactiveComposerActionColor: Color {
        .gray
    }

    private var inactiveKnowledgeToggleColor: Color {
        inactiveComposerActionColor.opacity(0.55)
    }

    private var isLocalhostLocked: Bool {
        localhostServer.isLocked
    }

    private var knowledgeBaseToggle: some View {
        Button {
            chatSession.toggleRAGForCurrentChat()
        } label: {
            Image(systemName: chatSession.isRAGActiveForChat ? "text.book.closed.fill" : "text.book.closed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(chatSession.isRAGActiveForChat ? Color.appAccent : inactiveKnowledgeToggleColor)
            #if os(iOS)
            .frame(width: 24, height: 24)
            #else
            .frame(width: 16, height: 16)
            #endif
        }
        #if os(iOS)
        .padding(.trailing, 4)
        .padding(.bottom, 12)
        #else
        .padding(.trailing, 4)
        .padding(.bottom, 8)
        #endif
        .disabled(isLocalhostLocked)
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }

    private var chatInput: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                if isLocalhostLocked {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                        Text("Localhost active, turn off to chat")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minHeight: 32)
                } else {
                    TextField(chatSession.inputPlaceholder, text: $chatSession.prompt, axis: .vertical)
                        .focused($isPromptFocused)
                        .textFieldStyle(.plain)
                        .disabled(chatSession.isModelMismatch)
                    #if os(iOS)
                        .padding(.horizontal, 16)
                    #elseif os(macOS)
                        .padding(.horizontal, 12)
                        .onSubmit {
                            handleShiftReturn()
                        }
                        .submitLabel(.send)
                    #endif
                        .padding(.vertical, 8)
                    #if os(iOS)
                        .frame(minHeight: 48)
                        .onSubmit {
                            isPromptFocused = true
                            sendPrompt()
                        }
                    #elseif os(macOS)
                        .frame(minHeight: 32)
                    #endif
                }

                if knowledgeBase.hasIndex {
                    knowledgeBaseToggle
                }

                if llm.running {
                    stopButton
                } else {
                    generateButton
                }
            }
        }
        #if os(iOS)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(platformBackgroundColor)
        )
        #elseif os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.background)
        )
        #endif
    }

    private var generateButton: some View {
        Button {
            sendPrompt()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white, isPromptEmpty ? inactiveComposerActionColor : Color.appAccent)
            #if os(iOS)
                .frame(width: 24, height: 24)
            #else
                .frame(width: 16, height: 16)
            #endif
        }
        .disabled(isPromptEmpty || chatSession.isModelMismatch || isLocalhostLocked)
        #if os(iOS)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
        #else
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        #endif
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }

    private var stopButton: some View {
        Button {
            chatSession.stopGeneration()
        } label: {
            Image(systemName: "stop.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
            #if os(iOS)
                .frame(width: 24, height: 24)
            #else
                .frame(width: 16, height: 16)
            #endif
        }
        .disabled(llm.cancelled)
        #if os(iOS)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
        #else
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        #endif
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let currentThread = chatSession.currentThread {
                    ConversationView(thread: currentThread, generatingThreadID: chatSession.generatingThreadID)
                } else {
                    Spacer()
                    Text(emptyStatePhrase)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                chatInput
                    .padding()
            }
            .background(
                GeometryReader { geo in
                    Image(.moon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 800)
                        .opacity(chatSession.currentThread != nil ? 0.2 : 0.5)
                        .animation(.easeInOut(duration: 0.5), value: chatSession.currentThread != nil)
                        .rotationEffect(.degrees(moonRotation))
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.85 + 100)
                }
            )
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: Color(.windowBackgroundColor), location: 0),
                        .init(color: Color(.windowBackgroundColor).opacity(0.8), location: 0.4),
                        .init(color: Color(.windowBackgroundColor).opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            .onAppear {
                emptyStatePhrase = ChatView.emptyStatePhrases.randomElement() ?? "Say something..."
                moonRotation = 0
                withAnimation(.linear(duration: 540).repeatForever(autoreverses: false)) {
                    moonRotation = 360
                }
            }
            .navigationTitle(chatSession.chatTitle)
            .toolbarBackground(.hidden)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onChange(of: llm.modelInfo) {
                if case .failed = llm.loadState {
                    showServerError = true
                }
            }
            .alert("Python Server Failed", isPresented: $showServerError) {
                Button("Restart Server") {
                    Task {
                        #if os(macOS)
                        await llm.restartPythonBackend()
                        #endif
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(llm.modelInfo)
            }
            .alert("Something went wrong", isPresented: $chatSession.showingErrorAlert) {
                Button("OK", role: .cancel) {
                    chatSession.dismissError()
                }
            } message: {
                Text(chatSession.activeErrorMessage ?? "Unknown error")
            }
            .sheet(isPresented: $showModelPicker) {
                NavigationStack {
                    ModelsSettingsView(showsDismissButton: true)
                }
                #if os(iOS)
                .presentationDragIndicator(.visible)
                .if(appPreferences.userInterfaceIdiom == .phone) { view in
                    view.presentationDetents([.fraction(0.4)])
                }
                #endif
            }
            .toolbar {
                #if os(iOS)
                if appPreferences.userInterfaceIdiom == .phone {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            appPreferences.playHaptic()
                            showChats.toggle()
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appPreferences.playHaptic()
                        showModelPicker.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(llm.statusColor)
                                .frame(width: 8, height: 8)
                            Image(systemName: "gyroscope")
                        }
                        .padding(.leading, 4)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appPreferences.playHaptic()
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                #elseif os(macOS)
                ToolbarItem(id: "models", placement: .primaryAction) {
                    Button {
                        appPreferences.playHaptic()
                        showModelPicker.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(llm.statusColor)
                                .frame(width: 8, height: 8)
                            Image(systemName: "gyroscope")
                        }
                        .padding(.leading, 4)
                    }
                    .help("models")
                }
                ToolbarItem(id: "settings", placement: .primaryAction) {
                    Button {
                        appPreferences.playHaptic()
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("settings")
                }
                #endif
            }
        }
    }

    private func sendPrompt() {
        Task {
            await chatSession.sendCurrentPrompt()
            isPromptFocused = true
        }
    }

    #if os(macOS)
    private func handleShiftReturn() {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            chatSession.prompt.append("\n")
            isPromptFocused = true
        } else {
            sendPrompt()
        }
    }
    #endif
}

#Preview {
    @FocusState var isPromptFocused: Bool
    ChatView(chatSession: ChatSessionController(), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false))
        .environmentObject(AppPreferences())
        .environmentObject(ModelSettingsStore())
        .environmentObject(KnowledgeBaseIndex())
        .environment(LLMEvaluator())
}
