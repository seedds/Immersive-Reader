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

enum BookImportService {
    struct ImportProgress: Sendable {
        let fractionCompleted: Double
        let message: String
    }

    struct RefreshProgress: Sendable {
        let fractionCompleted: Double
        let message: String
    }

    private struct SourceFileFingerprint: Sendable, Equatable {
        let fileSize: Int64?
        let modifiedAt: Date?
    }

    private struct ExistingBookSnapshot: Sendable {
        let id: UUID
        let originalFilename: String
        let epubFilePath: String
        let extractedDirectoryPath: String
        let mediaOverlayJSONPath: String?
        let sourceFileSize: Int64?
        let sourceFileModifiedAt: Date?
    }

    private struct PreparedBookImport: Sendable {
        let id: UUID
        let filename: String
        let epubFilePath: String
        let extractedDirectoryPath: String
        let metadata: EPUBMetadata
        let mediaOverlayJSONPath: String?
        let mediaOverlayActiveClass: String?
        let mediaOverlayDuration: Double?
        let mediaOverlayClipCount: Int?
        let fingerprint: SourceFileFingerprint
    }

    private struct StagedLibraryFile: Sendable {
        let fileURL: URL
        let shouldCleanupOnFailure: Bool
    }

    private struct RefreshPreparation: Sendable {
        let preparedImports: [PreparedBookImport]
        let removedBookIDs: [UUID]
    }

    enum ExistingBookStrategy {
        case skip
        case overwrite
    }

