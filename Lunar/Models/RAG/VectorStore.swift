//
//  VectorStore.swift
//  Lunar
//
//  In-memory vector store with cosine similarity search.
//  Persists to .lunar_index/ inside the knowledge base folder.
//

import Foundation

struct KnowledgeBaseStats: Equatable {
    var fileCount: Int = 0
    var chunkCount: Int = 0
    var ramEstimateBytes: Int64 = 0
    var diskUsageBytes: Int64 = 0

    var ramEstimateFormatted: String {
        ByteCountFormatter.string(fromByteCount: ramEstimateBytes, countStyle: .memory)
    }

    var diskUsageFormatted: String {
        ByteCountFormatter.string(fromByteCount: diskUsageBytes, countStyle: .file)
    }
}

struct IndexManifest: Codable {
    struct FileEntry: Codable {
        let relativePath: String
        let modificationDate: Date
        let fileSize: Int64
    }
    var files: [FileEntry] = []
}

class VectorStore {
    private(set) var chunks: [DocumentChunk] = []
    private(set) var manifest = IndexManifest()

    var isEmpty: Bool { chunks.isEmpty }

    func addChunks(_ newChunks: [DocumentChunk]) {
        chunks.append(contentsOf: newChunks)
    }

    func removeChunks(forFile fileName: String) {
        chunks.removeAll { $0.fileName == fileName }
    }

    func clear() {
        chunks = []
        manifest = IndexManifest()
    }

    func search(query: [Float], topK: Int = 5) -> [DocumentChunk] {
        guard !query.isEmpty else { return [] }

        let scored = chunks.compactMap { chunk -> (DocumentChunk, Float)? in
            guard !chunk.embedding.isEmpty else { return nil }
            let sim = cosineSimilarity(query, chunk.embedding)
            return (chunk, sim)
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { $0.0 }
    }

    // MARK: - Persistence

    func save(to indexDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: indexDir, withIntermediateDirectories: true)

        let chunksURL = indexDir.appendingPathComponent("chunks.json")
        let manifestURL = indexDir.appendingPathComponent("manifest.json")
        let statsURL = indexDir.appendingPathComponent("stats.json")

        let encoder = JSONEncoder()
        try encoder.encode(chunks).write(to: chunksURL)
        try encoder.encode(manifest).write(to: manifestURL)

        let stats = computeStats(indexDir: indexDir)
        let statsDict: [String: Int64] = [
            "fileCount": Int64(stats.fileCount),
            "chunkCount": Int64(stats.chunkCount),
            "ramEstimateBytes": stats.ramEstimateBytes,
            "diskUsageBytes": stats.diskUsageBytes
        ]
        try encoder.encode(statsDict).write(to: statsURL)
    }

    func load(from indexDir: URL) throws {
        let chunksURL = indexDir.appendingPathComponent("chunks.json")
        let manifestURL = indexDir.appendingPathComponent("manifest.json")

        let decoder = JSONDecoder()
        let chunksData = try Data(contentsOf: chunksURL)
        chunks = try decoder.decode([DocumentChunk].self, from: chunksData)

        let manifestData = try Data(contentsOf: manifestURL)
        manifest = try decoder.decode(IndexManifest.self, from: manifestData)
    }

    func updateManifest(_ newManifest: IndexManifest) {
        manifest = newManifest
    }

    func computeStats(indexDir: URL? = nil) -> KnowledgeBaseStats {
        let uniqueFiles = Set(chunks.map { $0.fileName })
        let embeddingBytes = chunks.reduce(0) { $0 + $1.embedding.count } * MemoryLayout<Float>.size
        let textBytes = chunks.reduce(0) { $0 + $1.text.utf8.count }
        let ramEstimate = Int64(embeddingBytes + textBytes)

        var diskUsage: Int64 = 0
        if let indexDir {
            diskUsage = directorySize(indexDir)
        }

        return KnowledgeBaseStats(
            fileCount: uniqueFiles.count,
            chunkCount: chunks.count,
            ramEstimateBytes: ramEstimate,
            diskUsageBytes: diskUsage
        )
    }

    // MARK: - Private

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
