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
    @StateObject private var playback = MediaOverlayPlaybackController()

    let book: Book

    @State private var state: ReaderState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Opening EPUB...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready(_, let navigator):
                VStack(spacing: 0) {
                    EPUBNavigatorHost(navigator: navigator) { locator in
                        saveLocation(locator)
                    }
                    .ignoresSafeArea(edges: .bottom)

                    if !playback.clips.isEmpty {
                        MediaOverlayPlaybackBar(
                            playback: playback,
                            playPause: {
                                playback.togglePlayback()
                                navigateToCurrentClip(with: navigator)
                                applyCurrentClipDecoration(with: navigator)
                            },
                            previous: {
                                playback.previousClip()
                                navigateToCurrentClip(with: navigator)
                                applyCurrentClipDecoration(with: navigator)
                            },
                            next: {
                                playback.nextClip()
                                navigateToCurrentClip(with: navigator)
                                applyCurrentClipDecoration(with: navigator)
                            }
                        )
                    }
                }
                .onChange(of: playback.currentClipIndex) { _, _ in
                    navigateToCurrentClip(with: navigator)
                    applyCurrentClipDecoration(with: navigator)
                }

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
        .onDisappear {
            playback.stop()
        }
    }

    @MainActor
    private func openBook() async {
        guard case .loading = state else {
            return
        }

        book.lastOpenedAt = Date()
        try? modelContext.save()
        playback.load(from: book.mediaOverlayJSONPath)

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

    @MainActor
    private func navigateToCurrentClip(with navigator: EPUBNavigatorViewController) {
        guard let clip = playback.currentClip,
              let href = RelativeURL(epubHREF: clip.textResourceHref)
        else {
            return
        }

        let locator = Locator(
            href: href,
            mediaType: .xhtml,
            locations: Locator.Locations(
                fragments: clip.fragmentID.map { [$0] } ?? []
            )
        )

        Task {
            await navigator.go(to: locator, options: .animated)
        }
    }

    @MainActor
    private func applyCurrentClipDecoration(with navigator: EPUBNavigatorViewController) {
        guard let clip = playback.currentClip,
              let href = RelativeURL(epubHREF: clip.textResourceHref)
        else {
            navigator.apply(decorations: [], in: mediaOverlayDecorationGroup)
            return
        }

        let locator = Locator(
            href: href,
            mediaType: .xhtml,
            locations: Locator.Locations(
                fragments: clip.fragmentID.map { [$0] } ?? []
            )
        )

        navigator.apply(
            decorations: [
                Decoration(
                    id: "media-overlay-active",
                    locator: locator,
                    style: .highlight(tint: .systemGreen, isActive: true)
                ),
            ],
            in: mediaOverlayDecorationGroup
        )
    }
}

private let mediaOverlayDecorationGroup = "media-overlay"

private enum ReaderState {
    case loading
    case ready(publication: Publication, navigator: EPUBNavigatorViewController)
    case failed(String)
}

private struct MediaOverlayPlaybackBar: View {
    @ObservedObject var playback: MediaOverlayPlaybackController
    let playPause: () -> Void
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Button(action: previous) {
                Image(systemName: "backward.fill")
            }
            .disabled(playback.currentClipIndex == nil || playback.currentClipIndex == 0)

            Button(action: playPause) {
                Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 36, height: 36)
                    .background(.blue, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button(action: next) {
                Image(systemName: "forward.fill")
            }
            .disabled(!canGoForward)

            VStack(alignment: .leading, spacing: 2) {
                Text("Read Aloud")
                    .font(.caption.bold())
                Text(playback.currentClipNumberText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var canGoForward: Bool {
        guard let currentClipIndex = playback.currentClipIndex else {
            return false
        }
        return currentClipIndex < playback.clips.count - 1
    }
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
