//
//  EPUBMetadataService.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation

struct EPUBMetadata {
    var title: String?
    var author: String?
    var language: String?
    var identifier: String?
    var coverImagePath: String?

    nonisolated init(
        title: String? = nil,
        author: String? = nil,
        language: String? = nil,
        identifier: String? = nil,
        coverImagePath: String? = nil
    ) {
        self.title = title
        self.author = author
        self.language = language
        self.identifier = identifier
        self.coverImagePath = coverImagePath
    }
}

struct EPUBPackageInfo {
    struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String?
        let mediaOverlay: String?
        let properties: Set<String>

        nonisolated init(id: String, href: String, mediaType: String?, mediaOverlay: String?, properties: Set<String>) {
            self.id = id
            self.href = href
            self.mediaType = mediaType
            self.mediaOverlay = mediaOverlay
            self.properties = properties
        }
    }

    var packageURL: URL
    var title: String?
    var creator: String?
    var language: String?
    var identifier: String?
    var coverItemId: String?
    var mediaActiveClass: String?
    var mediaPlaybackActiveClass: String?
    var mediaDuration: Double?
    var mediaNarrator: String?
    var manifestItems: [ManifestItem] = []

    nonisolated init(
        packageURL: URL,
        title: String? = nil,
        creator: String? = nil,
        language: String? = nil,
        identifier: String? = nil,
        coverItemId: String? = nil,
        mediaActiveClass: String? = nil,
        mediaPlaybackActiveClass: String? = nil,
        mediaDuration: Double? = nil,
        mediaNarrator: String? = nil,
        manifestItems: [ManifestItem] = []
    ) {
        self.packageURL = packageURL
        self.title = title
        self.creator = creator
        self.language = language
        self.identifier = identifier
        self.coverItemId = coverItemId
        self.mediaActiveClass = mediaActiveClass
        self.mediaPlaybackActiveClass = mediaPlaybackActiveClass
        self.mediaDuration = mediaDuration
        self.mediaNarrator = mediaNarrator
        self.manifestItems = manifestItems
    }
}

enum EPUBMetadataService {
    nonisolated static func metadata(in extractedDirectory: URL) -> EPUBMetadata {
        guard let package = packageInfo(in: extractedDirectory) else {
            return EPUBMetadata()
        }

        return metadata(in: extractedDirectory, package: package)
    }

    nonisolated static func metadata(in extractedDirectory: URL, package: EPUBPackageInfo) -> EPUBMetadata {
        let coverPath = coverImagePath(
            in: package,
            extractedDirectory: extractedDirectory
        )

        return EPUBMetadata(
            title: clean(package.title),
            author: clean(package.creator),
            language: clean(package.language),
            identifier: clean(package.identifier),
            coverImagePath: coverPath
        )
    }

    nonisolated static func packageInfo(in extractedDirectory: URL) -> EPUBPackageInfo? {
        guard let packageURL = packageDocumentURL(in: extractedDirectory) else {
            return nil
        }

        let parser = OPFParser(packageURL: packageURL)
        return parser.parse(url: packageURL)
    }

    nonisolated static func resolvedURL(for href: String, relativeTo baseURL: URL, root: URL) -> URL? {
        let stripped = href.components(separatedBy: "#").first?.components(separatedBy: "?").first ?? href
        guard !stripped.isEmpty, !stripped.hasPrefix("/"), !stripped.hasPrefix("~") else {
            return nil
        }

        let decoded = stripped.removingPercentEncoding ?? stripped
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        let url = components.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return url
    }

    nonisolated private static func packageDocumentURL(in extractedDirectory: URL) -> URL? {
        let containerURL = extractedDirectory
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml", isDirectory: false)

        let parser = ContainerParser()
        guard let fullPath = parser.parse(url: containerURL) else {
            return nil
        }

        return resolvedURL(for: fullPath, relativeTo: extractedDirectory, root: extractedDirectory)
    }

    nonisolated private static func coverImagePath(in package: EPUBPackageInfo, extractedDirectory: URL) -> String? {
        let coverItem = package.manifestItems.first { item in
            item.properties.contains("cover-image")
        } ?? package.manifestItems.first { item in
            package.coverItemId != nil && item.id == package.coverItemId
        }

        guard let href = coverItem?.href else {
            return nil
        }

        let packageDirectory = package.packageURL.deletingLastPathComponent()
        return resolvedURL(for: href, relativeTo: packageDirectory, root: extractedDirectory)?.path
    }

    nonisolated private static func clean(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }
}

nonisolated private final class ContainerParser: NSObject, XMLParserDelegate {
    private var fullPath: String?

    nonisolated override init() {
        super.init()
    }

    nonisolated func parse(url: URL) -> String? {
        guard let parser = XMLParser(contentsOf: url) else {
            return nil
        }
        parser.delegate = self
        parser.parse()
        return fullPath
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard localName(elementName) == "rootfile", fullPath == nil else {
            return
        }
        fullPath = attributeDict["full-path"]
    }
}

nonisolated private final class OPFParser: NSObject, XMLParserDelegate {
    private var package: EPUBPackageInfo
    private var currentMetadataElement: String?
    private var currentText = ""

    nonisolated init(packageURL: URL) {
        package = EPUBPackageInfo(packageURL: packageURL)
    }

    nonisolated func parse(url: URL) -> EPUBPackageInfo? {
        guard let parser = XMLParser(contentsOf: url) else {
            return nil
        }
        parser.delegate = self
        parser.parse()
        return package
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)

        switch name {
        case "title", "creator", "language", "identifier":
            currentMetadataElement = name
            currentText = ""

        case "meta":
            if attributeDict["name"] == "cover", let content = attributeDict["content"] {
                package.coverItemId = content
            }
            if attributeDict["property"] == "media:active-class" {
                currentMetadataElement = "media:active-class"
                currentText = ""
            } else if attributeDict["property"] == "media:playback-active-class" {
                currentMetadataElement = "media:playback-active-class"
                currentText = ""
            } else if attributeDict["property"] == "media:duration" {
                currentMetadataElement = "media:duration"
                currentText = ""
            } else if attributeDict["property"] == "media:narrator" {
                currentMetadataElement = "media:narrator"
                currentText = ""
            }

        case "item":
            guard let id = attributeDict["id"], let href = attributeDict["href"] else {
                return
            }
            let properties = Set((attributeDict["properties"] ?? "").split(separator: " ").map(String.init))
            package.manifestItems.append(EPUBPackageInfo.ManifestItem(
                id: id,
                href: href,
                mediaType: attributeDict["media-type"],
                mediaOverlay: attributeDict["media-overlay"],
                properties: properties
            ))

        default:
            break
        }
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentMetadataElement != nil else {
            return
        }
        currentText += string
    }

    nonisolated func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        guard currentMetadataElement == name || (name == "meta" && currentMetadataElement?.hasPrefix("media:") == true) else {
            return
        }

        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            switch currentMetadataElement {
            case "title" where package.title == nil:
                package.title = text
            case "creator" where package.creator == nil:
                package.creator = text
            case "language" where package.language == nil:
                package.language = text
            case "identifier" where package.identifier == nil:
                package.identifier = text
            case "media:active-class":
                package.mediaActiveClass = text
            case "media:playback-active-class":
                package.mediaPlaybackActiveClass = text
            case "media:duration":
                package.mediaDuration = EPUBMediaOverlayTimeParser.seconds(from: text)
            case "media:narrator":
                package.mediaNarrator = text
            default:
                break
            }
        }

        currentMetadataElement = nil
        currentText = ""
    }
}

nonisolated private func localName(_ elementName: String) -> String {
    elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
}
