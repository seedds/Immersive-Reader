//
//  EPUBMediaOverlayService.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation

struct EPUBMediaOverlayManifest: Codable {
    var activeClass: String?
    var playbackActiveClass: String?
    var narrator: String?
    var duration: Double?
    var documents: [EPUBMediaOverlayDocument]

    var clipCount: Int {
        documents.reduce(0) { $0 + $1.clips.count }
    }
}

struct EPUBMediaOverlayDocument: Codable {
    var smilHref: String
    var smilPath: String
    var associatedContentHref: String?
    var clips: [EPUBMediaOverlayClip]
}

struct EPUBMediaOverlayClip: Codable {
    var textHref: String
    var textResourceHref: String
    var fragmentID: String?
    var audioHref: String
    var audioPath: String
    var clipBegin: Double
    var clipEnd: Double?

    var duration: Double? {
        guard let clipEnd else { return nil }
        return max(0, clipEnd - clipBegin)
    }
}

struct EPUBMediaOverlayParseResult {
    var manifest: EPUBMediaOverlayManifest
    var jsonURL: URL
}

enum EPUBMediaOverlayService {
    static func parseAndWrite(in extractedDirectory: URL, package: EPUBPackageInfo) throws -> EPUBMediaOverlayParseResult? {
        guard let manifest = parse(in: extractedDirectory, package: package), manifest.clipCount > 0 else {
            return nil
        }

        let jsonURL = extractedDirectory.appendingPathComponent("media-overlays.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: jsonURL, options: .atomic)

        return EPUBMediaOverlayParseResult(manifest: manifest, jsonURL: jsonURL)
    }

    private static func parse(in extractedDirectory: URL, package: EPUBPackageInfo) -> EPUBMediaOverlayManifest? {
        let packageDirectory = package.packageURL.deletingLastPathComponent()
        let smilItemsById = Dictionary(uniqueKeysWithValues: package.manifestItems.compactMap { item in
            isSMIL(item) ? (item.id, item) : nil
        })

        var candidates: [(contentItem: EPUBPackageInfo.ManifestItem?, smilItem: EPUBPackageInfo.ManifestItem)] = []

        for item in package.manifestItems {
            guard let mediaOverlay = item.mediaOverlay, let smilItem = smilItemsById[mediaOverlay] else {
                continue
            }
            candidates.append((item, smilItem))
        }

        if candidates.isEmpty {
            candidates = smilItemsById.values.map { (nil, $0) }
        }

        let documents = candidates.compactMap { contentItem, smilItem -> EPUBMediaOverlayDocument? in
            guard let smilURL = EPUBMetadataService.resolvedURL(
                for: smilItem.href,
                relativeTo: packageDirectory,
                root: extractedDirectory
            ) else {
                return nil
            }

            let parser = SMILParser(
                extractedDirectory: extractedDirectory,
                smilURL: smilURL
            )
            let clips = parser.parse()
            guard !clips.isEmpty else {
                return nil
            }

            return EPUBMediaOverlayDocument(
                smilHref: relativePath(for: smilURL, root: extractedDirectory) ?? smilItem.href,
                smilPath: smilURL.path,
                associatedContentHref: contentItem?.href,
                clips: clips
            )
        }

        guard !documents.isEmpty else {
            return nil
        }

        return EPUBMediaOverlayManifest(
            activeClass: package.mediaActiveClass,
            playbackActiveClass: package.mediaPlaybackActiveClass,
            narrator: package.mediaNarrator,
            duration: package.mediaDuration,
            documents: documents
        )
    }

    private static func isSMIL(_ item: EPUBPackageInfo.ManifestItem) -> Bool {
        item.mediaType == "application/smil+xml" || item.href.lowercased().hasSuffix(".smil")
    }

    fileprivate static func relativePath(for url: URL, root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

enum EPUBMediaOverlayTimeParser {
    static func seconds(from value: String?) -> Double? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        text = text.replacingOccurrences(of: ",", with: ".")

        if text.hasSuffix("ms") {
            let number = text.dropLast(2)
            return Double(number).map { $0 / 1000 }
        }

        if text.hasSuffix("s") {
            let number = text.dropLast()
            return Double(number)
        }

        if text.hasSuffix("min") {
            let number = text.dropLast(3)
            return Double(number).map { $0 * 60 }
        }

        if text.hasSuffix("h") {
            let number = text.dropLast()
            return Double(number).map { $0 * 3600 }
        }

        let parts = text.split(separator: ":").map(String.init)
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        case 3:
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        default:
            return nil
        }
    }
}

private final class SMILParser: NSObject, XMLParserDelegate {
    private struct ParBuilder {
        var textSource: String?
        var audioSource: String?
        var clipBegin: Double = 0
        var clipEnd: Double?
    }

