//
//  ReaderView.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import ReadiumNavigator
import ReadiumShared
import SwiftData
import SwiftUI
import UIKit

struct ReaderView: View {
    @Environment(\.modelContext) private var modelContext

    let book: Book

    @State private var state: ReaderState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Opening EPUB...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready(_, let navigator):
                ViewControllerHost(viewController: navigator)
                    .ignoresSafeArea(edges: .bottom)

            case .failed(let message):
                ContentUnavailableView(
                    "Couldn’t Open EPUB",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: book.id) {
            await openBook()
        }
    }

    @MainActor
    private func openBook() async {
        guard case .loading = state else {
            return
        }

        book.lastOpenedAt = Date()
        try? modelContext.save()

        do {
            let publication = try await ReadiumBookService.shared.openPublication(for: book)
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: nil,
                config: .init()
            )
            state = .ready(publication: publication, navigator: navigator)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private enum ReaderState {
    case loading
    case ready(publication: Publication, navigator: EPUBNavigatorViewController)
    case failed(String)
}

private struct ViewControllerHost<ViewController: UIViewController>: UIViewControllerRepresentable {
    let viewController: ViewController

    func makeUIViewController(context: Context) -> ViewController {
        viewController
    }

    func updateUIViewController(_ uiViewController: ViewController, context: Context) {}
}
