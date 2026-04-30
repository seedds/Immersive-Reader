//
//  Book.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import SwiftData

struct NormalizedBookStoragePaths: Equatable {
    let epubFilePath: String
    let extractedDirectoryPath: String
    let coverImagePath: String?
    let mediaOverlayJSONPath: String?
}

@Model
final class Book {
    var id: UUID
    var title: String
    var author: String
    var originalFilename: String
    var epubFilePath: String
    var extractedDirectoryPath: String = ""
    var coverImagePath: String?
    var language: String?
    var metadataIdentifier: String?
    var lastLocatorJSON: String?
    var lastPlayedTextResourceHref: String?
    var lastPlayedFragmentID: String?
    var lastPlayedClipBegin: Double?
    var lastPlayedClipEnd: Double?
    var mediaOverlayJSONPath: String?
    var mediaOverlayActiveClass: String?
    var mediaOverlayDuration: Double?
    var mediaOverlayClipCount: Int?
    var sourceFileSize: Int64?
    var sourceFileModifiedAt: Date?
    var importedAt: Date
    var lastOpenedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        author: String = "Unknown Author",
        originalFilename: String,
        epubFilePath: String,
        extractedDirectoryPath: String,
        coverImagePath: String? = nil,
        language: String? = nil,
        metadataIdentifier: String? = nil,
        lastLocatorJSON: String? = nil,
        lastPlayedTextResourceHref: String? = nil,
        lastPlayedFragmentID: String? = nil,
        lastPlayedClipBegin: Double? = nil,
        lastPlayedClipEnd: Double? = nil,
        mediaOverlayJSONPath: String? = nil,
        mediaOverlayActiveClass: String? = nil,
        mediaOverlayDuration: Double? = nil,
        mediaOverlayClipCount: Int? = nil,
        sourceFileSize: Int64? = nil,
        sourceFileModifiedAt: Date? = nil,
        importedAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.originalFilename = originalFilename
        self.epubFilePath = epubFilePath
        self.extractedDirectoryPath = extractedDirectoryPath
        self.coverImagePath = coverImagePath
        self.language = language
        self.metadataIdentifier = metadataIdentifier
        self.lastLocatorJSON = lastLocatorJSON
        self.lastPlayedTextResourceHref = lastPlayedTextResourceHref
        self.lastPlayedFragmentID = lastPlayedFragmentID
        self.lastPlayedClipBegin = lastPlayedClipBegin
        self.lastPlayedClipEnd = lastPlayedClipEnd
        self.mediaOverlayJSONPath = mediaOverlayJSONPath
        self.mediaOverlayActiveClass = mediaOverlayActiveClass
        self.mediaOverlayDuration = mediaOverlayDuration
        self.mediaOverlayClipCount = mediaOverlayClipCount
        self.sourceFileSize = sourceFileSize
        self.sourceFileModifiedAt = sourceFileModifiedAt
        self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

extension Book {
    nonisolated var normalizedStoragePaths: NormalizedBookStoragePaths {
        let normalizedEPUBPath = AppStorage.sanitizedFilename(
            originalFilename.isEmpty ? URL(fileURLWithPath: epubFilePath).lastPathComponent : originalFilename
        )
        let normalizedExtractedDirectoryPath = id.uuidString

        return NormalizedBookStoragePaths(
            epubFilePath: normalizedEPUBPath,
            extractedDirectoryPath: normalizedExtractedDirectoryPath,
            coverImagePath: normalizedExtractedSubpath(for: coverImagePath),
            mediaOverlayJSONPath: normalizedExtractedSubpath(for: mediaOverlayJSONPath)
        )
    }

    nonisolated func resolvedEPUBFileURL() throws -> URL {
        try AppStorage.bookFileURL(named: normalizedStoragePaths.epubFilePath)
    }

    nonisolated func resolvedExtractedDirectoryURL() throws -> URL {
        try AppStorage.extractedDirectory(for: id)
    }

    nonisolated func resolvedCoverImageURL() throws -> URL? {
        guard let relativePath = normalizedStoragePaths.coverImagePath else {
            return nil
        }
        return try resolvedExtractedDirectoryURL().appendingPathComponent(relativePath, isDirectory: false)
    }

    nonisolated func resolvedMediaOverlayJSONURL() throws -> URL? {
        guard let relativePath = normalizedStoragePaths.mediaOverlayJSONPath else {
            return nil
        }
        return try resolvedExtractedDirectoryURL().appendingPathComponent(relativePath, isDirectory: false)
    }

    nonisolated private func normalizedExtractedSubpath(for path: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }

        if path.hasPrefix("/") {
            if let relativePath = AppStorage.relativePath(from: path, under: extractedDirectoryPath) {
                return relativePath
            }
            return URL(fileURLWithPath: path).lastPathComponent
        }

        return path
    }
}
