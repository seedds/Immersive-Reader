//
//  AppStorage.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation

enum AppStorage {
    nonisolated static func documentsDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    nonisolated static func applicationSupportDirectory() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try ensureDirectory(supportDirectory.appendingPathComponent("Immersive Reader", isDirectory: true))
    }

    nonisolated static func uploadsDirectory() throws -> URL {
        try ensureDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("Immersive Reader", isDirectory: true)
                .appendingPathComponent("Uploads", isDirectory: true)
        )
    }

    nonisolated static func extractedDirectory() throws -> URL {
        try ensureDirectory(applicationSupportDirectory().appendingPathComponent("Extracted", isDirectory: true))
    }

    nonisolated static func customFontsDirectory() throws -> URL {
        try ensureDirectory(applicationSupportDirectory().appendingPathComponent("CustomFonts", isDirectory: true))
    }

    nonisolated static func customFontsMetadataURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("custom-fonts.json", isDirectory: false)
    }

    nonisolated static func bookFileURL(named filename: String) throws -> URL {
        try documentsDirectory().appendingPathComponent(sanitizedFilename(filename), isDirectory: false)
    }

    nonisolated static func extractedDirectory(for bookID: UUID) throws -> URL {
        try extractedDirectory().appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    nonisolated static func sanitizedFilename(_ filename: String) -> String {
        let fallback = "upload.epub"
        let basename = URL(fileURLWithPath: filename).lastPathComponent
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()[]"))
        let sanitized = basename.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        let result = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }

    nonisolated static func uniqueFileURL(named filename: String, in directory: URL) -> URL {
        let sanitized = sanitizedFilename(filename)
        let base = URL(fileURLWithPath: sanitized).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: sanitized).pathExtension
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(sanitized)
        var index = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let indexedName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(indexedName)
            index += 1
        }

        return candidate
    }

    nonisolated static func relativePath(from absolutePath: String, under directoryPath: String) -> String? {
        guard absolutePath.hasPrefix("/"), directoryPath.hasPrefix("/") else {
            return nil
        }

        let absoluteURL = URL(fileURLWithPath: absolutePath).standardizedFileURL
        let directoryURL = URL(fileURLWithPath: directoryPath).standardizedFileURL
        let absolute = absoluteURL.path
        let directory = directoryURL.path

        guard absolute != directory, absolute.hasPrefix(directory + "/") else {
            return nil
        }

        return String(absolute.dropFirst(directory.count + 1))
    }

    nonisolated private static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
