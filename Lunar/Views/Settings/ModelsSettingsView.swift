//
//  ModelsSettingsView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/5/24.
//

import SwiftUI
import MLXLMCommon

struct ModelsSettingsView: View {
    @EnvironmentObject private var appPreferences: AppPreferences
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    @EnvironmentObject private var localhostServer: LocalhostServerController
    @Environment(\.dismiss) private var dismiss
    @Environment(LLMEvaluator.self) var llm
    var showsDismissButton = false

    var body: some View {
        Form {
            Section(header: Text("add model")) {
                NavigationLink {
                    OnboardingInstallModelView(showOnboarding: .constant(false), showsDismissButton: true)
                } label: {
                    Label("install a model", systemImage: "arrow.down.circle.dotted")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(.primary)
                .disabled(localhostServer.isLocked)

                NavigationLink {
                    AddModelView()
                } label: {
                    Label("add from huggingface…", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(.primary)
                .disabled(localhostServer.isLocked)
            }

            Section(header: Text(appPreferences.installedModels.count == 1 ? "installed model" : "installed models")) {
                ForEach(appPreferences.installedModels, id: \.self) { modelName in
                    NavigationLink {
                        ModelDetailView(modelName: modelName)
                    } label: {
                        let isSelected = appPreferences.currentModelName == modelName
                        let selectionColor: Color = localhostServer.isLocked ? .secondary : (isSelected ? .appAccent : .primary)
                        let textColor: Color = localhostServer.isLocked ? .secondary : .primary
                        HStack {
                            Button {
                                Task { await switchModel(modelName) }
                            } label: {
                                HStack {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectionColor)
                                    Text(modelSettings.displayName(for: modelName))
                                        .foregroundStyle(textColor)
                                }
                            }
                            .tint(.primary)
                            .buttonStyle(.borderless)
                            .disabled(localhostServer.isLocked)

                            Spacer()

                            Text("edit")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            appPreferences.removeInstalledModel(modelName, settings: modelSettings)
                        } label: {
                            Label("delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets {
                        appPreferences.removeInstalledModel(appPreferences.installedModels[i], settings: modelSettings)
                    }
                }
            }

            #if os(macOS)
            Section(header: Text("other")) {
                NavigationLink("localhost settings…") {
                    LocalhostSettingsView()
                }
                NavigationLink("python backend settings…") {
                    PythonBackendSettingsView()
                }
            }
            if localhostServer.isLocked {
                Section {} footer: {
                    Text("localhost serving is active. model installs, selection changes, and backend changes are locked until you turn localhost off.")
                }
            }
            #endif
        }
        .formStyle(.grouped)
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsDismissButton {
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
        }
        #endif
        .task {
            for name in appPreferences.installedModels {
                _ = ModelConfiguration.getOrRegister(name)
            }
        }
        .centeredSettingsPageTitle("models")
    }
    
    private func switchModel(_ modelName: String) async {
        let model = ModelConfiguration.getOrRegister(modelName)
        appPreferences.currentModelName = modelName
        appPreferences.playHaptic()
        await llm.switchModel(model)
    }
}

#Preview {
    ModelsSettingsView()
}
