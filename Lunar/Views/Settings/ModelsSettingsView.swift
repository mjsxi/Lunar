//
//  ModelsSettingsView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/5/24.
//

import SwiftUI
import MLXLMCommon

struct ModelsSettingsView: View {
    @EnvironmentObject var appManager: AppManager
    @Environment(LLMEvaluator.self) var llm
    @State var showOnboardingInstallModelView = false
    @State var showAddModelView = false

    var body: some View {
        Form {
            Section(header: Text("add model")) {
                Button {
                    showOnboardingInstallModelView.toggle()
                } label: {
                    Label("install a model", systemImage: "arrow.down.circle.dotted")
                }
                .tint(.primary)
                #if os(macOS)
                .buttonStyle(.borderless)
                #endif

                Button {
                    showAddModelView = true
                } label: {
                    Label("add from huggingface…", systemImage: "plus.circle")
                }
                .tint(.primary)
                #if os(macOS)
                .buttonStyle(.borderless)
                #endif
            }

            Section(header: Text(appManager.installedModels.count == 1 ? "installed model" : "installed models")) {
                ForEach(appManager.installedModels, id: \.self) { modelName in
                    NavigationLink {
                        ModelDetailView(modelName: modelName)
                    } label: {
                        HStack {
                            Button {
                                Task { await switchModel(modelName) }
                            } label: {
                                HStack {
                                    Image(systemName: appManager.currentModelName == modelName ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(appManager.currentModelName == modelName ? .appAccent : .primary)
                                    Text(appManager.modelDisplayName(modelName))
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
                            appManager.removeInstalledModel(modelName)
                        } label: {
                            Label("delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets {
                        appManager.removeInstalledModel(appManager.installedModels[i])
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
        .task {
            for name in appManager.installedModels {
                _ = ModelConfiguration.getOrRegister(name)
            }
        }
        .navigationTitle("models")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showAddModelView) {
            NavigationStack {
                AddModelView(isPresented: $showAddModelView)
                    .environmentObject(appManager)
                    .environment(llm)
            }
        }
        .sheet(isPresented: $showOnboardingInstallModelView) {
            NavigationStack {
                OnboardingInstallModelView(showOnboarding: $showOnboardingInstallModelView)
                    .environment(llm)
                    .toolbar {
                        #if os(iOS)
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: { showOnboardingInstallModelView = false }) {
                                Image(systemName: "xmark")
                            }
                        }
                        #elseif os(macOS)
                        ToolbarItem(placement: .destructiveAction) {
                            Button(action: { showOnboardingInstallModelView = false }) {
                                Text("close")
                            }
                        }
                        #endif
                    }
            }
        }
    }
    
    private func switchModel(_ modelName: String) async {
        let model = ModelConfiguration.getOrRegister(modelName)
        appManager.currentModelName = modelName
        appManager.playHaptic()
        await llm.switchModel(model)
    }
}

#Preview {
    ModelsSettingsView()
}
