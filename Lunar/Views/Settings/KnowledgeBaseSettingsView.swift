//
//  KnowledgeBaseSettingsView.swift
//  Lunar
//
//  Settings UI for the personal knowledge base (RAG) feature.
//

import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
#endif

struct KnowledgeBaseSettingsView: View {
    @EnvironmentObject var appManager: AppManager
    @EnvironmentObject var knowledgeBase: KnowledgeBaseIndex
    @State private var showPurgeConfirmation = false
    #if os(iOS)
    @State private var showDocumentPicker = false
    #endif

    var body: some View {
        Form {
            Section(header: Text("folder"), footer: Text("select a folder containing your writing and documents. supported formats: .txt, .md, .pdf, .rtf")) {
                if let url = knowledgeBase.folderURL {
                    LabeledContent("path", value: url.lastPathComponent)
                    Button("change folder") {
                        pickFolder()
                    }
                    Button("remove folder", role: .destructive) {
                        knowledgeBase.removeFolder()
                    }
                } else {
                    Button("select folder") {
                        pickFolder()
                    }
                }
            }

            if knowledgeBase.hasFolderConfigured {
                Section(header: Text("index"), footer: Text("the index is stored as a .lunar_index folder inside your knowledge base folder.")) {
                    if knowledgeBase.isIndexing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("indexing...")
                                .foregroundStyle(.secondary)
                            ProgressView(value: knowledgeBase.indexProgress)
                        }
                    } else if knowledgeBase.hasIndex {
                        LabeledContent("files indexed", value: "\(knowledgeBase.stats.fileCount)")
                        LabeledContent("chunks", value: "\(knowledgeBase.stats.chunkCount)")

                        Button {
                            Task { await knowledgeBase.refresh() }
                        } label: {
                            Label("refresh index", systemImage: "arrow.clockwise")
                        }

                        Button {
                            Task { await knowledgeBase.indexFolder() }
                        } label: {
                            Label("rebuild index", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } else {
                        Button {
                            Task { await knowledgeBase.indexFolder() }
                        } label: {
                            Label("build index", systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    if let error = knowledgeBase.errorMessage {
                        Text(error)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                if knowledgeBase.hasIndex {
                    Section(header: Text("resources")) {
                        LabeledContent("RAM estimate", value: knowledgeBase.stats.ramEstimateFormatted)
                        LabeledContent("disk usage", value: knowledgeBase.stats.diskUsageFormatted)
                    }

                    Section(header: Text("retrieval"), footer: Text("number of text chunks to include as context when answering questions.")) {
                        Stepper("context chunks: \(appManager.ragTopK)", value: $appManager.ragTopK, in: 1...20)
                    }

                    Section {
                        Button(role: .destructive) {
                            showPurgeConfirmation = true
                        } label: {
                            Label("purge knowledge base", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("knowledge base")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDocumentPicker) {
            FolderPicker { url in
                knowledgeBase.setFolder(url)
                Task { await knowledgeBase.indexFolder() }
            }
        }
        #endif
        .alert("purge knowledge base?", isPresented: $showPurgeConfirmation) {
            Button("purge", role: .destructive) {
                knowledgeBase.purge()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("this will delete the .lunar_index folder and all indexed data. your original files will not be affected.")
        }
    }

    private func pickFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your knowledge base folder"
        if panel.runModal() == .OK, let url = panel.url {
            knowledgeBase.setFolder(url)
            Task { await knowledgeBase.indexFolder() }
        }
        #else
        showDocumentPicker = true
        #endif
    }
}

#if os(iOS)
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            onPick(url)
        }
    }
}
#endif