    @MainActor
    @discardableResult
    static func importBook(
        from sourceURL: URL,
        modelContext: ModelContext,
        existingBookStrategy: ExistingBookStrategy = .skip,
        progressHandler: (@MainActor @Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> Book? {
        let filename = AppStorage.sanitizedFilename(sourceURL.lastPathComponent)
        guard filename.lowercased().hasSuffix(".epub") else {
            throw BookImportError.notEpub(filename)
        }

        let existingBook = try existingBook(originalFilename: filename, modelContext: modelContext)
        let existingBookSnapshot = existingBook.map(snapshot(for:))

        let bookID = existingBook?.id ?? UUID()
        let preparedImport = try await Task.detached(priority: .userInitiated) {
            try await prepareImport(
                from: sourceURL,
                filename: filename,
                existingBook: existingBookSnapshot,
                existingBookStrategy: existingBookStrategy,
                bookID: bookID,
                progressHandler: progressHandler
            )
        }.value

        guard let preparedImport else {
            return nil
        }

        await reportImportProgress(
            ImportProgress(fractionCompleted: 0.96, message: "Saving book..."),
            using: progressHandler
        )

        let book = try applyPreparedImport(
            preparedImport,
            existingBookID: existingBook?.id,
            modelContext: modelContext
        )

        await reportImportProgress(
            ImportProgress(fractionCompleted: 1, message: "Import complete"),
            using: progressHandler
        )
        return book
    }

    @discardableResult
    @MainActor
    static func importBooks(from urls: [URL], modelContext: ModelContext) throws -> [Book] {
        try importBooks(from: urls, modelContext: modelContext, existingBookStrategy: .skip)
    }

    @discardableResult
    @MainActor
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

            let fingerprint = try sourceFileFingerprint(for: destinationURL)

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
                existingBook.sourceFileSize = fingerprint.fileSize
                existingBook.sourceFileModifiedAt = fingerprint.modifiedAt
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
                    mediaOverlayClipCount: mediaOverlay?.manifest.clipCount,
                    sourceFileSize: fingerprint.fileSize,
                    sourceFileModifiedAt: fingerprint.modifiedAt
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
    @MainActor
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

    @MainActor
    @discardableResult
    static func refreshBooksFromDocuments(
        modelContext: ModelContext,
        progressHandler: (@MainActor @Sendable (RefreshProgress) -> Void)? = nil
    ) async throws -> [Book] {
        await reportRefreshProgress(
            RefreshProgress(fractionCompleted: 0.02, message: "Scanning EPUB files..."),
            using: progressHandler
        )

        let libraryDirectory = try AppStorage.documentsDirectory()
        let epubURLs = try FileManager.default.contentsOfDirectory(
            at: libraryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "epub" }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        let existingBooks = try modelContext.fetch(FetchDescriptor<Book>())
        let snapshots = existingBooks.map { book in
            ExistingBookSnapshot(
                id: book.id,
                originalFilename: book.originalFilename,
                epubFilePath: book.epubFilePath,
                extractedDirectoryPath: book.extractedDirectoryPath,
                mediaOverlayJSONPath: book.mediaOverlayJSONPath,
                sourceFileSize: book.sourceFileSize,
                sourceFileModifiedAt: book.sourceFileModifiedAt
            )
        }

        let preparation = try await Task.detached(priority: .userInitiated) {
            try await prepareRefresh(from: epubURLs, existingBooks: snapshots, progressHandler: progressHandler)
        }.value

        await reportRefreshProgress(
            RefreshProgress(fractionCompleted: 0.72, message: "Applying library updates..."),
            using: progressHandler
        )

        let existingBooksByID = Dictionary(uniqueKeysWithValues: existingBooks.map { ($0.id, $0) })
        let existingBooksByFilename = Dictionary(uniqueKeysWithValues: existingBooks.map { ($0.originalFilename, $0) })
        let fileManager = FileManager.default
        let totalApplyOperations = max(preparation.removedBookIDs.count + preparation.preparedImports.count, 1)
        var completedApplyOperations = 0

        for bookID in preparation.removedBookIDs {
            guard let book = existingBooksByID[bookID] else {
                continue
            }

            try? fileManager.removeItem(atPath: book.epubFilePath)
            try? fileManager.removeItem(atPath: book.extractedDirectoryPath)
            modelContext.delete(book)

            completedApplyOperations += 1
            await reportRefreshProgress(
                RefreshProgress(
                    fractionCompleted: 0.72 + (Double(completedApplyOperations) / Double(totalApplyOperations)) * 0.23,
                    message: "Removing missing books \(completedApplyOperations) of \(preparation.removedBookIDs.count)"
                ),
                using: progressHandler
            )
        }

        var refreshedBooks: [Book] = []
        for (index, preparedImport) in preparation.preparedImports.enumerated() {
            let book: Book
            if let existingBook = existingBooksByFilename[preparedImport.filename] {
                existingBook.title = preparedImport.metadata.title ?? displayTitle(for: preparedImport.filename)
                existingBook.author = preparedImport.metadata.author ?? "Unknown Author"
                existingBook.originalFilename = preparedImport.filename
                existingBook.epubFilePath = preparedImport.epubFilePath
                existingBook.extractedDirectoryPath = preparedImport.extractedDirectoryPath
                existingBook.coverImagePath = preparedImport.metadata.coverImagePath
                existingBook.language = preparedImport.metadata.language
                existingBook.metadataIdentifier = preparedImport.metadata.identifier
                existingBook.mediaOverlayJSONPath = preparedImport.mediaOverlayJSONPath
                existingBook.mediaOverlayActiveClass = preparedImport.mediaOverlayActiveClass
                existingBook.mediaOverlayDuration = preparedImport.mediaOverlayDuration
                existingBook.mediaOverlayClipCount = preparedImport.mediaOverlayClipCount
                existingBook.sourceFileSize = preparedImport.fingerprint.fileSize
                existingBook.sourceFileModifiedAt = preparedImport.fingerprint.modifiedAt
                existingBook.importedAt = Date()
                book = existingBook
            } else {
                let newBook = Book(
                    id: preparedImport.id,
                    title: preparedImport.metadata.title ?? displayTitle(for: preparedImport.filename),
                    author: preparedImport.metadata.author ?? "Unknown Author",
                    originalFilename: preparedImport.filename,
                    epubFilePath: preparedImport.epubFilePath,
                    extractedDirectoryPath: preparedImport.extractedDirectoryPath,
                    coverImagePath: preparedImport.metadata.coverImagePath,
                    language: preparedImport.metadata.language,
                    metadataIdentifier: preparedImport.metadata.identifier,
                    mediaOverlayJSONPath: preparedImport.mediaOverlayJSONPath,
                    mediaOverlayActiveClass: preparedImport.mediaOverlayActiveClass,
                    mediaOverlayDuration: preparedImport.mediaOverlayDuration,
                    mediaOverlayClipCount: preparedImport.mediaOverlayClipCount,
                    sourceFileSize: preparedImport.fingerprint.fileSize,
                    sourceFileModifiedAt: preparedImport.fingerprint.modifiedAt
                )
                modelContext.insert(newBook)
                book = newBook
            }

            refreshedBooks.append(book)

            completedApplyOperations += 1
            await reportRefreshProgress(
                RefreshProgress(
                    fractionCompleted: 0.72 + (Double(completedApplyOperations) / Double(totalApplyOperations)) * 0.23,
                    message: "Updating library \(index + 1) of \(preparation.preparedImports.count)"
                ),
                using: progressHandler
            )
        }

        await reportRefreshProgress(
            RefreshProgress(fractionCompleted: 0.97, message: "Saving library..."),
            using: progressHandler
        )
        try modelContext.save()
        await reportRefreshProgress(
            RefreshProgress(fractionCompleted: 1, message: "Refresh complete"),
            using: progressHandler
        )
        return refreshedBooks
    }

    @MainActor
    private static func existingBook(originalFilename: String, modelContext: ModelContext) throws -> Book? {
        var descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { book in
                book.originalFilename == originalFilename
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    @MainActor
    private static func bookForID(_ id: UUID, modelContext: ModelContext) throws -> Book? {
        var descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { book in
                book.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    @MainActor
    private static func applyPreparedImport(
        _ preparedImport: PreparedBookImport,
        existingBookID: UUID?,
        modelContext: ModelContext
    ) throws -> Book {
        let book: Book
        if let existingBookID,
           let existingBook = try bookForID(existingBookID, modelContext: modelContext) {
            existingBook.title = preparedImport.metadata.title ?? displayTitle(for: preparedImport.filename)
            existingBook.author = preparedImport.metadata.author ?? "Unknown Author"
            existingBook.originalFilename = preparedImport.filename
            existingBook.epubFilePath = preparedImport.epubFilePath
            existingBook.extractedDirectoryPath = preparedImport.extractedDirectoryPath
            existingBook.coverImagePath = preparedImport.metadata.coverImagePath
            existingBook.language = preparedImport.metadata.language
            existingBook.metadataIdentifier = preparedImport.metadata.identifier
            existingBook.mediaOverlayJSONPath = preparedImport.mediaOverlayJSONPath
            existingBook.mediaOverlayActiveClass = preparedImport.mediaOverlayActiveClass
            existingBook.mediaOverlayDuration = preparedImport.mediaOverlayDuration
            existingBook.mediaOverlayClipCount = preparedImport.mediaOverlayClipCount
            existingBook.sourceFileSize = preparedImport.fingerprint.fileSize
            existingBook.sourceFileModifiedAt = preparedImport.fingerprint.modifiedAt
            existingBook.importedAt = Date()
            book = existingBook
        } else {
            let newBook = Book(
                id: preparedImport.id,
                title: preparedImport.metadata.title ?? displayTitle(for: preparedImport.filename),
                author: preparedImport.metadata.author ?? "Unknown Author",
                originalFilename: preparedImport.filename,
                epubFilePath: preparedImport.epubFilePath,
                extractedDirectoryPath: preparedImport.extractedDirectoryPath,
                coverImagePath: preparedImport.metadata.coverImagePath,
                language: preparedImport.metadata.language,
                metadataIdentifier: preparedImport.metadata.identifier,
                mediaOverlayJSONPath: preparedImport.mediaOverlayJSONPath,
                mediaOverlayActiveClass: preparedImport.mediaOverlayActiveClass,
                mediaOverlayDuration: preparedImport.mediaOverlayDuration,
                mediaOverlayClipCount: preparedImport.mediaOverlayClipCount,
                sourceFileSize: preparedImport.fingerprint.fileSize,
                sourceFileModifiedAt: preparedImport.fingerprint.modifiedAt
            )
            modelContext.insert(newBook)
            book = newBook
        }

        try modelContext.save()
        return book
    }

    nonisolated private static func prepareImport(
        from sourceURL: URL,
        filename: String,
        existingBook: ExistingBookSnapshot?,
        existingBookStrategy: ExistingBookStrategy,
        bookID: UUID,
        progressHandler: (@MainActor @Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> PreparedBookImport? {
        let stagedLibraryFile = try await stageSourceFileInLibrary(
            from: sourceURL,
            filename: filename,
            progressHandler: progressHandler
        )

        let destinationURL = stagedLibraryFile.fileURL
        let fingerprint = try sourceFileFingerprint(for: destinationURL)
        if existingBookStrategy != .overwrite,
           let existingBook,
           shouldSkipPreparedBook(for: destinationURL, existingBook: existingBook, fingerprint: fingerprint) {
            await reportImportProgress(
                ImportProgress(fractionCompleted: 1, message: "Book already exists, skipping"),
                using: progressHandler
            )
            return nil
        }

        let fileManager = FileManager.default

        do {
            await reportImportProgress(
                ImportProgress(fractionCompleted: 0.24, message: "Validating EPUB..."),
                using: progressHandler
            )
            try EPUBArchive.validateEPUB(at: destinationURL)

            let extractionURL = try AppStorage.extractedDirectory().appendingPathComponent(bookID.uuidString, isDirectory: true)

            try? fileManager.removeItem(at: extractionURL)

            do {
                await reportImportProgress(
                    ImportProgress(fractionCompleted: 0.46, message: "Extracting book..."),
                    using: progressHandler
                )
                try EPUBArchive(url: destinationURL).extract(to: extractionURL)
            } catch {
                if stagedLibraryFile.shouldCleanupOnFailure {
                    try? fileManager.removeItem(at: destinationURL)
                }
                try? fileManager.removeItem(at: extractionURL)
                throw error
            }

            await reportImportProgress(
                ImportProgress(fractionCompleted: 0.82, message: "Reading metadata..."),
                using: progressHandler
            )
            let package = EPUBMetadataService.packageInfo(in: extractionURL)
            let metadata = package.map { EPUBMetadataService.metadata(in: extractionURL, package: $0) } ?? EPUBMetadata()
            let mediaOverlay: EPUBMediaOverlayParseResult?
            if let package {
                mediaOverlay = try? EPUBMediaOverlayService.parseAndWrite(in: extractionURL, package: package)
            } else {
                mediaOverlay = nil
            }

            await reportImportProgress(
                ImportProgress(fractionCompleted: 0.92, message: "Finalizing book..."),
                using: progressHandler
            )
            return PreparedBookImport(
                id: bookID,
                filename: filename,
                epubFilePath: destinationURL.path,
                extractedDirectoryPath: extractionURL.path,
                metadata: metadata,
                mediaOverlayJSONPath: mediaOverlay?.jsonURL.path,
                mediaOverlayActiveClass: mediaOverlay?.manifest.activeClass,
                mediaOverlayDuration: mediaOverlay?.manifest.duration,
                mediaOverlayClipCount: mediaOverlay?.manifest.clipCount,
                fingerprint: fingerprint
            )
        } catch {
            if stagedLibraryFile.shouldCleanupOnFailure {
                try? fileManager.removeItem(at: destinationURL)
            }
            throw error
        }
    }

    nonisolated private static func stageSourceFileInLibrary(
        from sourceURL: URL,
        filename: String,
        progressHandler: (@MainActor @Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> StagedLibraryFile {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let libraryDirectory = try AppStorage.documentsDirectory()
        let destinationURL = libraryDirectory.appendingPathComponent(filename, isDirectory: false)
        let sourcePath = sourceURL.standardizedFileURL.path
        let destinationPath = destinationURL.standardizedFileURL.path

        await reportImportProgress(
            ImportProgress(fractionCompleted: 0.08, message: "Staging EPUB..."),
            using: progressHandler
        )

        guard sourcePath != destinationPath else {
            return StagedLibraryFile(fileURL: destinationURL, shouldCleanupOnFailure: false)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        if shouldMoveUploadedSourceIntoLibrary(sourceURL) {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }

        return StagedLibraryFile(fileURL: destinationURL, shouldCleanupOnFailure: true)
    }

    nonisolated private static func prepareRefresh(
        from urls: [URL],
        existingBooks: [ExistingBookSnapshot],
        progressHandler: (@MainActor @Sendable (RefreshProgress) -> Void)? = nil
    ) async throws -> RefreshPreparation {
        let existingByFilename = Dictionary(uniqueKeysWithValues: existingBooks.map { ($0.originalFilename, $0) })
        let filenamesOnDisk = Set(urls.map { AppStorage.sanitizedFilename($0.lastPathComponent) })
        let removedBookIDs = existingBooks
            .filter { !filenamesOnDisk.contains($0.originalFilename) }
            .map(\.id)

        var preparedImports: [PreparedBookImport] = []
        preparedImports.reserveCapacity(urls.count)

        for (index, sourceURL) in urls.enumerated() {
            let filename = AppStorage.sanitizedFilename(sourceURL.lastPathComponent)
            guard filename.lowercased().hasSuffix(".epub") else {
                throw BookImportError.notEpub(filename)
            }

            let fingerprint = try sourceFileFingerprint(for: sourceURL)
            if let existingBook = existingByFilename[filename],
               shouldSkipPreparedBook(for: sourceURL, existingBook: existingBook, fingerprint: fingerprint) {
                await reportRefreshProgress(
                    RefreshProgress(
                        fractionCompleted: preparationFraction(processedFileCount: index + 1, totalFileCount: urls.count),
                        message: "Preparing book \(index + 1) of \(urls.count)"
                    ),
                    using: progressHandler
                )
                continue
            }

            let bookID = existingByFilename[filename]?.id ?? UUID()
            let extractionURL = try AppStorage.extractedDirectory().appendingPathComponent(bookID.uuidString, isDirectory: true)
            let fileManager = FileManager.default

            try EPUBArchive.validateEPUB(at: sourceURL)
            try? fileManager.removeItem(at: extractionURL)
            do {
                try EPUBArchive(url: sourceURL).extract(to: extractionURL)
            } catch {
                try? fileManager.removeItem(at: extractionURL)
                throw error
            }

            let package = EPUBMetadataService.packageInfo(in: extractionURL)
            let metadata = package.map { EPUBMetadataService.metadata(in: extractionURL, package: $0) } ?? EPUBMetadata()
            let mediaOverlay = package.flatMap { try? EPUBMediaOverlayService.parseAndWrite(in: extractionURL, package: $0) }

            preparedImports.append(PreparedBookImport(
                id: bookID,
                filename: filename,
                epubFilePath: sourceURL.path,
                extractedDirectoryPath: extractionURL.path,
                metadata: metadata,
                mediaOverlayJSONPath: mediaOverlay?.jsonURL.path,
                mediaOverlayActiveClass: mediaOverlay?.manifest.activeClass,
                mediaOverlayDuration: mediaOverlay?.manifest.duration,
                mediaOverlayClipCount: mediaOverlay?.manifest.clipCount,
                fingerprint: fingerprint
            ))

            await reportRefreshProgress(
                RefreshProgress(
                    fractionCompleted: preparationFraction(processedFileCount: index + 1, totalFileCount: urls.count),
                    message: "Preparing book \(index + 1) of \(urls.count)"
                ),
                using: progressHandler
            )
        }

        return RefreshPreparation(preparedImports: preparedImports, removedBookIDs: removedBookIDs)
    }

    nonisolated private static func reportRefreshProgress(
        _ progress: RefreshProgress,
        using progressHandler: (@MainActor @Sendable (RefreshProgress) -> Void)?
    ) async {
        guard let progressHandler else {
            return
        }

        await progressHandler(
            RefreshProgress(
                fractionCompleted: min(max(progress.fractionCompleted, 0), 1),
                message: progress.message
            )
        )
    }

    nonisolated private static func reportImportProgress(
        _ progress: ImportProgress,
        using progressHandler: (@MainActor @Sendable (ImportProgress) -> Void)?
    ) async {
        guard let progressHandler else {
            return
        }

        await progressHandler(
            ImportProgress(
                fractionCompleted: min(max(progress.fractionCompleted, 0), 1),
                message: progress.message
            )
        )
    }

    nonisolated private static func preparationFraction(processedFileCount: Int, totalFileCount: Int) -> Double {
        guard totalFileCount > 0 else {
            return 0.7
        }

        return 0.08 + (Double(processedFileCount) / Double(totalFileCount)) * 0.6
    }

    nonisolated private static func shouldSkipPreparedBook(
        for libraryFileURL: URL,
        existingBook: ExistingBookSnapshot,
        fingerprint: SourceFileFingerprint
    ) -> Bool {
        guard fingerprint.fileSize == existingBook.sourceFileSize,
              existingBook.epubFilePath == libraryFileURL.path,
              FileManager.default.fileExists(atPath: existingBook.epubFilePath),
              FileManager.default.fileExists(atPath: existingBook.extractedDirectoryPath)
        else {
            return false
        }

        if let mediaOverlayJSONPath = existingBook.mediaOverlayJSONPath {
            return FileManager.default.fileExists(atPath: mediaOverlayJSONPath)
        }

        return true
    }

    nonisolated private static func sourceFileFingerprint(for url: URL) throws -> SourceFileFingerprint {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = resourceValues.fileSize.map(Int64.init)
        return SourceFileFingerprint(
            fileSize: fileSize,
            modifiedAt: resourceValues.contentModificationDate
        )
    }

    @MainActor
    private static func snapshot(for book: Book) -> ExistingBookSnapshot {
        ExistingBookSnapshot(
            id: book.id,
            originalFilename: book.originalFilename,
            epubFilePath: book.epubFilePath,
            extractedDirectoryPath: book.extractedDirectoryPath,
            mediaOverlayJSONPath: book.mediaOverlayJSONPath,
            sourceFileSize: book.sourceFileSize,
            sourceFileModifiedAt: book.sourceFileModifiedAt
        )
    }

    nonisolated private static func shouldMoveUploadedSourceIntoLibrary(_ sourceURL: URL) -> Bool {
        guard let uploadsDirectory = try? AppStorage.uploadsDirectory() else {
            return false
        }

        let sourcePath = sourceURL.standardizedFileURL.path
        let uploadsPath = uploadsDirectory.standardizedFileURL.path
        return sourcePath == uploadsPath || sourcePath.hasPrefix(uploadsPath + "/")
    }

    private static func displayTitle(for filename: String) -> String {
        URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
    }
}
