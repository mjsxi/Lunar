//
//  TextChunker.swift
//  Lunar
//
//  Splits document text into chunks suitable for embedding and retrieval.
//

import Foundation
import NaturalLanguage

struct DocumentChunk: Codable, Identifiable {
    let id: UUID
    let fileName: String
    let chunkIndex: Int
    let text: String
    var embedding: [Float]

    init(fileName: String, chunkIndex: Int, text: String, embedding: [Float] = []) {
        self.id = UUID()
        self.fileName = fileName
        self.chunkIndex = chunkIndex
        self.text = text
        self.embedding = embedding
    }
}

struct TextChunker {
    let targetSize: Int
    let overlap: Int

    init(targetSize: Int = 1500, overlap: Int = 200) {
        self.targetSize = targetSize
        self.overlap = overlap
    }

    func chunk(text: String, fileName: String) -> [DocumentChunk] {
        let paragraphs = splitParagraphs(text)
        var chunks: [DocumentChunk] = []
        var buffer = ""
        var index = 0

        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if buffer.count + trimmed.count + 2 > targetSize && !buffer.isEmpty {
                chunks.append(DocumentChunk(fileName: fileName, chunkIndex: index, text: buffer))
                index += 1
                // Keep overlap from end of buffer
                let overlapText = String(buffer.suffix(overlap))
                buffer = overlapText
            }

            if !buffer.isEmpty { buffer += "\n\n" }
            buffer += trimmed

            // If a single paragraph exceeds target, split by sentences
            if buffer.count > targetSize {
                let sentences = splitSentences(buffer)
                buffer = ""
                for sentence in sentences {
                    if buffer.count + sentence.count + 1 > targetSize && !buffer.isEmpty {
                        chunks.append(DocumentChunk(fileName: fileName, chunkIndex: index, text: buffer))
                        index += 1
                        buffer = String(buffer.suffix(overlap))
                    }
                    if !buffer.isEmpty { buffer += " " }
                    buffer += sentence
                }
            }
        }

        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(DocumentChunk(fileName: fileName, chunkIndex: index, text: buffer))
        }

        return chunks
    }

    private func splitParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
    }

    private func splitSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        return sentences
    }
}
