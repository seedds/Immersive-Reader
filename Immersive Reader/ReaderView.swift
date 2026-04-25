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
                EPUBNavigatorHost(navigator: navigator) { locator in
                    saveLocation(locator)
                }
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
            let initialLocation = savedLocation()
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: .init()
            )
            state = .ready(publication: publication, navigator: navigator)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func savedLocation() -> Locator? {
        guard let lastLocatorJSON = book.lastLocatorJSON else {
            return nil
        }
        return (try? Locator(jsonString: lastLocatorJSON)) ?? nil
    }

    @MainActor
    private func saveLocation(_ locator: Locator) {
        book.lastLocatorJSON = locator.jsonString
        book.lastOpenedAt = Date()
        try? modelContext.save()
    }
}

private enum ReaderState {
    case loading
    case ready(publication: Publication, navigator: EPUBNavigatorViewController)
    case failed(String)
}

private struct EPUBNavigatorHost: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    let onLocationDidChange: (Locator) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLocationDidChange: onLocationDidChange)
    }

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator.delegate = context.coordinator
        return navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {
        context.coordinator.onLocationDidChange = onLocationDidChange
        uiViewController.delegate = context.coordinator
    }

    final class Coordinator: NSObject, EPUBNavigatorDelegate {
        var onLocationDidChange: (Locator) -> Void

        init(onLocationDidChange: @escaping (Locator) -> Void) {
            self.onLocationDidChange = onLocationDidChange
        }

        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            onLocationDidChange(locator)
        }

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
    }
}
