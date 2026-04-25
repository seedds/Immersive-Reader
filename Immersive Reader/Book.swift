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
    var importedAt: Date
    var lastOpenedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        author: String = "Unknown Author",
        originalFilename: String,
        epubFilePath: String,
        extractedDirectoryPath: String,
        importedAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.originalFilename = originalFilename
        self.epubFilePath = epubFilePath
        self.extractedDirectoryPath = extractedDirectoryPath
        self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt
    }
}
