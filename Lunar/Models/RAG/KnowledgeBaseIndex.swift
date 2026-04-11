//
//  KnowledgeBaseIndex.swift
//  Lunar
//
//  Orchestrates document loading, chunking, embedding, and search
//  for the personal knowledge base feature.
//

import Foundation
import SwiftUI

@MainActor
class KnowledgeBaseIndex: ObservableObject {
    @Published var isIndexing = false
    @Published var indexProgress: Double = 0
    @Published var stats = KnowledgeBaseStats()
    @Published var folderURL: URL?
    @Published var errorMessage: String?

    private let store = VectorStore()
    private let chunker = TextChunker()
    private let embeddingService: EmbeddingService = AppleNLEmbedding()

    private let indexDirName = ".lunar_index"

    var hasIndex: Bool { !store.isEmpty }
    var hasFolderConfigured: Bool { folderURL != nil }

    private var indexDirURL: URL? {
        folderURL?.appendingPathComponent(indexDirName)
    }

    // MARK: - Lifecycle

    func loadPersistedIndex() {
        guard let indexDir = indexDirURL else { return }
        do {
            try store.load(from: indexDir)
            stats = store.computeStats(indexDir: indexDir)
        } catch {
            // No persisted index yet — that's fine
        }
    }

    // MARK: - Indexing

