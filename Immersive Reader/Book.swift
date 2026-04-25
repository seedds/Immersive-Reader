//
//  Book.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import SwiftData

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
