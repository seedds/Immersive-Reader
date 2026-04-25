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
}

enum EPUBMetadataService {
    static func metadata(in extractedDirectory: URL) -> EPUBMetadata {
        guard let packageURL = packageDocumentURL(in: extractedDirectory) else {
            return EPUBMetadata()
        }

        let parser = OPFParser()
        guard let package = parser.parse(url: packageURL) else {
            return EPUBMetadata()
        }

        let coverPath = coverImagePath(
            in: package,
            packageURL: packageURL,
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

    private static func packageDocumentURL(in extractedDirectory: URL) -> URL? {
        let containerURL = extractedDirectory
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml", isDirectory: false)

        let parser = ContainerParser()
        guard let fullPath = parser.parse(url: containerURL) else {
            return nil
        }

        return resolvedURL(for: fullPath, relativeTo: extractedDirectory, root: extractedDirectory)
    }

    private static func coverImagePath(in package: OPFPackage, packageURL: URL, extractedDirectory: URL) -> String? {
        let coverItem = package.manifestItems.first { item in
            item.properties.contains("cover-image")
        } ?? package.manifestItems.first { item in
            package.coverItemId != nil && item.id == package.coverItemId
        }

        guard let href = coverItem?.href else {
            return nil
        }

        let packageDirectory = packageURL.deletingLastPathComponent()
        return resolvedURL(for: href, relativeTo: packageDirectory, root: extractedDirectory)?.path
    }

    private static func resolvedURL(for href: String, relativeTo baseURL: URL, root: URL) -> URL? {
        let stripped = href.components(separatedBy: "#").first?.components(separatedBy: "?").first ?? href
        guard !stripped.isEmpty, !stripped.hasPrefix("/"), !stripped.hasPrefix("~") else {
            return nil
        }

        let decoded = stripped.removingPercentEncoding ?? stripped
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains("..") else {
            return nil
        }

        let url = components.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return url
    }

    private static func clean(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }
}

private struct OPFPackage {
    struct ManifestItem {
        let id: String
        let href: String
        let properties: Set<String>
    }

    var title: String?
    var creator: String?
    var language: String?
    var identifier: String?
    var coverItemId: String?
    var manifestItems: [ManifestItem] = []
}

private final class ContainerParser: NSObject, XMLParserDelegate {
    private var fullPath: String?

    func parse(url: URL) -> String? {
        guard let parser = XMLParser(contentsOf: url) else {
            return nil
        }
        parser.delegate = self
        parser.parse()
        return fullPath
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard localName(elementName) == "rootfile", fullPath == nil else {
            return
        }
        fullPath = attributeDict["full-path"]
    }
}

private final class OPFParser: NSObject, XMLParserDelegate {
    private var package = OPFPackage()
    private var currentMetadataElement: String?
    private var currentText = ""

    func parse(url: URL) -> OPFPackage? {
        guard let parser = XMLParser(contentsOf: url) else {
            return nil
        }
        parser.delegate = self
        parser.parse()
        return package
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)

        switch name {
        case "title", "creator", "language", "identifier":
            currentMetadataElement = name
            currentText = ""

        case "meta":
            if attributeDict["name"] == "cover", let content = attributeDict["content"] {
                package.coverItemId = content
            }

        case "item":
            guard let id = attributeDict["id"], let href = attributeDict["href"] else {
                return
            }
            let properties = Set((attributeDict["properties"] ?? "").split(separator: " ").map(String.init))
            package.manifestItems.append(OPFPackage.ManifestItem(id: id, href: href, properties: properties))

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentMetadataElement != nil else {
            return
        }
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard currentMetadataElement == localName(elementName) else {
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
            default:
                break
            }
        }

        currentMetadataElement = nil
        currentText = ""
    }
}

private func localName(_ elementName: String) -> String {
    elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
}
