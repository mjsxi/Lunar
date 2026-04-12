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
    @EnvironmentObject var appPreferences: AppPreferences
    @EnvironmentObject var modelSettings: ModelSettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(LLMEvaluator.self) var llm
    @State private var deviceSupportsMetal3: Bool = true
    @Binding var showOnboarding: Bool
    var showsDismissButton = false
    @State var selectedModel = ModelConfiguration(id: "")
    @State private var hasUserSelected = false
    @State private var installingRepoId: String? = nil
    let suggestedModel = ModelConfiguration.defaultModel

    func sizeBadge(_ model: ModelConfiguration?) -> String? {
        guard let size = model?.modelSize else { return nil }
        return "\(size) GB"
    }

    func installedSizeBadge(_ modelName: String) -> String? {
        guard let gb = modelSettings.modelSizeGB(for: modelName) else { return nil }
        return "\(formatSize(gb)) GB"
    }

    /// The maximum allowable model size as a fraction of the device's total RAM.
    /// For example, a value of 0.6 means the model's size should not exceed 60% of the device's total memory.
    let modelMemoryThreshold = 0.75

    var modelsList: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image("lil-guy")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 74, height: 74)

                    Text("select from MLX models made for apple silicon that fit within your RAM size")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 2)
                    HStack(spacing: 4) {
                        Text("RAM Size:")
                            .foregroundStyle(.secondary)
                        Text("\(Int(appPreferences.availableMemory.rounded())) GB")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.quaternary)
                            )
                    }
                    .font(.subheadline)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)

            if appPreferences.installedModels.count > 0 {
                Section(header: Text("installed")) {
                    ForEach(appPreferences.installedModels, id: \.self) { modelName in
                        Button {} label: {
                            Label {
                                Text(modelSettings.displayName(for: modelName))
                            } icon: {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .badge(installedSizeBadge(modelName))
                        .tint(.primary)
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
                                        ramFitIndicator(forSizeGB: suggestion.sizeGB)
                                    }
                                } icon: {
                                    Image(systemName: selectedModel.name == suggestion.repoId ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedModel.name == suggestion.repoId ? .appAccent : .primary)
                                }
                            }
                            .tint(.primary)
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
        .centeredSettingsPageTitle("install a model")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasUserSelected {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        startInstall()
                    } label: {
                        Group {
                            if installingRepoId != nil {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("installing…")
                                }
                            } else {
                                Text("install")
                            }
                        }
                        .themedSettingsButtonContent()
                    }
                    #if os(macOS)
                    .buttonStyle(.borderless)
                    #endif
                    .disabled(installingRepoId != nil)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.background)
                }
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
                appPreferences.addInstalledModel(model.name)
                appPreferences.currentModelName = model.name
                installingRepoId = nil
                showOnboarding = false
                if showsDismissButton {
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    func ramFitIndicator(forSizeGB sizeGB: Double) -> some View {
        let ratio = sizeGB / appPreferences.availableMemory
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
        let ram = appPreferences.availableMemory
        let maxModelGB = ram * modelMemoryThreshold
        return SuggestedModelsCatalog.tiers
            .filter { Double($0) <= ram }
            .map { tier in
                let models = SuggestedModelsCatalog.all
                    .filter { $0.tierGB == tier }
                    .filter { $0.sizeGB <= maxModelGB }
                    .filter { !appPreferences.installedModels.contains($0.repoId) }
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
    @Previewable @State var appPreferences = AppPreferences()

    OnboardingInstallModelView(showOnboarding: .constant(true))
        .environmentObject(appPreferences)
        .environmentObject(ModelSettingsStore())
}
