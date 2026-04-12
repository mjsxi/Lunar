//
//  SettingsView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appPreferences: AppPreferences
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    @Environment(\.dismiss) var dismiss
    @Bindable var chatSession: ChatSessionController

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(.moon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 84, height: 84)

                        VStack(spacing: 4) {
                            Text("Lunar")
                                .font(.title)
                                .fontWeight(.semibold)

                            Text("a delightful app for running local LLMs with your knowledge")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 2)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)

                Section {
                    NavigationLink(destination: ModelsSettingsView()) {
                        HStack(spacing: 12) {
                            Label {
                                Text("models")
                                    .fixedSize()
                            } icon: {
                                Image(systemName: "gyroscope")
                            }

                            Spacer(minLength: 12)

                            Text(modelSettings.displayName(for: appPreferences.currentModelName ?? ""))
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    NavigationLink(destination: UniversalPromptSettingsView()) {
                        Label("universal prompt", systemImage: "list.bullet.rectangle.portrait")
                    }

                    NavigationLink(destination: KnowledgeBaseSettingsView()) {
                        Label("knowledge base", systemImage: "text.book.closed")
                    }

                    NavigationLink(destination: AppearanceSettingsView()) {
                        Label("appearance", systemImage: "paintbrush")
                    }

                    NavigationLink(destination: ChatsSettingsView(chatSession: chatSession)) {
                        Label("chats", systemImage: "ellipsis.bubble")
                    }

                    NavigationLink(destination: UsageStatsSettingsView()) {
                        Label("stats", systemImage: "atom")
                    }
                }

                Section {} footer: {
                    HStack {
                        Spacer()
                        Text("\(Bundle.main.releaseVersionNumber ?? "0") (\(Bundle.main.buildVersionNumber ?? "0"))")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.vertical)
                }
            }
            .formStyle(.grouped)
            .centeredSettingsPageTitle("settings")
            #if os(macOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        dismiss()
                    } label: {
                        Text("close")
                            .themedSettingsButtonContent()
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.background)
                }
            }
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                }
                #endif
            }
        }
        .tint(appPreferences.appTintColor.getColor())
        .environment(\.dynamicTypeSize, appPreferences.appFontSize.getFontSize())
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

extension View {
    func centeredSettingsButtonContent() -> some View {
        frame(maxWidth: .infinity, alignment: .center)
    }

    func themedSettingsButtonContent(color: Color = .accentColor) -> some View {
        centeredSettingsButtonContent()
            .foregroundStyle(color)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.08))
            )
    }

    func centeredSettingsPageTitle(_ title: String) -> some View {
        navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

#Preview {
    SettingsView(chatSession: ChatSessionController())
        .environmentObject(AppPreferences())
        .environmentObject(ModelSettingsStore())
        .environmentObject(UsageStatsStore())
        .environmentObject(KnowledgeBaseIndex())
        .environment(LLMEvaluator())
}
