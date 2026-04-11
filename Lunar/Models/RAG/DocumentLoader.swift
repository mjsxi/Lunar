//
//  DocumentLoader.swift
//  Lunar
//
//  Loads text content from supported file types for the knowledge base.
//

import Foundation
import PDFKit

protocol DocumentLoader {
    func loadText(from url: URL) throws -> String
}

struct PlainTextLoader: DocumentLoader {
    func loadText(from url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

struct PDFLoader: DocumentLoader {
    func loadText(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw DocumentLoaderError.unreadableFile(url.lastPathComponent)
        }
        var text = ""
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let pageText = page.string {
                text += pageText + "\n\n"
            }
        }
        return text
    }
}

struct RTFLoader: DocumentLoader {
    func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        return attributed.string
    }
}

enum DocumentLoaderError: LocalizedError {
    case unsupportedFileType(String)
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext): return "Unsupported file type: \(ext)"
        case .unreadableFile(let name): return "Could not read file: \(name)"
        }
    }
}

struct DocumentLoaderRegistry {
    static let supportedExtensions: Set<String> = ["txt", "md", "markdown", "pdf", "rtf", "text"]

    static func loader(for url: URL) -> DocumentLoader? {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown", "text":
            return PlainTextLoader()
        case "pdf":
            return PDFLoader()
        case "rtf":
            return RTFLoader()
        default:
            return nil
        }
    }

    static func supportedFiles(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                files.append(fileURL)
            }
        }
        return files
    }
}
