//
//  OnboardingInstallModelView.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import MLXLMCommon
import os
import SwiftUI

struct OnboardingInstallModelView: View {
    @EnvironmentObject var appManager: AppManager
    @Environment(LLMEvaluator.self) var llm
    @State private var deviceSupportsMetal3: Bool = true
    @Binding var showOnboarding: Bool
    @State var selectedModel = ModelConfiguration(id: "")
    @State private var hasUserSelected = false
    @State private var installingRepoId: String? = nil
    let suggestedModel = ModelConfiguration.defaultModel

    func sizeBadge(_ model: ModelConfiguration?) -> String? {
        guard let size = model?.modelSize else { return nil }
        return "\(size) GB"
    }

    func installedSizeBadge(_ modelName: String) -> String? {
        guard let gb = appManager.modelSizeGB(for: modelName) else { return nil }
        return "\(formatSize(gb)) GB"
    }

    /// The maximum allowable model size as a fraction of the device's total RAM.
    /// For example, a value of 0.6 means the model's size should not exceed 60% of the device's total memory.
    let modelMemoryThreshold = 0.75

    var modelsList: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.dotted")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .foregroundStyle(.primary, .tertiary)

                    VStack(spacing: 4) {
                        Text("install a model")
                            .font(.title)
                            .fontWeight(.semibold)
                        Text("select from models that are optimized for apple silicon")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 6) {
                            Text("RAM Size:")
                                .foregroundStyle(.secondary)
                            Text("\(Int(appManager.availableMemory.rounded())) GB")
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(.quaternary)
                                )
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.vertical)
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)

            if appManager.installedModels.count > 0 {
                Section(header: Text("installed")) {
                    ForEach(appManager.installedModels, id: \.self) { modelName in
                        Button {} label: {
                            Label {
                                Text(appManager.modelDisplayName(modelName))
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        }
                        .badge(installedSizeBadge(modelName))
                        #if os(macOS)
                            .buttonStyle(.borderless)
                        #endif
                            .foregroundStyle(.secondary)
                            .disabled(true)
                    }
                }
            }

            ForEach(groupedSuggestions, id: \.tier) { group in
                Section(header: Text("\(group.tier) GB")) {
                    ForEach(group.models) { suggestion in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                selectedModel = ModelConfiguration(id: suggestion.repoId)
                                hasUserSelected = true
                            } label: {
                                Label {
                                    HStack(spacing: 6) {
                                        Text(suggestion.displayName)
                                            .tint(.primary)
                                        ramFitIndicator(forSizeGB: suggestion.sizeGB)
                                    }
                                } icon: {
                                    Image(systemName: selectedModel.name == suggestion.repoId ? "checkmark.circle.fill" : "circle")
                                }
                            }
                            .badge("\(formatSize(suggestion.sizeGB)) GB")
                            #if os(macOS)
                                .buttonStyle(.borderless)
                            #endif
                            .disabled(installingRepoId != nil)

                            if installingRepoId == suggestion.repoId {
                                VStack(alignment: .leading, spacing: 6) {
                                    if llm.progress <= 0 {
                                        HStack(spacing: 8) {
                                            ProgressView().controlSize(.small)
                                            Text("preparing download…")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        HStack(spacing: 8) {
                                            ProgressView(value: llm.progress, total: 1)
                                                .progressViewStyle(.linear)
                                            Text("\(Int(llm.progress * 100))%")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text("models can take some time to download depending on your internet speed — please keep this window open")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }
            }

        }
        .formStyle(.grouped)
    }

    var body: some View {
        ZStack {
            if deviceSupportsMetal3 {
                modelsList
                .toolbar {
                    if hasUserSelected {
                        #if os(iOS)
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { startInstall() } label: {
                                Text("install").font(.headline)
                            }
                            .disabled(installingRepoId != nil)
                        }
                        #else
                        ToolbarItem(placement: .confirmationAction) {
                            Button("install") { startInstall() }
                                .disabled(installingRepoId != nil)
                        }
                        #endif
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
                .task {
                    checkModels()
                }
            } else {
                DeviceNotSupportedView()
            }
        }
        .onAppear {
            checkMetal3Support()
        }
    }

    func startInstall() {
        let model = selectedModel
        installingRepoId = model.name
        Task {
            await llm.switchModel(model)
            await MainActor.run {
                appManager.addInstalledModel(model.name)
                appManager.currentModelName = model.name
                installingRepoId = nil
                showOnboarding = false
            }
        }
    }

    @ViewBuilder
    func ramFitIndicator(forSizeGB sizeGB: Double) -> some View {
        let ratio = sizeGB / appManager.availableMemory
        if ratio >= 0.8 {
            Image(systemName: "diamond.fill")
                .foregroundStyle(.red)
                .font(.caption2)
                .help("Uses ≥80% of system RAM")
        } else if ratio >= 0.5 {
            Image(systemName: "circle.fill")
                .foregroundStyle(.orange)
                .font(.caption2)
                .help("Uses ≥50% of system RAM")
        }
    }

    private func formatSize(_ gb: Double) -> String {
        gb.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", gb)
            : String(format: "%.1f", gb)
    }

    var groupedSuggestions: [(tier: Int, models: [SuggestedModel])] {
        let ram = appManager.availableMemory
        let maxModelGB = ram * modelMemoryThreshold
        return SuggestedModelsCatalog.tiers
            .filter { Double($0) <= ram }
            .map { tier in
                let models = SuggestedModelsCatalog.all
                    .filter { $0.tierGB == tier }
                    .filter { $0.sizeGB <= maxModelGB }
                    .filter { !appManager.installedModels.contains($0.repoId) }
                    .sorted { $0.sizeGB > $1.sizeGB }
                return (tier, models)
            }
            .filter { !$0.models.isEmpty }
    }

    func checkModels() {
        // no auto-selection: user must pick a model explicitly
    }

    func checkMetal3Support() {
        #if os(iOS)
        if let device = MTLCreateSystemDefaultDevice() {
            deviceSupportsMetal3 = device.supportsFamily(.metal3)
        }
        #endif
    }
}

#Preview {
    @Previewable @State var appManager = AppManager()

    OnboardingInstallModelView(showOnboarding: .constant(true))
        .environmentObject(appManager)
}
