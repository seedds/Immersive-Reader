//
//  BookImportService.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import SwiftData

enum BookImportError: LocalizedError {
    case notEpub(String)

    var errorDescription: String? {
        switch self {
        case .notEpub(let filename):
            "Only EPUB files are supported. \(filename) is not an EPUB."
        }
    }
}

@MainActor
enum BookImportService {
    @discardableResult
    static func importBooks(from urls: [URL], modelContext: ModelContext) throws -> [Book] {
        var importedBooks: [Book] = []
        let libraryDirectory = try AppStorage.documentsDirectory()

        for sourceURL in urls {
            let filename = AppStorage.sanitizedFilename(sourceURL.lastPathComponent)
            guard filename.lowercased().hasSuffix(".epub") else {
                throw BookImportError.notEpub(filename)
            }

            if try bookExists(originalFilename: filename, modelContext: modelContext) {
                continue
            }

            let hasAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let destinationURL = AppStorage.uniqueFileURL(named: filename, in: libraryDirectory)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            do {
                try EPUBArchive.validateEPUB(at: destinationURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }

            let bookId = UUID()
            let extractionURL = try AppStorage.extractedDirectory().appendingPathComponent(bookId.uuidString, isDirectory: true)

            do {
                try EPUBArchive(url: destinationURL).extract(to: extractionURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                try? FileManager.default.removeItem(at: extractionURL)
                throw error
            }

            let book = Book(
                id: bookId,
                title: displayTitle(for: filename),
                originalFilename: filename,
                epubFilePath: destinationURL.path,
                extractedDirectoryPath: extractionURL.path
            )
            modelContext.insert(book)
            importedBooks.append(book)
        }

        try modelContext.save()
        return importedBooks
    }

    private static func bookExists(originalFilename: String, modelContext: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { book in
                book.originalFilename == originalFilename
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    private static func displayTitle(for filename: String) -> String {
        URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
    }
}
