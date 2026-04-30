//
//  CustomFontStore.swift
//  Immersive Reader
//
//  Created by OpenCode on 30/4/2026.
//

import CoreText
import Foundation
import ReadiumNavigator
import ReadiumShared

enum CustomFontStoreError: LocalizedError {
    case unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let filename):
            "Only .ttf and .otf font files are supported. \(filename) can't be imported."
        }
    }
}

enum CustomFontStore {
    struct ImportedFontFamily: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        let displayName: String
        let fontFamily: String
        let importedAt: Date
        var files: [ImportedFontFile]

        var fileCount: Int {
            files.count
        }
    }

    struct ImportedFontFile: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        let storedFilename: String
        let originalFilename: String
        let style: ImportedFontStyle
        let importedAt: Date
    }

    enum ImportedFontStyle: String, Codable, Hashable, Sendable {
        case normal
        case italic

        var cssStyle: CSSFontStyle {
            switch self {
            case .normal:
                .normal
            case .italic:
                .italic
            }
        }

        var label: String {
            switch self {
            case .normal:
                "Regular"
            case .italic:
                "Italic"
            }
        }

        var sortOrder: Int {
            switch self {
            case .normal:
                0
            case .italic:
                1
            }
        }
    }

    private struct DetectedFontMetadata {
        let familyDisplayName: String
        let style: ImportedFontStyle
    }

    static func allFamilies() -> [ImportedFontFamily] {
        synchronizedFamilies().families
    }

    @discardableResult
    static func importFonts(from urls: [URL]) throws -> [ImportedFontFamily] {
        let directory = try AppStorage.customFontsDirectory()
        let fileManager = FileManager.default
        var snapshot = synchronizedFamilies().families
        var changedFamilyIDs = Set<UUID>()

        for sourceURL in urls {
            let originalFilename = AppStorage.sanitizedFilename(sourceURL.lastPathComponent)
            guard isSupportedFontFilename(originalFilename) else {
                throw CustomFontStoreError.unsupportedFile(originalFilename)
            }

            let fileID = UUID()
            let destinationURL = directory.appendingPathComponent(
                internalStoredFilename(for: fileID, pathExtension: pathExtension(for: originalFilename)),
                isDirectory: false
            )

            do {
                let hasAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                try fileManager.copyItem(at: sourceURL, to: destinationURL)

                let metadata = detectedFontMetadata(for: destinationURL, fallbackFilename: originalFilename)
                let importedFile = ImportedFontFile(
                    id: fileID,
                    storedFilename: destinationURL.lastPathComponent,
                    originalFilename: originalFilename,
                    style: metadata.style,
                    importedAt: Date()
                )

                if let familyIndex = snapshot.firstIndex(where: { normalizedFamilyKey($0.displayName) == normalizedFamilyKey(metadata.familyDisplayName) }) {
                    snapshot[familyIndex].files.append(importedFile)
                    changedFamilyIDs.insert(snapshot[familyIndex].id)
                } else {
                    let family = ImportedFontFamily(
                        id: UUID(),
                        displayName: metadata.familyDisplayName,
                        fontFamily: customFontFamilyName(),
                        importedAt: Date(),
                        files: [importedFile]
                    )
                    snapshot.append(family)
                    changedFamilyIDs.insert(family.id)
                }
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
        }

        snapshot = sortedFamilies(snapshot)
        try save(families: snapshot)
        synchronizeSelectedFontFamily(with: snapshot)
        return snapshot.filter { changedFamilyIDs.contains($0.id) }
    }

    static func removeFamilies(withIDs ids: some Sequence<UUID>) throws {
        let idsToRemove = Set(ids)
        guard !idsToRemove.isEmpty else {
            return
        }

        let snapshot = synchronizedFamilies().families
        let removedFiles = snapshot
            .filter { idsToRemove.contains($0.id) }
            .flatMap(\.files)

        try removeStoredFiles(removedFiles)

        let remainingFamilies = snapshot.filter { !idsToRemove.contains($0.id) }
        try save(families: remainingFamilies)
        synchronizeSelectedFontFamily(with: remainingFamilies)
    }

    static func removeFiles(withIDs ids: some Sequence<UUID>) throws {
        let idsToRemove = Set(ids)
        guard !idsToRemove.isEmpty else {
            return
        }

        let snapshot = synchronizedFamilies().families
        let removedFiles = snapshot
            .flatMap(\.files)
            .filter { idsToRemove.contains($0.id) }

        try removeStoredFiles(removedFiles)

        let remainingFamilies = snapshot.compactMap { family -> ImportedFontFamily? in
            let remainingFiles = family.files.filter { !idsToRemove.contains($0.id) }
            guard !remainingFiles.isEmpty else {
                return nil
            }

            var updatedFamily = family
            updatedFamily.files = remainingFiles
            return updatedFamily
        }

        let sortedRemainingFamilies = sortedFamilies(remainingFamilies)
        try save(families: sortedRemainingFamilies)
        synchronizeSelectedFontFamily(with: sortedRemainingFamilies)
    }

    static func fontFamilyDeclarations() -> [AnyHTMLFontFamilyDeclaration] {
        let directory = try? AppStorage.customFontsDirectory()
        return allFamilies().compactMap { family in
            guard let directory else {
                return nil
            }

            let fontFaces = family.files.compactMap { file -> CSSFontFace? in
                let fileURL = directory.appendingPathComponent(file.storedFilename, isDirectory: false)
                guard let readiumFileURL = FileURL(url: fileURL) else {
                    return nil
                }

                return CSSFontFace(file: readiumFileURL, style: file.style.cssStyle)
            }

            guard !fontFaces.isEmpty else {
                return nil
            }

            return CSSFontFamilyDeclaration(
                fontFamily: FontFamily(rawValue: family.fontFamily),
                fontFaces: fontFaces
            )
            .eraseToAnyHTMLFontFamilyDeclaration()
        }
    }

    private static func synchronizedFamilies() -> (families: [ImportedFontFamily], didChange: Bool) {
        let loadedFamilies = (try? loadFamilies()) ?? []
        let directory = try? AppStorage.customFontsDirectory()
        var didChange = false

        let filteredFamilies = loadedFamilies.compactMap { family -> ImportedFontFamily? in
            guard let directory else {
                didChange = true
                return nil
            }

            let remainingFiles = family.files.filter { file in
                let fileURL = directory.appendingPathComponent(file.storedFilename, isDirectory: false)
                return FileManager.default.fileExists(atPath: fileURL.path)
            }

            if remainingFiles.count != family.files.count {
                didChange = true
            }

            guard !remainingFiles.isEmpty else {
                didChange = true
                return nil
            }

            var updatedFamily = family
            updatedFamily.files = remainingFiles
            return updatedFamily
        }

        let sortedFilteredFamilies = sortedFamilies(filteredFamilies)
        if sortedFilteredFamilies != loadedFamilies {
            didChange = true
        }

        if didChange {
            try? save(families: sortedFilteredFamilies)
        }
        synchronizeSelectedFontFamily(with: sortedFilteredFamilies)
        return (sortedFilteredFamilies, didChange)
    }

    private static func loadFamilies() throws -> [ImportedFontFamily] {
        let metadataURL = try AppStorage.customFontsMetadataURL()
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode([ImportedFontFamily].self, from: data)
    }

    private static func save(families: [ImportedFontFamily]) throws {
        let data = try JSONEncoder().encode(families)
        let metadataURL = try AppStorage.customFontsMetadataURL()
        try data.write(to: metadataURL, options: .atomic)
    }

    private static func detectedFontMetadata(for fileURL: URL, fallbackFilename: String) -> DetectedFontMetadata {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fileURL as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first
        else {
            return DetectedFontMetadata(
                familyDisplayName: fallbackFamilyDisplayName(for: fallbackFilename),
                style: fallbackStyle(for: fallbackFilename)
            )
        }

        let rawFamilyDisplayName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
        let familyDisplayName = rawFamilyDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let styleName = (CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String) ?? ""
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolicTraitsValue = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        let symbolicTraits = CTFontSymbolicTraits(rawValue: symbolicTraitsValue)
        let isItalic = symbolicTraits.contains(.traitItalic)
            || styleName.localizedCaseInsensitiveContains("italic")
            || styleName.localizedCaseInsensitiveContains("oblique")

        return DetectedFontMetadata(
            familyDisplayName: (familyDisplayName?.isEmpty == false ? familyDisplayName : fallbackFamilyDisplayName(for: fallbackFilename))
                ?? fallbackFamilyDisplayName(for: fallbackFilename),
            style: isItalic ? .italic : .normal
        )
    }

    private static func fallbackFamilyDisplayName(for filename: String) -> String {
        let baseName = URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
        let suffixes = ["-regular", " regular", "-italic", " italic", "-oblique", " oblique"]

        for suffix in suffixes where baseName.lowercased().hasSuffix(suffix) {
            let trimmed = String(baseName.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return baseName
    }

    private static func fallbackStyle(for filename: String) -> ImportedFontStyle {
        let baseName = URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()

        if baseName.contains("italic") || baseName.contains("oblique") {
            return .italic
        }
        return .normal
    }

    private static func sortedFamilies(_ families: [ImportedFontFamily]) -> [ImportedFontFamily] {
        families
            .map { family in
                var sortedFamily = family
                sortedFamily.files = family.files.sorted { lhs, rhs in
                    if lhs.style.sortOrder != rhs.style.sortOrder {
                        return lhs.style.sortOrder < rhs.style.sortOrder
                    }
                    return lhs.originalFilename.localizedStandardCompare(rhs.originalFilename) == .orderedAscending
                }
                return sortedFamily
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    private static func removeStoredFiles(_ files: [ImportedFontFile]) throws {
        let directory = try AppStorage.customFontsDirectory()
        let fileManager = FileManager.default

        for file in files {
            let fileURL = directory.appendingPathComponent(file.storedFilename, isDirectory: false)
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private static func normalizedFamilyKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pathExtension(for filename: String, fallbackFilename: String? = nil) -> String {
        let filenameExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if !filenameExtension.isEmpty {
            return filenameExtension
        }

        guard let fallbackFilename else {
            return ""
        }
        return URL(fileURLWithPath: fallbackFilename).pathExtension.lowercased()
    }

    private static func internalStoredFilename(for fileID: UUID, pathExtension: String) -> String {
        let normalizedExtension = pathExtension.lowercased()
        let basename = fileID.uuidString.lowercased()
        guard !normalizedExtension.isEmpty else {
            return basename
        }
        return "\(basename).\(normalizedExtension)"
    }

    private static func customFontFamilyName() -> String {
        "custom-font-\(UUID().uuidString.lowercased())"
    }

    private static func isSupportedFontFilename(_ filename: String) -> Bool {
        let pathExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return pathExtension == "ttf" || pathExtension == "otf"
    }

    private static func synchronizeSelectedFontFamily(with families: [ImportedFontFamily]) {
        let defaults = UserDefaults.standard
        let selectedFontFamily = defaults.string(forKey: ReaderSettings.fontFamilyKey) ?? ""
        guard selectedFontFamily.hasPrefix("custom-font-") else {
            return
        }

        if families.contains(where: { $0.fontFamily == selectedFontFamily }) {
            return
        }

        defaults.set("", forKey: ReaderSettings.fontFamilyKey)
    }
}
