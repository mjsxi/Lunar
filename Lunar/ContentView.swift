//
//  ContentView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appPreferences: AppPreferences
    @EnvironmentObject var modelSettings: ModelSettingsStore
    @EnvironmentObject var usageStats: UsageStatsStore
    @EnvironmentObject var knowledgeBase: KnowledgeBaseIndex
    @Environment(\.modelContext) var modelContext
    @Environment(LLMEvaluator.self) var llm
    @State private var chatSession = ChatSessionController()
    @State var showOnboarding = false
    @State var showSettings = false
    @State var showChats = false
    @FocusState var isPromptFocused: Bool

    var body: some View {
        Group {
            if appPreferences.userInterfaceIdiom == .pad || appPreferences.userInterfaceIdiom == .mac {
                NavigationSplitView {
                    ChatsListView(chatSession: chatSession, isPromptFocused: $isPromptFocused)
                    #if os(macOS)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 320)
                    #endif
                } detail: {
                    ChatView(chatSession: chatSession, isPromptFocused: $isPromptFocused, showChats: $showChats, showSettings: $showSettings)
                }
            } else {
                ChatView(chatSession: chatSession, isPromptFocused: $isPromptFocused, showChats: $showChats, showSettings: $showSettings)
            }
        }
        .task {
            chatSession.configure(
                preferences: appPreferences,
                modelSettings: modelSettings,
                knowledgeBase: knowledgeBase,
                usageStats: usageStats,
                llm: llm,
                modelContext: modelContext
            )
            isPromptFocused = true
        }
        .task {
            bootstrapUsageStatsIfNeeded()
        }
        .task(id: appPreferences.currentModelName) {
            if let modelName = appPreferences.currentModelName {
                await llm.switchModel(named: modelName)
            }
        }
        .if(appPreferences.userInterfaceIdiom == .phone) { view in
            view
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            if !showChats && gesture.startLocation.x < 20 && gesture.translation.width > 100 {
                                appPreferences.playHaptic()
                                showChats = true
                            }
                        }
                )
        }
        .sheet(isPresented: $showChats) {
            ChatsListView(chatSession: chatSession, isPromptFocused: $isPromptFocused)
                .presentationDragIndicator(.hidden)
                .if(appPreferences.userInterfaceIdiom == .phone) { view in
                    view.presentationDetents([.medium, .large])
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(chatSession: chatSession)
                .presentationDragIndicator(.hidden)
                .if(appPreferences.userInterfaceIdiom == .phone) { view in
                    view.presentationDetents([.medium])
                }
        }
        .sheet(isPresented: $showOnboarding, onDismiss: dismissOnboarding) {
            OnboardingView(showOnboarding: $showOnboarding)
        }
        .tint(appPreferences.appTintColor.getColor())
        .fontDesign(appPreferences.appFontDesign.getFontDesign())
        .environment(\.dynamicTypeSize, appPreferences.appFontSize.getFontSize())
        .fontWidth(appPreferences.appFontWidth.getFontWidth())
        .onAppear {
            appPreferences.incrementNumberOfVisits()
        }
    }
    
    func dismissOnboarding() {
        isPromptFocused = true
    }

    private func bootstrapUsageStatsIfNeeded() {
        guard !usageStats.hasBootstrappedFromMessages else { return }

        let descriptor = FetchDescriptor<Message>()
        guard let messages = try? modelContext.fetch(descriptor) else { return }
        usageStats.bootstrapIfNeeded(from: messages)
    }
}

extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

#Preview {
    ContentView()
}
