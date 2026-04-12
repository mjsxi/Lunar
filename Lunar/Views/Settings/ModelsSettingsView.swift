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

                NavigationLink {
                    AddModelView()
                } label: {
                    Label("add from huggingface…", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(.primary)
            }

            Section(header: Text(appPreferences.installedModels.count == 1 ? "installed model" : "installed models")) {
                ForEach(appPreferences.installedModels, id: \.self) { modelName in
                    NavigationLink {
                        ModelDetailView(modelName: modelName)
                    } label: {
                        HStack {
                            Button {
                                Task { await switchModel(modelName) }
                            } label: {
                                HStack {
                                    Image(systemName: appPreferences.currentModelName == modelName ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(appPreferences.currentModelName == modelName ? .appAccent : .primary)
                                    Text(modelSettings.displayName(for: modelName))
                                }
                            }
                            .tint(.primary)
                            .buttonStyle(.borderless)

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
                NavigationLink("Python backend settings…") {
                    PythonBackendSettingsView()
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
