//
//  ModelDetailView.swift
//  Lunar
//
//  Per-model settings. On macOS shows a backend picker (mlx-swift vs
//  mlx_lm Python). On iOS the backend is fixed to mlx-swift so the
//  picker is hidden.
//

import SwiftUI

struct ModelDetailView: View {
    @EnvironmentObject var appManager: AppManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let modelName: String

    @State private var showRenameAlert = false
    @State private var renameDraft = ""

    var body: some View {
        Form {
            Section("model") {
                HStack {
                    Text("display name")
                    Spacer()
                    Text(appManager.modelDisplayName(modelName))
                        .foregroundStyle(.secondary)
                    Button {
                        renameDraft = appManager.modelDisplayName(modelName)
                        showRenameAlert = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                }
                if let gb = appManager.modelSizeGB(for: modelName) {
                    LabeledContent("size", value: "\(formatModelSize(gb)) GB")
                }
                LabeledContent("repo", value: modelName)
                if let url = appManager.huggingFaceURL(for: modelName) {
                    Button {
                        openURL(url)
                    } label: {
                        HStack {
                            Text("hugging face")
                            Spacer()
                            Text(url.absoluteString)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section(header: Text("system prompt"), footer: Text("leave empty to use the universal prompt")) {
                TextEditor(text: Binding(
                    get: { appManager.modelSystemPrompts[modelName] ?? appManager.systemPrompt },
                    set: { appManager.setSystemPrompt($0, for: modelName) }
                ))
                .textEditorStyle(.plain)
                .frame(minHeight: 80)
            }

            Section(header: Text("reasoning"), footer: Text("enable to let the model think step-by-step using <think> tags. works with reasoning-capable models.")) {
                Toggle("reasoning enabled", isOn: Binding(
                    get: { appManager.isReasoningEnabled(for: modelName) },
                    set: { appManager.setReasoningEnabled($0, for: modelName) }
                ))
            }

            Section("model tweaks") {
                let contextBinding = Binding<Double>(
                    get: { Double(appManager.contextWindow(for: modelName)) },
                    set: { appManager.setContextWindow(Int($0), for: modelName) }
                )
                VStack(alignment: .leading, spacing: 4) {
                    let tokens = Int(contextBinding.wrappedValue)
                    let est = estimatedRAMGB(forContext: tokens)
                    let ratio = est / max(appManager.availableMemory, 0.001)
                    HStack(spacing: 4) {
                        Text("context window")
                        Spacer()
                        Text("\(tokens) tokens ≈ \(Text(String(format: "%.1f GB", est)).foregroundStyle(ramColor(ratio: ratio))) RAM")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: contextBinding, in: 1024...262144, step: 1024)
                }

                let tempBinding = Binding<Double>(
                    get: { Double(appManager.temperature(for: modelName)) },
                    set: { appManager.setTemperature(Float($0), for: modelName) }
                )
                VStack(alignment: .leading) {
                    HStack {
                        Text("temperature")
                        Spacer()
                        Text(String(format: "%.2f", tempBinding.wrappedValue))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: tempBinding, in: 0...2, step: 0.05)
                }

                let topKBinding = Binding<Double>(
                    get: { Double(appManager.topK(for: modelName)) },
                    set: { appManager.setTopK(Int($0), for: modelName) }
                )
                VStack(alignment: .leading) {
                    HStack {
                        Text("top K")
                        Spacer()
                        Text("\(Int(topKBinding.wrappedValue))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: topKBinding, in: 0...200, step: 1)
                }

                let topPBinding = Binding<Double>(
                    get: { Double(appManager.topP(for: modelName)) },
                    set: { appManager.setTopP(Float($0), for: modelName) }
                )
                VStack(alignment: .leading) {
                    HStack {
                        Text("top P")
                        Spacer()
                        Text(String(format: "%.2f", topPBinding.wrappedValue))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: topPBinding, in: 0...1, step: 0.01)
                }
            }

            #if os(macOS)
            Section("inference backend") {
                Picker("backend", selection: backendBinding) {
                    ForEach(BackendKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                Text("MLX Swift runs in-process. MLX LM (Python) launches `mlx_lm.server` as a subprocess and streams over its OpenAI-compatible API. Configure the python path under Models → Python backend settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appManager.backend(for: modelName) == .pythonMLX {
                Section(header: Text("python backend tuning"),
                        footer: Text("changes take effect on next server restart. larger prefill step sizes reduce time-to-first-token but use more peak memory.")) {
                    let prefillBinding = Binding<Double>(
                        get: { Double(appManager.prefillStepSize(for: modelName)) },
                        set: { appManager.setPrefillStepSize(Int($0), for: modelName) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("prefill step size")
                            Spacer()
                            Text("\(Int(prefillBinding.wrappedValue))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: prefillBinding, in: 512...16384, step: 512)
                    }

                    let cacheBinding = Binding<Double>(
                        get: { Double(appManager.promptCacheGB(for: modelName)) },
                        set: { appManager.setPromptCacheGB(Int($0), for: modelName) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        let cacheGB = Int(cacheBinding.wrappedValue)
                        let weightsGB = appManager.modelSizeGB(for: modelName) ?? 1.0
                        let totalGB = weightsGB + Double(cacheGB)
                        let ratio = totalGB / max(appManager.availableMemory, 0.001)
                        HStack(spacing: 4) {
                            Text("prompt cache")
                            Spacer()
                            Text("\(cacheGB) GB — est. \(Text(String(format: "%.1f GB", totalGB)).foregroundStyle(ramColor(ratio: ratio))) total RAM")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: cacheBinding, in: 1...32, step: 1)
                    }
                }
            }
            #endif

            Button(role: .destructive) {
                appManager.removeInstalledModel(modelName)
                dismiss()
            } label: {
                Label("delete model", systemImage: "trash")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
            }
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .formStyle(.grouped)
        .navigationTitle(appManager.modelDisplayName(modelName))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("rename model", isPresented: $showRenameAlert) {
            TextField("display name", text: $renameDraft)
            Button("save") {
                appManager.setDisplayNameOverride(renameDraft, for: modelName)
            }
            Button("reset", role: .destructive) {
                appManager.setDisplayNameOverride(nil, for: modelName)
            }
            Button("cancel", role: .cancel) {}
        }
    }

    /// Rough RAM estimate for running this model with the given context size.
    /// Combines weight footprint (from the suggested-models catalog when known)
    /// with a KV-cache approximation of ~2 KB per token.
    private func estimatedRAMGB(forContext tokens: Int) -> Double {
        let weightsGB = SuggestedModelsCatalog.first(matching: modelName)?.sizeGB ?? 1.0
        let kvBytes = Double(tokens) * 2_048
        let kvGB = kvBytes / 1_073_741_824.0
        return weightsGB + kvGB
    }

    private func formatModelSize(_ gb: Double) -> String {
        gb.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", gb)
            : String(format: "%.2f", gb)
    }

    private func ramColor(ratio: Double) -> Color {
        if ratio >= 0.75 { return .red }
        if ratio >= 0.5 { return .orange }
        return .secondary
    }

    private var backendBinding: Binding<BackendKind> {
        Binding(
            get: { appManager.backend(for: modelName) },
            set: { appManager.setBackend($0, for: modelName) }
        )
    }
}
