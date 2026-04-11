//
//  EmbeddingService.swift
//  Lunar
//
//  Generates vector embeddings for text using Apple's NaturalLanguage framework.
//

import Foundation
import NaturalLanguage

protocol EmbeddingService {
    func embed(_ texts: [String]) -> [[Float]]
}

struct AppleNLEmbedding: EmbeddingService {
    func embed(_ texts: [String]) -> [[Float]] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return texts.map { _ in [Float]() }
        }

        return texts.map { text in
            if let vector = embedding.vector(for: text) {
                return vector.map { Float($0) }
            }
            return [Float]()
        }
    }
}
