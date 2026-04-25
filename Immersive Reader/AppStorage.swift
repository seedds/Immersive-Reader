//
//  AppStorage.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation

enum AppStorage {
    nonisolated static func rootDirectory() throws -> URL {
        let documentsDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try ensureDirectory(documentsDirectory.appendingPathComponent("Immersive Reader", isDirectory: true))
    }

    nonisolated static func epubsDirectory() throws -> URL {
        try ensureDirectory(rootDirectory().appendingPathComponent("EPUBs", isDirectory: true))
    }

    nonisolated static func uploadsDirectory() throws -> URL {
        try ensureDirectory(rootDirectory().appendingPathComponent("Uploads", isDirectory: true))
    }

    nonisolated static func extractedDirectory() throws -> URL {
        try ensureDirectory(rootDirectory().appendingPathComponent("Extracted", isDirectory: true))
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

    nonisolated private static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
