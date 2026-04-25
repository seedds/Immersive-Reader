//
//  ContentView.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var uploadServer = UploadServerController()

    var body: some View {
        TabView {
            BooksView()
                .tabItem {
                    Label("Books", systemImage: "books.vertical")
                }

            UploadView(controller: uploadServer)
                .tabItem {
                    Label("Upload", systemImage: "network")
                }

            SettingsPlaceholderView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

private struct BooksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.importedAt, order: .reverse) private var books: [Book]

    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView {
                        Label("No EPUB Books", systemImage: "book.closed")
                    } description: {
                        Text("Import EPUB3 books to start building your read-aloud library.")
                    } actions: {
                        Button("Import EPUB") {
                            isImporting = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(books) { book in
                            NavigationLink {
                                ReaderView(book: book)
                            } label: {
                                BookRow(book: book)
                            }
                        }
                        .onDelete(perform: deleteBooks)
                    }
                }
            }
            .navigationTitle("Books")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import EPUB", systemImage: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.epub],
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { isPresented in
                        if !isPresented {
                            importError = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "Unknown error")
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            try BookImportService.importBooks(from: urls, modelContext: modelContext)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func deleteBooks(at offsets: IndexSet) {
        let fileManager = FileManager.default

        for index in offsets {
            let book = books[index]
            try? fileManager.removeItem(atPath: book.epubFilePath)
            try? fileManager.removeItem(atPath: book.extractedDirectoryPath)
            modelContext.delete(book)
        }

        try? modelContext.save()
    }

}

private struct BookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 14) {
            BookCoverView(book: book)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(book.originalFilename)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Text("Imported \(book.importedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let clipCount = book.mediaOverlayClipCount, clipCount > 0 {
                    Label("Read-aloud ready - \(clipCount) clips", systemImage: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct BookCoverView: View {
    let book: Book

    var body: some View {
        Group {
            if let image = coverImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.blue.gradient)
                    .overlay {
                        Image(systemName: "book.closed.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 52, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
    }

    private var coverImage: UIImage? {
        guard let coverImagePath = book.coverImagePath else {
            return nil
        }
        return UIImage(contentsOfFile: coverImagePath)
    }
}

private struct UploadView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var controller: UploadServerController

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    LabeledContent("Status", value: controller.status.title)

                    if let serverURL = controller.serverURL {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Open this address on another computer on the same Wi-Fi network:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(serverURL.absoluteString)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    } else if case .running = controller.status {
                        Text("Server is running, but no Wi-Fi IP address was found. Make sure this device is connected to the same network as the computer uploading the EPUB.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        switch controller.status {
                        case .running:
                            controller.stop()
                        case .stopped, .failed:
                            controller.start(modelContext: modelContext)
                        }
                    } label: {
                        Text(controller.status == .running ? "Stop Server" : "Start Server")
                    }
                }

                if case .failed(let message) = controller.status {
                    Section("Error") {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }

                Section("Storage") {
                    Text("Uploaded EPUBs are imported into Documents/Immersive Reader/.")
                    Text("Keep the app open while uploading. iOS may suspend local networking in the background.")
                        .foregroundStyle(.secondary)
                }

                Section("Recent Uploads") {
                    if controller.recentUploads.isEmpty {
                        Text("No uploads yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.recentUploads) { upload in
                            VStack(alignment: .leading) {
                                Text(upload.filename)
                                Text(upload.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Upload")
        }
    }
}

private struct SettingsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Settings Later",
                systemImage: "gearshape",
                description: Text("Reader typography, theme, playback, and server settings will be added in a later pass.")
            )
            .navigationTitle("Settings")
        }
    }
}

private extension UTType {
    static let epub = UTType(filenameExtension: "epub") ?? .data
}

#Preview {
    ContentView()
        .modelContainer(for: Book.self, inMemory: true)
}
