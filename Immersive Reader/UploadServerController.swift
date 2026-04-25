//
//  UploadServerController.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import Darwin
import Combine
import SwiftData

enum LocalLibraryError: LocalizedError {
    case bookNotFound
    case duplicateFilename(String)
    case invalidFilename

    var errorDescription: String? {
        switch self {
        case .bookNotFound:
            "The selected book could not be found."
        case .duplicateFilename(let filename):
            "A book named \(filename) already exists."
        case .invalidFilename:
            "Enter a valid EPUB filename."
        }
    }
}

@MainActor
final class UploadServerController: ObservableObject {
    enum Status: Equatable {
        case stopped
        case running
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .running: "Running"
            case .failed: "Failed"
            }
        }
    }

    struct UploadRecord: Identifiable {
        let id = UUID()
        let filename: String
        let date: Date
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var recentUploads: [UploadRecord] = []
    @Published var port: UInt16 = 8080

    private var server: LocalUploadServer?

    var serverURL: URL? {
        guard case .running = status, let ipAddress = Self.localIPAddress() else {
            return nil
        }
        return URL(string: "http://\(ipAddress):\(port)")
    }

    func start(modelContext: ModelContext) {
        guard server == nil else { return }

        let server = LocalUploadServer(port: port)
        server.onUploadFinished = { [weak self] fileURL, filename in
            Task { @MainActor in
                do {
                    defer { try? FileManager.default.removeItem(at: fileURL) }
                    try BookImportService.importBooks(from: [fileURL], modelContext: modelContext)
                    self?.recentUploads.insert(UploadRecord(filename: filename, date: Date()), at: 0)
                } catch {
                    try? FileManager.default.removeItem(at: fileURL)
                    self?.status = .failed(error.localizedDescription)
                }
            }
        }
        server.onBooksRequested = { [weak self] completion in
            Task { @MainActor in
                do {
                    guard let self else { throw LocalLibraryError.bookNotFound }
                    completion(.success(try self.booksJSON(modelContext: modelContext)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        server.onRenameRequested = { [weak self] bookId, filename, completion in
            Task { @MainActor in
                do {
                    guard let self else { throw LocalLibraryError.bookNotFound }
                    try self.renameBook(id: bookId, to: filename, modelContext: modelContext)
                    completion(.success(try self.booksJSON(modelContext: modelContext)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        server.onDeleteRequested = { [weak self] bookId, completion in
            Task { @MainActor in
                do {
                    guard let self else { throw LocalLibraryError.bookNotFound }
                    try self.deleteBook(id: bookId, modelContext: modelContext)
                    completion(.success(try self.booksJSON(modelContext: modelContext)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        server.onError = { [weak self] message in
            Task { @MainActor in
                self?.status = .failed(message)
            }
        }

        do {
            try server.start()
            self.server = server
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .stopped
    }

    private func booksJSON(modelContext: ModelContext) throws -> Data {
        let descriptor = FetchDescriptor<Book>(
            sortBy: [SortDescriptor(\Book.importedAt, order: .reverse)]
        )
        let books = try modelContext.fetch(descriptor)
        let fileManager = FileManager.default
        let dateFormatter = ISO8601DateFormatter()

        let payload = books.map { book -> [String: Any] in
            let attributes = try? fileManager.attributesOfItem(atPath: book.epubFilePath)
            let fileSize = attributes?[.size] as? Int64 ?? 0
            return [
                "id": book.id.uuidString,
                "title": book.title,
                "author": book.author,
                "filename": book.originalFilename,
                "importedAt": dateFormatter.string(from: book.importedAt),
                "fileSize": fileSize,
                "hasMediaOverlay": (book.mediaOverlayClipCount ?? 0) > 0,
                "mediaOverlayClipCount": book.mediaOverlayClipCount ?? 0,
            ]
        }

        return try JSONSerialization.data(withJSONObject: ["books": payload], options: [])
    }

    private func renameBook(id: UUID, to requestedFilename: String, modelContext: ModelContext) throws {
        let book = try findBook(id: id, modelContext: modelContext)
        let filename = epubFilename(from: requestedFilename)
        guard !filename.isEmpty else {
            throw LocalLibraryError.invalidFilename
        }

        let fileManager = FileManager.default
        let libraryDirectory = try AppStorage.documentsDirectory()
        let destinationURL = libraryDirectory.appendingPathComponent(filename, isDirectory: false)
        let sourceURL = URL(fileURLWithPath: book.epubFilePath)

        if destinationURL.path != sourceURL.path, fileManager.fileExists(atPath: destinationURL.path) {
            throw LocalLibraryError.duplicateFilename(filename)
        }

        if destinationURL.path != sourceURL.path {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }

        let previousDisplayTitle = displayTitle(for: book.originalFilename)
        book.originalFilename = filename
        if book.title == previousDisplayTitle {
            book.title = displayTitle(for: filename)
        }
        book.epubFilePath = destinationURL.path
        try modelContext.save()
    }

    private func deleteBook(id: UUID, modelContext: ModelContext) throws {
        let book = try findBook(id: id, modelContext: modelContext)
        try? FileManager.default.removeItem(atPath: book.epubFilePath)
        try? FileManager.default.removeItem(atPath: book.extractedDirectoryPath)
        modelContext.delete(book)
        try modelContext.save()
    }

    private func findBook(id: UUID, modelContext: ModelContext) throws -> Book {
        let descriptor = FetchDescriptor<Book>()
        guard let book = try modelContext.fetch(descriptor).first(where: { $0.id == id }) else {
            throw LocalLibraryError.bookNotFound
        }
        return book
    }

    private func epubFilename(from filename: String) -> String {
        let sanitized = AppStorage.sanitizedFilename(filename)
        if sanitized.lowercased().hasSuffix(".epub") {
            return sanitized
        }
        return "\(sanitized).epub"
    }

    private func displayTitle(for filename: String) -> String {
        URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func localIPAddress() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        for interface in sequence(first: firstInterface, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback else { continue }

            let addr = interface.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var socketAddress = addr
            let result = getnameinfo(
                &socketAddress,
                socklen_t(socketAddress.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                address = String(cString: hostname)
                break
            }
        }

        return address
    }
}