    func indexFolder() async {
        guard let folderURL else { return }
        isIndexing = true
        indexProgress = 0
        errorMessage = nil

        do {
            let files = try DocumentLoaderRegistry.supportedFiles(in: folderURL)
            guard !files.isEmpty else {
                errorMessage = "No supported files found in folder."
                isIndexing = false
                return
            }

            store.clear()
            var manifestEntries: [IndexManifest.FileEntry] = []
            var allChunks: [DocumentChunk] = []

            for (i, fileURL) in files.enumerated() {
                guard let loader = DocumentLoaderRegistry.loader(for: fileURL) else { continue }
                do {
                    let text = try loader.loadText(from: fileURL)
                    let relativePath = fileURL.lastPathComponent
                    let chunks = chunker.chunk(text: text, fileName: relativePath)
                    allChunks.append(contentsOf: chunks)

                    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let modDate = attrs[.modificationDate] as? Date ?? Date()
                    let fileSize = attrs[.size] as? Int64 ?? 0
                    manifestEntries.append(IndexManifest.FileEntry(
                        relativePath: relativePath,
                        modificationDate: modDate,
                        fileSize: fileSize
                    ))
                } catch {
                    // Skip files that can't be loaded
                    print("[KnowledgeBase] Skipped \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
                indexProgress = Double(i + 1) / Double(files.count) * 0.5
            }

            // Embed all chunks
            let batchSize = 64
            for batchStart in stride(from: 0, to: allChunks.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, allChunks.count)
                let texts = allChunks[batchStart..<batchEnd].map { $0.text }
                let embeddings = embeddingService.embed(texts)
                for (j, embedding) in embeddings.enumerated() {
                    allChunks[batchStart + j].embedding = embedding
                }
                indexProgress = 0.5 + Double(batchEnd) / Double(allChunks.count) * 0.5
            }

            // Filter out chunks with empty embeddings
            let validChunks = allChunks.filter { !$0.embedding.isEmpty }
            store.addChunks(validChunks)
            store.updateManifest(IndexManifest(files: manifestEntries))

            // Persist
            if let indexDir = indexDirURL {
                try store.save(to: indexDir)
                stats = store.computeStats(indexDir: indexDir)
            }

            indexProgress = 1.0
        } catch {
            errorMessage = error.localizedDescription
        }

        isIndexing = false
    }

    // MARK: - Refresh

    func refresh() async {
        guard let folderURL else { return }
        isIndexing = true
        indexProgress = 0
        errorMessage = nil

        do {
            let files = try DocumentLoaderRegistry.supportedFiles(in: folderURL)
            let currentFileNames = Set(files.map { $0.lastPathComponent })
            let indexedFileNames = Set(store.manifest.files.map { $0.relativePath })
            let manifestLookup = Dictionary(uniqueKeysWithValues: store.manifest.files.map { ($0.relativePath, $0) })

            // Find new or modified files
            var filesToIndex: [URL] = []
            for fileURL in files {
                let name = fileURL.lastPathComponent
                if let existing = manifestLookup[name] {
                    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let modDate = attrs[.modificationDate] as? Date ?? Date()
                    if modDate > existing.modificationDate {
                        filesToIndex.append(fileURL)
                        store.removeChunks(forFile: name)
                    }
                } else {
                    filesToIndex.append(fileURL)
                }
            }

            // Remove chunks for deleted files
            let deletedFiles = indexedFileNames.subtracting(currentFileNames)
            for name in deletedFiles {
                store.removeChunks(forFile: name)
            }

            // Index new/modified files
            var newChunks: [DocumentChunk] = []
            var newManifestEntries = store.manifest.files.filter { currentFileNames.contains($0.relativePath) && !filesToIndex.map { $0.lastPathComponent }.contains($0.relativePath) }

            for (i, fileURL) in filesToIndex.enumerated() {
                guard let loader = DocumentLoaderRegistry.loader(for: fileURL) else { continue }
                do {
                    let text = try loader.loadText(from: fileURL)
                    let chunks = chunker.chunk(text: text, fileName: fileURL.lastPathComponent)
                    newChunks.append(contentsOf: chunks)

                    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let modDate = attrs[.modificationDate] as? Date ?? Date()
                    let fileSize = attrs[.size] as? Int64 ?? 0
                    newManifestEntries.append(IndexManifest.FileEntry(
                        relativePath: fileURL.lastPathComponent,
                        modificationDate: modDate,
                        fileSize: fileSize
                    ))
                } catch {
                    print("[KnowledgeBase] Skipped \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
                indexProgress = Double(i + 1) / Double(filesToIndex.count) * 0.5
            }

            // Embed new chunks
            if !newChunks.isEmpty {
                let batchSize = 64
                for batchStart in stride(from: 0, to: newChunks.count, by: batchSize) {
                    let batchEnd = min(batchStart + batchSize, newChunks.count)
                    let texts = newChunks[batchStart..<batchEnd].map { $0.text }
                    let embeddings = embeddingService.embed(texts)
                    for (j, embedding) in embeddings.enumerated() {
                        newChunks[batchStart + j].embedding = embedding
                    }
                    indexProgress = 0.5 + Double(batchEnd) / Double(newChunks.count) * 0.5
                }

                let validChunks = newChunks.filter { !$0.embedding.isEmpty }
                store.addChunks(validChunks)
            }

            store.updateManifest(IndexManifest(files: newManifestEntries))

            if let indexDir = indexDirURL {
                try store.save(to: indexDir)
                stats = store.computeStats(indexDir: indexDir)
            }

            if filesToIndex.isEmpty && deletedFiles.isEmpty {
                errorMessage = "Already up to date."
            }

            indexProgress = 1.0
        } catch {
            errorMessage = error.localizedDescription
        }

        isIndexing = false
    }

    // MARK: - Purge

    func purge() {
        store.clear()
        stats = KnowledgeBaseStats()
        errorMessage = nil

        if let indexDir = indexDirURL {
            try? FileManager.default.removeItem(at: indexDir)
        }
    }

    // MARK: - Query

    func query(_ text: String, topK: Int = 5) -> [DocumentChunk] {
        let embeddings = embeddingService.embed([text])
        guard let queryVector = embeddings.first, !queryVector.isEmpty else { return [] }
        return store.search(query: queryVector, topK: topK)
    }

    // MARK: - Folder Management

    func setFolder(_ url: URL) {
        folderURL = url
        // Save bookmark
        if let bookmark = try? url.bookmarkData(options: bookmarkOptions) {
            UserDefaults.standard.set(bookmark, forKey: "ragFolderBookmark")
        }
        loadPersistedIndex()
    }

    func resolveBookmark() {
        guard let data = UserDefaults.standard.data(forKey: "ragFolderBookmark") else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: bookmarkResolutionOptions, bookmarkDataIsStale: &stale) {
            #if os(iOS)
            _ = url.startAccessingSecurityScopedResource()
            #endif
            folderURL = url
            if stale {
                // Re-save bookmark
                if let newBookmark = try? url.bookmarkData(options: bookmarkOptions) {
                    UserDefaults.standard.set(newBookmark, forKey: "ragFolderBookmark")
                }
            }
            loadPersistedIndex()
        }
    }

    func removeFolder() {
        purge()
        folderURL = nil
        UserDefaults.standard.removeObject(forKey: "ragFolderBookmark")
    }

    private var bookmarkOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return []
        #else
        return .minimalBookmark
        #endif
    }

    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return []
        #else
        return []
        #endif
    }
}
