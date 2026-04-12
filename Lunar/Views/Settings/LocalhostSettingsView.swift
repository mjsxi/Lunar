#if os(macOS)
import AppKit
import SwiftUI

struct LocalhostSettingsView: View {
    @EnvironmentObject private var appPreferences: AppPreferences
    @EnvironmentObject private var modelSettings: ModelSettingsStore
    @EnvironmentObject private var localhostServer: LocalhostServerController

    @State private var portText = ""
    @State private var portError: String?

    var body: some View {
        Form {
            Section {
                Toggle("enable localhost", isOn: Binding(
                    get: { localhostServer.isEnabled },
                    set: { newValue in
                        if newValue {
                            guard commitPortInput() else { return }
                            Task { await localhostServer.setEnabled(true) }
                        } else {
                            Task { await localhostServer.setEnabled(false) }
                        }
                    }
                ))

                HStack {
                    Text("port")
                    Spacer()
                    TextField("", text: $portText, prompt: Text("58627"))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                        .disabled(localhostServer.isLocked)
                        .onSubmit {
                            _ = commitPortInput()
                        }
                }

                HStack {
                    Text("address")
                    Spacer()
                    Text(localhostServer.endpointURLString)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        copyToPasteboard(localhostServer.endpointURLString)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("copy")
                }

                endpointRow(title: "models", value: "\(localhostServer.endpointURLString)/v1/models")
                endpointRow(title: "chat", value: "\(localhostServer.endpointURLString)/v1/chat/completions")

                if let portError {
                    Text(portError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Text("status")
                    Spacer()
                    Text(statusText)
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("model")
                    Spacer()
                    Text(modelText)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("backend")
                    Spacer()
                    Text(backendText)
                        .foregroundStyle(.secondary)
                }

                if case .failed(let message) = localhostServer.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("localhost serving")
            } footer: {
                Text("when localhost serving is enabled, Lunar binds only to 127.0.0.1. the app must stay open, and chat generation plus model switching are disabled until you turn it off.")
            }
        }
        .formStyle(.grouped)
        .centeredSettingsPageTitle("localhost")
        .onAppear {
            portText = "\(appPreferences.localhostServerPort)"
        }
        .onChange(of: appPreferences.localhostServerPort) { _, newValue in
            if !localhostServer.isLocked {
                portText = "\(newValue)"
            }
        }
    }

    private var statusText: String {
        localhostServer.isEnabled ? "on" : "off"
    }

    private var statusColor: Color {
        switch localhostServer.state {
        case .idle:
            return .secondary
        case .starting:
            return .orange
        case .running:
            return .green
        case .failed:
            return .red
        }
    }

    private var modelText: String {
        guard let modelName = localhostServer.pinnedModelName else {
            return "undefined"
        }
        return modelSettings.displayName(for: modelName)
    }

    private var backendText: String {
        localhostServer.pinnedBackend?.displayName ?? "undefined"
    }

    @ViewBuilder
    private func endpointRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                copyToPasteboard(value)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("copy")
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @discardableResult
    private func commitPortInput() -> Bool {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65_535).contains(port) else {
            portError = "port must be a number between 1 and 65535"
            return false
        }
        portError = nil
        localhostServer.updateConfiguredPort(port)
        portText = "\(port)"
        return true
    }
}
#endif
