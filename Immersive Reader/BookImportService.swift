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
    enum ExistingBookStrategy {
        case skip
        case overwrite
    }

    @discardableResult
    static func importBooks(from urls: [URL], modelContext: ModelContext) throws -> [Book] {
        try importBooks(from: urls, modelContext: modelContext, existingBookStrategy: .skip)
    }

    @discardableResult
    static func importBooks(
        from urls: [URL],
        modelContext: ModelContext,
        existingBookStrategy: ExistingBookStrategy
    ) throws -> [Book] {
        var importedBooks: [Book] = []
        let libraryDirectory = try AppStorage.documentsDirectory()
        let fileManager = FileManager.default

        for sourceURL in urls {
            let filename = AppStorage.sanitizedFilename(sourceURL.lastPathComponent)
            guard filename.lowercased().hasSuffix(".epub") else {
                throw BookImportError.notEpub(filename)
            }

            let existingBook = try existingBook(originalFilename: filename, modelContext: modelContext)
            if existingBook != nil, existingBookStrategy == .skip {
                continue
            }

            let hasAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let destinationURL = libraryDirectory.appendingPathComponent(filename, isDirectory: false)
            let sourcePath = sourceURL.standardizedFileURL.path
            let destinationPath = destinationURL.standardizedFileURL.path

            if sourcePath != destinationPath {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }

            do {
                try EPUBArchive.validateEPUB(at: destinationURL)
            } catch {
                if sourcePath != destinationPath {
                    try? fileManager.removeItem(at: destinationURL)
                }
                throw error
            }

            let bookId = existingBook?.id ?? UUID()
            let extractionURL = try AppStorage.extractedDirectory().appendingPathComponent(bookId.uuidString, isDirectory: true)

            try? fileManager.removeItem(at: extractionURL)

            do {
                try EPUBArchive(url: destinationURL).extract(to: extractionURL)
            } catch {
                if sourcePath != destinationPath {
                    try? fileManager.removeItem(at: destinationURL)
                }
                try? fileManager.removeItem(at: extractionURL)
                throw error
            }

            let package = EPUBMetadataService.packageInfo(in: extractionURL)
            let metadata = package.map { EPUBMetadataService.metadata(in: extractionURL, package: $0) } ?? EPUBMetadata()
            let mediaOverlay: EPUBMediaOverlayParseResult?
            if let package {
                mediaOverlay = try? EPUBMediaOverlayService.parseAndWrite(in: extractionURL, package: package)
            } else {
                mediaOverlay = nil
            }

            let book: Book
            if let existingBook {
                existingBook.title = metadata.title ?? displayTitle(for: filename)
                existingBook.author = metadata.author ?? "Unknown Author"
                existingBook.originalFilename = filename
                existingBook.epubFilePath = destinationURL.path
                existingBook.extractedDirectoryPath = extractionURL.path
                existingBook.coverImagePath = metadata.coverImagePath
                existingBook.language = metadata.language
                existingBook.metadataIdentifier = metadata.identifier
                existingBook.mediaOverlayJSONPath = mediaOverlay?.jsonURL.path
                existingBook.mediaOverlayActiveClass = mediaOverlay?.manifest.activeClass
                existingBook.mediaOverlayDuration = mediaOverlay?.manifest.duration
                existingBook.mediaOverlayClipCount = mediaOverlay?.manifest.clipCount
                existingBook.importedAt = Date()
                book = existingBook
            } else {
                let newBook = Book(
                    id: bookId,
                    title: metadata.title ?? displayTitle(for: filename),
                    author: metadata.author ?? "Unknown Author",
                    originalFilename: filename,
                    epubFilePath: destinationURL.path,
                    extractedDirectoryPath: extractionURL.path,
                    coverImagePath: metadata.coverImagePath,
                    language: metadata.language,
                    metadataIdentifier: metadata.identifier,
                    mediaOverlayJSONPath: mediaOverlay?.jsonURL.path,
                    mediaOverlayActiveClass: mediaOverlay?.manifest.activeClass,
                    mediaOverlayDuration: mediaOverlay?.manifest.duration,
                    mediaOverlayClipCount: mediaOverlay?.manifest.clipCount
                )
                modelContext.insert(newBook)
                book = newBook
            }

            importedBooks.append(book)
        }

        try modelContext.save()
        return importedBooks
    }

    @discardableResult
    static func reimportAllBooksFromDocuments(modelContext: ModelContext) throws -> [Book] {
        let libraryDirectory = try AppStorage.documentsDirectory()
        let epubURLs = try FileManager.default.contentsOfDirectory(
            at: libraryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "epub" }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return try importBooks(from: epubURLs, modelContext: modelContext, existingBookStrategy: .overwrite)
    }

    private static func existingBook(originalFilename: String, modelContext: ModelContext) throws -> Book? {
        var descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { book in
                book.originalFilename == originalFilename
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func displayTitle(for filename: String) -> String {
        URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
    }
}
