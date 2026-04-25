//
//  ContentView.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    var body: some View {
        TabView {
            BooksView()
                .tabItem {
                    Label("Books", systemImage: "books.vertical")
                }

            UploadPlaceholderView()
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
                                ReaderPlaceholderView(book: book)
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
            try importBooks(from: urls)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importBooks(from urls: [URL]) throws {
        let fileManager = FileManager.default
        let libraryDirectory = try epubLibraryDirectory()

        for sourceURL in urls {
            let filename = sourceURL.lastPathComponent
            guard !books.contains(where: { $0.originalFilename == filename }) else {
                continue
            }

            let hasAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let destinationURL = libraryDirectory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
            try fileManager.copyItem(at: sourceURL, to: destinationURL)

            let book = Book(
                title: displayTitle(for: sourceURL),
                originalFilename: filename,
                epubFilePath: destinationURL.path
            )
            modelContext.insert(book)
        }

        try modelContext.save()
    }

    private func deleteBooks(at offsets: IndexSet) {
        let fileManager = FileManager.default

        for index in offsets {
            let book = books[index]
            try? fileManager.removeItem(atPath: book.epubFilePath)
            modelContext.delete(book)
        }

        try? modelContext.save()
    }

    private func epubLibraryDirectory() throws -> URL {
        let documentsDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let libraryDirectory = documentsDirectory.appendingPathComponent("EPUBs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: libraryDirectory,
            withIntermediateDirectories: true
        )
        return libraryDirectory
    }

    private func displayTitle(for url: URL) -> String {
        url.deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
    }
}

private struct BookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.blue.gradient)
                .frame(width: 52, height: 68)
                .overlay {
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }

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
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ReaderPlaceholderView: View {
    @Environment(\.modelContext) private var modelContext
    let book: Book

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text(book.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(book.author)
                    .foregroundStyle(.secondary)
            }

            Text("Reader integration is next. This book is imported and ready for EPUB extraction, Readium rendering, and media-overlay playback.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .padding()
        .navigationTitle("Reader")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            book.lastOpenedAt = Date()
            try? modelContext.save()
        }
    }
}

private struct UploadPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Upload Server Later",
                systemImage: "network",
                description: Text("The local HTTP EPUB upload server will be added after the Books tab and reader pipeline are stable.")
            )
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
