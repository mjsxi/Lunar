import SwiftUI

struct UsageStatsSettingsView: View {
    @EnvironmentObject private var usageStats: UsageStatsStore
    @State private var showResetStatsConfirmation = false

    var body: some View {
        Form {
            Section(
                header: Text("usage"),
                footer: Text("usage stats track generated assistant output tokens on this device and persist independently from chat history.")
            ) {
                if usageStats.hasRecordedStats {
                    LabeledContent("assistant replies", value: usageStats.totalResponsesFormatted)
                    LabeledContent("tokens processed", value: usageStats.totalGeneratedTokensFormatted)
                    LabeledContent("avg tokens/reply", value: usageStats.averageTokensPerResponseFormatted)
                    LabeledContent("avg tok/s", value: usageStats.averageTokensPerSecondFormatted)
                    LabeledContent("best tok/s", value: usageStats.peakTokensPerSecondFormatted)
                    LabeledContent("avg TTFT", value: usageStats.averageTimeToFirstTokenFormatted)
                } else {
                    Text("No generations tracked yet.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showResetStatsConfirmation = true
                } label: {
                    Label("reset stats", systemImage: "arrow.counterclockwise")
                        .themedSettingsButtonContent(color: .red)
                }
                #if os(macOS)
                .buttonStyle(.borderless)
                #endif
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .formStyle(.grouped)
        .centeredSettingsPageTitle("stats")
        .alert("reset stats?", isPresented: $showResetStatsConfirmation) {
            Button("cancel", role: .cancel) {}
            Button("reset", role: .destructive) {
                usageStats.reset()
            }
        } message: {
            Text("this clears usage totals without affecting your chats.")
        }
    }
}

#Preview {
    UsageStatsSettingsView()
        .environmentObject(UsageStatsStore())
}
