//
//  SettingsView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appManager: AppManager
    @Environment(\.dismiss) var dismiss
    @Environment(LLMEvaluator.self) var llm
    @Binding var currentThread: Thread?

    var body: some View {
        NavigationStack {
            Form {
                Section {} header: {
                    HStack {
                        Spacer()
                        Image(.ohNoNawno)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.secondary)
                            .frame(height: 48)
                            .padding(.vertical, 8)
                        Spacer()
                    }
                }

                Section {
                    NavigationLink(destination: ModelsSettingsView()) {
                        Label {
                            Text("models")
                                .fixedSize()
                        } icon: {
                            Image(systemName: "gyroscope")
                        }
                        .badge(appManager.modelDisplayName(appManager.currentModelName ?? ""))
                    }

                    NavigationLink(destination: AppearanceSettingsView()) {
                        Label("appearance", systemImage: "paintbrush")
                    }

                    NavigationLink(destination: UniversalPromptSettingsView()) {
                        Label("universal prompt", systemImage: "list.bullet.rectangle.portrait")
                    }

                    NavigationLink(destination: ChatsSettingsView(currentThread: $currentThread)) {
                        Label("chats", systemImage: "ellipsis.bubble")
                    }

                    NavigationLink(destination: KnowledgeBaseSettingsView()) {
                        Label("knowledge base", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section {} footer: {
                    HStack {
                        Spacer()
                        Text("v\(Bundle.main.releaseVersionNumber ?? "0").\(Bundle.main.buildVersionNumber ?? "0")")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.vertical)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("settings")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                        }
                    }
                    #elseif os(macOS)
                    ToolbarItem(placement: .destructiveAction) {
                        Button(action: { dismiss() }) {
                            Text("close")
                        }
                    }
                    #endif
                }
        }
        .tint(appManager.appTintColor.getColor())
        .environment(\.dynamicTypeSize, appManager.appFontSize.getFontSize())
    }
}

extension Bundle {
    var releaseVersionNumber: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var buildVersionNumber: String? {
        return infoDictionary?["CFBundleVersion"] as? String
    }
}

#Preview {
    SettingsView(currentThread: .constant(nil))
        .environmentObject(AppManager())
        .environmentObject(KnowledgeBaseIndex())
        .environment(LLMEvaluator())
}