    private let extractedDirectory: URL
    private let smilURL: URL
    private var parStack: [ParBuilder] = []
    private var clips: [EPUBMediaOverlayClip] = []

    init(extractedDirectory: URL, smilURL: URL) {
        self.extractedDirectory = extractedDirectory
        self.smilURL = smilURL
    }

    func parse() -> [EPUBMediaOverlayClip] {
        guard let parser = XMLParser(contentsOf: smilURL) else {
            return []
        }
        parser.delegate = self
        parser.parse()
        return clips
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "par":
            parStack.append(ParBuilder())
        case "text":
            guard !parStack.isEmpty else { return }
            parStack[parStack.count - 1].textSource = attributeDict["src"]
        case "audio":
            guard !parStack.isEmpty else { return }
            parStack[parStack.count - 1].audioSource = attributeDict["src"]
            parStack[parStack.count - 1].clipBegin = EPUBMediaOverlayTimeParser.seconds(
                from: attributeDict["clipBegin"] ?? attributeDict["clip-begin"]
            ) ?? 0
            parStack[parStack.count - 1].clipEnd = EPUBMediaOverlayTimeParser.seconds(
                from: attributeDict["clipEnd"] ?? attributeDict["clip-end"]
            )
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard localName(elementName) == "par", let builder = parStack.popLast(), let clip = makeClip(from: builder) else {
            return
        }
        clips.append(clip)
    }

    private func makeClip(from builder: ParBuilder) -> EPUBMediaOverlayClip? {
        guard let textSource = builder.textSource,
              let audioSource = builder.audioSource,
              let textReference = resolveReference(textSource),
              let audioReference = resolveReference(audioSource)
        else {
            return nil
        }

        return EPUBMediaOverlayClip(
            textHref: textReference.href,
            textResourceHref: textReference.resourceHref,
            fragmentID: textReference.fragmentID,
            audioHref: audioReference.resourceHref,
            audioPath: audioReference.fileURL.path,
            clipBegin: builder.clipBegin,
            clipEnd: builder.clipEnd
        )
    }

    private func resolveReference(_ href: String) -> (href: String, resourceHref: String, fragmentID: String?, fileURL: URL)? {
        let fragmentID = fragment(from: href)
        let smilDirectory = smilURL.deletingLastPathComponent()
        guard let fileURL = EPUBMetadataService.resolvedURL(
            for: href,
            relativeTo: smilDirectory,
            root: extractedDirectory
        ), let resourceHref = EPUBMediaOverlayService.relativePath(for: fileURL, root: extractedDirectory) else {
            return nil
        }

        let fullHref = fragmentID.map { "\(resourceHref)#\($0)" } ?? resourceHref
        return (fullHref, resourceHref, fragmentID, fileURL)
    }

    private func fragment(from href: String) -> String? {
        if let hashIndex = href.lastIndex(of: "#") {
            return String(href[href.index(after: hashIndex)...])
        }

        if let encodedRange = href.range(of: "%23", options: .backwards) {
            return String(href[encodedRange.upperBound...])
        }

        return nil
    }
}

private func localName(_ elementName: String) -> String {
    elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
}
