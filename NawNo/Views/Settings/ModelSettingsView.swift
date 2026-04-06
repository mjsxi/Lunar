import SwiftUI

struct ModelSettingsView: View {
    let model: ModelEntry
    @State private var settings: ModelSettings = .defaults
    @State private var isLoading = true
    @State private var saveTask: Task<Void, Never>?
    @State private var lastSaved: Date?

    @State private var pythonAvailable: Bool?

    var body: some View {
        Form {
            modelInfoSection
            backendSection
            contextWindowSection
            systemPromptSection
            samplingSection
            generationSection
            actionsSection
        }
        .formStyle(.grouped)
        .onAppear {
            isLoading = true
            settings = SettingsStorage.settings(for: model)
            // Delay to prevent auto-save on load
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                isLoading = false
            }
        }
        .onChange(of: model.id) { _, _ in
            isLoading = true
            settings = SettingsStorage.settings(for: model)
            lastSaved = nil
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                isLoading = false
            }
        }
        .onChange(of: settings) { _, _ in
            debounceSave()
        }
    }

    // MARK: - Sections

    private var modelInfoSection: some View {
        Section("Model Info") {
            LabeledContent("Vendor", value: model.vendor)
            LabeledContent("Size on Disk", value: model.formattedDiskSize)
            LabeledContent("Added", value: model.dateAdded.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Path", value: model.relativePath)
        }
    }

    private var backendSection: some View {
        Section("Inference Backend") {
            Picker("Backend", selection: $settings.backend) {
                Text("Auto (try Swift, fall back to Python)").tag(BackendType.auto)
                Text("Swift (mlx-swift, native)").tag(BackendType.swift)
                Text("Python (mlx-lm server)").tag(BackendType.python)
            }
            .pickerStyle(.radioGroup)

            if settings.backend == .python || settings.backend == .auto {
                HStack(spacing: 6) {
                    if let available = pythonAvailable {
                        Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(available ? .green : .red)
                        Text(available ? "mlx-lm installed" : "mlx-lm not found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !available {
                            Text("— install with: pip install mlx-lm")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Re-check") {
                        pythonAvailable = nil
                        PythonMLXService.clearCache()
                        Task {
                            pythonAvailable = await PythonMLXService.isAvailable()
                        }
                    }
                    .font(.caption)
                }
                .task {
                    pythonAvailable = await PythonMLXService.isAvailable()
                }
            }
        }
    }

    private var contextWindowSection: some View {
        Section("Context Window") {
            HStack {
                Text("Size (tokens)")
                Spacer()
                TextField("", value: $settings.contextWindowSize, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }

            let ramEstimate = RAMEstimator.estimateRAM(
                modelDiskBytes: model.diskSizeBytes,
                contextSize: settings.contextWindowSize
            )
            LabeledContent("Estimated RAM") {
                Text(RAMEstimator.formatBytes(ramEstimate))
                    .foregroundStyle(ramEstimate > 16 * 1024 * 1024 * 1024 ? .red : .primary)
            }

            LabeledContent("Available Tokens (after prompt)") {
                Text("\(settings.availableContextTokens)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemPromptSection: some View {
        Section("System Prompt") {
            TextEditor(text: $settings.systemPrompt)
                .frame(minHeight: 80)
                .font(.body.monospaced())

            HStack {
                Text("~\(settings.estimatedSystemPromptTokens) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    settings.systemPrompt = ""
                }
                .font(.caption)
                .disabled(settings.systemPrompt.isEmpty)
            }
        }
    }

    private var samplingSection: some View {
        Section("Sampling") {
            VStack(alignment: .leading) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", settings.temperature))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.temperature, in: 0...2, step: 0.05)
            }

            HStack {
                Text("Top-K")
                Spacer()
                TextField("", value: $settings.topK, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Top-P")
                    Spacer()
                    Text(String(format: "%.2f", settings.topP))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.topP, in: 0...1, step: 0.05)
            }
        }
    }

    private var generationSection: some View {
        Section("Generation") {
            Toggle("Enable Thinking", isOn: $settings.enableThinking)
            Text("When enabled, models that support thinking (e.g. QwQ, DeepSeek-R1) will show their reasoning process in a collapsible block.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Max Tokens")
                Spacer()
                TextField("", value: $settings.maxTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Repetition Penalty")
                    Spacer()
                    Text(String(format: "%.2f", settings.repetitionPenalty))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.repetitionPenalty, in: 1...2, step: 0.05)
            }

            HStack {
                Text("Repetition Context")
                Spacer()
                TextField("", value: $settings.repetitionContextSize, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            HStack {
                if let saved = lastSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved \(saved.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Reset to Defaults") {
                    settings = .defaults
                }
            }

            Text("Settings saved to nawno_settings.json in the model directory")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Auto-save

    private func debounceSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            SettingsStorage.save(settings, for: model)
            lastSaved = Date()
        }
    }
}
