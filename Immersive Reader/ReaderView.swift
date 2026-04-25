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
import WebKit

struct ReaderView: View {
    @Environment(\.modelContext) private var modelContext
    @SwiftUI.AppStorage(ReaderSettings.fontSizeKey) private var readerFontSize = ReaderSettings.defaultFontSize
    @SwiftUI.AppStorage(ReaderSettings.fontFamilyKey) private var readerFontFamilyRawValue = ""
    @StateObject private var playback = MediaOverlayPlaybackController()

    let book: Book

    @State private var state: ReaderState = .loading
    @State private var chapterItems: [ChapterListItem] = []
    @State private var isChapterDrawerPresented = false
    @State private var currentLocationReference: EPUBReference?
    @State private var scrollSettledPlaybackTask: Task<Void, Never>?
    @State private var suppressNextClipNavigation = false
    @State private var suppressNextTapPlaybackNavigation = false
    @State private var programmaticPlaybackScrollState: ProgrammaticPlaybackScrollState?
    @State private var suppressPlaybackRetargetUntilClipChange = false
    @State private var readingOrderResourceHrefs: [String] = []

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Opening EPUB...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready(_, let navigator):
                ZStack(alignment: .trailing) {
                    VStack(spacing: 0) {
                        EPUBNavigatorHost(
                            navigator: navigator,
                            onLocationDidChange: { locator in
                                handleLocationDidChange(locator, navigator: navigator)
                            },
                            onViewportDidChange: {
                                Task {
                                    await handleViewportDidChange(navigator: navigator)
                                }
                                scheduleScrollSettledPlaybackSync(with: navigator)
                            },
                            onAudioTap: { reference in
                                Task {
                                    await playFromTappedReference(reference, navigator: navigator)
                                }
                            }
                        )
                        .ignoresSafeArea(edges: .bottom)

                        if !playback.clips.isEmpty {
                            MediaOverlayPlaybackBar(
                                playback: playback,
                                playPause: {
                                    if playback.state.isPlaying {
                                        playback.pause()
                                        applyCurrentClipDecoration(with: navigator)
                                    } else {
                                        Task {
                                            await startPlaybackFromVisibleOrForwardPosition(with: navigator)
                                        }
                                    }
                                },
                                previous: {
                                    suppressPlaybackRetargetUntilClipChange = false
                                    playback.previousClip()
                                    handleCurrentClipChange(oldIndex: nil, newIndex: playback.currentClipIndex, navigator: navigator)
                                },
                                next: {
                                    suppressPlaybackRetargetUntilClipChange = false
                                    playback.nextClip()
                                    handleCurrentClipChange(oldIndex: nil, newIndex: playback.currentClipIndex, navigator: navigator)
                                }
                            )
                        }
                    }

                    if isChapterDrawerPresented {
                        Color.black.opacity(0.2)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isChapterDrawerPresented = false
                                }
                            }

                        ChapterDrawer(
                            items: chapterItems,
                            selectedItemID: activeChapterItemID,
                            onSelect: { item in
                                Task {
                                    await selectChapter(item, navigator: navigator)
                                }
                            },
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isChapterDrawerPresented = false
                                }
                            }
                        )
                        .transition(.move(edge: .trailing))
                    }
                }
                .onChange(of: playback.currentClipIndex) { oldIndex, newIndex in
                    handleCurrentClipChange(oldIndex: oldIndex, newIndex: newIndex, navigator: navigator)
                }
                .onChange(of: readerFontSize) { _, _ in
                    applyReaderPreferences(to: navigator)
                }
                .onChange(of: readerFontFamilyRawValue) { _, _ in
                    applyReaderPreferences(to: navigator)
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
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if case .ready = state {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isChapterDrawerPresented.toggle()
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Chapters")
                }
            }
        }
        .task(id: book.id) {
            await openBook()
        }
        .onDisappear {
            scrollSettledPlaybackTask?.cancel()
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
            let chapterItems = await loadChapterItems(from: publication)
            let preferences = readerPreferences()
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: .init(
                    preferences: preferences,
                    defaults: EPUBDefaults(scroll: true, spread: .never),
                    disablePageTurnsWhileScrolling: true
                )
            )
            navigator.submitPreferences(preferences)
            self.chapterItems = chapterItems
            self.readingOrderResourceHrefs = publication.readingOrder.map { normalizedResourceHref(for: $0.href) }
            state = .ready(publication: publication, navigator: navigator)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func readerPreferences() -> EPUBPreferences {
        EPUBPreferences(
            fontFamily: ReaderSettings.fontFamily(from: readerFontFamilyRawValue),
            fontSize: ReaderSettings.normalizedFontSize(readerFontSize),
            publisherStyles: false,
            scroll: true
        )
    }

    @MainActor
    private func applyReaderPreferences(to navigator: EPUBNavigatorViewController) {
        navigator.submitPreferences(readerPreferences())
    }

    private func loadChapterItems(from publication: Publication) async -> [ChapterListItem] {
        let links = (try? await publication.tableOfContents().get()) ?? publication.readingOrder
        return flattenChapterLinks(links)
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
    private func handleLocationDidChange(_ locator: Locator, navigator: EPUBNavigatorViewController) {
        currentLocationReference = normalizedReference(for: locator.href.string)
        saveLocation(locator)

        maybeEndProgrammaticPlaybackScroll(with: currentLocationReference)

        guard !isProgrammaticPlaybackScrollInFlight else {
            return
        }

        scheduleScrollSettledPlaybackSync(with: navigator)
    }

    @MainActor
    private func scheduleScrollSettledPlaybackSync(with navigator: EPUBNavigatorViewController) {
        scrollSettledPlaybackTask?.cancel()

        guard playback.state.isPlaying,
              !isProgrammaticPlaybackScrollInFlight,
              !suppressPlaybackRetargetUntilClipChange
        else {
            return
        }

        scrollSettledPlaybackTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else {
                return
            }

            await retargetPlaybackToFirstVisibleClipIfNeeded(with: navigator)
        }
    }

    @MainActor
    private func handleViewportDidChange(navigator: EPUBNavigatorViewController) async {
        if case .autoFollowInDocument = programmaticPlaybackScrollState?.kind,
           let visibleLocator = await navigator.firstVisibleElementLocator() {
            maybeEndProgrammaticPlaybackScroll(
                with: EPUBReference(
                    resourceHref: normalizedResourceHref(for: visibleLocator.href.string),
                    fragmentID: visibleLocator.locations.fragments.first
                )
            )
        }
    }

    private var isProgrammaticPlaybackScrollInFlight: Bool {
        programmaticPlaybackScrollState != nil
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

        beginProgrammaticPlaybackScroll(
            kind: .goToClip,
            target: normalizedReference(for: clip.textResourceHref)
        )

        Task {
            await navigator.go(to: locator, options: .animated)
        }
    }

    @MainActor
    private func retargetPlaybackToFirstVisibleClipIfNeeded(with navigator: EPUBNavigatorViewController) async {
        guard playback.state.isPlaying,
              !isProgrammaticPlaybackScrollInFlight,
              !suppressPlaybackRetargetUntilClipChange,
              let currentClip = playback.currentClip,
              let visibleReference = await firstVisibleSpokenReferenceIfCurrentClipIsOffscreen(
                currentClip: currentClip,
                navigator: navigator
              ),
              let visibleClipIndex = exactClipIndex(for: visibleReference),
              !matchesCurrentClip(visibleReference),
              visibleClipIndex != playback.currentClipIndex
        else {
            return
        }

        suppressNextClipNavigation = true
        playback.selectClip(at: visibleClipIndex, autoplay: true)
        applyCurrentClipDecoration(with: navigator)
    }

    @MainActor
    private func selectChapter(_ item: ChapterListItem, navigator: EPUBNavigatorViewController) async {
        suppressPlaybackRetargetUntilClipChange = false

        withAnimation(.easeInOut(duration: 0.2)) {
            isChapterDrawerPresented = false
        }

        let wasPlaying = playback.state.isPlaying
        if let clipIndex = firstClipIndex(for: item.link) {
            playback.selectClip(at: clipIndex, autoplay: wasPlaying)
            navigateToCurrentClip(with: navigator)
            applyCurrentClipDecoration(with: navigator)
            return
        }

        if wasPlaying {
            playback.pause()
        }

        _ = await navigator.go(to: item.link, options: .animated)

        guard wasPlaying else {
            return
        }

        await startPlaybackFromVisibleOrForwardPosition(with: navigator)
    }

    @MainActor
    private func startPlaybackFromVisibleOrForwardPosition(with navigator: EPUBNavigatorViewController) async {
        suppressPlaybackRetargetUntilClipChange = false

        guard let target = await resolvedPlaybackStartTarget(with: navigator) else {
            return
        }

        if playback.currentClipIndex != target.clipIndex {
            if !target.shouldNavigate {
                suppressNextClipNavigation = true
            }
            playback.selectClip(at: target.clipIndex, autoplay: true)
            if target.shouldNavigate {
                navigateToCurrentClip(with: navigator)
            }
            return
        }

        playback.play()
        if target.shouldNavigate {
            navigateToCurrentClip(with: navigator)
        } else {
            applyCurrentClipDecoration(with: navigator)
        }
    }

    @MainActor
    private func playFromTappedReference(_ reference: EPUBReference, navigator: EPUBNavigatorViewController) async {
        guard let clipIndex = exactClipIndex(for: reference) else {
            return
        }

        suppressPlaybackRetargetUntilClipChange = false
        suppressNextTapPlaybackNavigation = true
        playback.selectClip(at: clipIndex, autoplay: true)
        applyCurrentClipDecoration(with: navigator)
    }

    private func exactClipIndex(for reference: EPUBReference) -> Int? {
        guard let fragmentID = reference.fragmentID,
              !fragmentID.isEmpty
        else {
            return nil
        }

        let exactReference = EPUBReference(
            resourceHref: reference.resourceHref,
            fragmentID: fragmentID
        )

        let match = playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == exactReference.resourceHref &&
            clip.fragmentID == exactReference.fragmentID
        })
        return match
    }

    private func firstClipIndex(for link: ReadiumShared.Link) -> Int? {
        firstClipIndex(for: normalizedReference(for: link.href))
    }

    private func firstClipIndex(for reference: EPUBReference) -> Int? {
        let chapterReference = reference

        if let exactMatch = playback.clips.firstIndex(where: { clip in
            normalizedReference(for: clip.textResourceHref) == chapterReference
        }) {
            return exactMatch
        }

        return playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == chapterReference.resourceHref
        })
    }

    private func firstClipIndex(forResourceHref resourceHref: String) -> Int? {
        playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == resourceHref
        })
    }

    private func firstClipIndex(afterResourceHref resourceHref: String) -> Int? {
        guard let currentResourceOrder = readingOrderResourceHrefs.firstIndex(of: resourceHref) else {
            return nil
        }

        for (index, clip) in playback.clips.enumerated() {
            let clipResourceHref = normalizedResourceHref(for: clip.textResourceHref)
            guard let clipResourceOrder = readingOrderResourceHrefs.firstIndex(of: clipResourceHref),
                  clipResourceOrder > currentResourceOrder
            else {
                continue
            }

            return index
        }

        return nil
    }

    private func normalizedReference(for href: String) -> EPUBReference {
        let normalized = (AnyURL(string: href)?.normalized.string ?? href)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = normalized.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let resourceHref = parts.first.map(String.init) ?? ""
        let fragmentID = parts.count > 1 ? String(parts[1]) : nil
        return EPUBReference(resourceHref: resourceHref, fragmentID: fragmentID)
    }

    private func normalizedResourceHref(for href: String) -> String {
        normalizedReference(for: href).resourceHref
    }

    private var activeChapterItemID: ChapterListItem.ID? {
        guard let currentLocationReference else {
            return nil
        }

        if let exactMatch = chapterItems.last(where: { item in
            normalizedReference(for: item.link.href) == currentLocationReference
        }) {
            return exactMatch.id
        }

        return chapterItems.last(where: { item in
            normalizedResourceHref(for: item.link.href) == currentLocationReference.resourceHref
        })?.id
    }

    @MainActor
    private func handleCurrentClipChange(oldIndex: Int?, newIndex: Int?, navigator: EPUBNavigatorViewController) {
        applyCurrentClipDecoration(with: navigator)

        if oldIndex != newIndex {
            suppressPlaybackRetargetUntilClipChange = false
        }

        if suppressNextTapPlaybackNavigation {
            suppressNextTapPlaybackNavigation = false
            return
        }

        if suppressNextClipNavigation {
            suppressNextClipNavigation = false
            return
        }

        guard let newIndex,
              playback.clips.indices.contains(newIndex)
        else {
            return
        }

        let newClip = playback.clips[newIndex]

        if playback.state.isPlaying,
           let oldIndex,
           playback.clips.indices.contains(oldIndex) {
            let oldClip = playback.clips[oldIndex]
            if oldClip.textResourceHref == newClip.textResourceHref {
                autoFollowCurrentClipIfNeeded(with: navigator, fragmentID: newClip.fragmentID)
                return
            }
        }

        navigateToCurrentClip(with: navigator)
    }

    @MainActor
    private func autoFollowCurrentClipIfNeeded(with navigator: EPUBNavigatorViewController, fragmentID: String?) {
        guard playback.state.isPlaying,
              let fragmentID,
              !fragmentID.isEmpty,
              let currentClip = playback.currentClip
        else {
            return
        }

        let fragmentIDLiteral = javaScriptStringLiteral(fragmentID)
        let script = """
        (() => {
          const element = document.getElementById(\(fragmentIDLiteral));
          if (!element) {
            return 'missing';
          }

          const rect = element.getBoundingClientRect();
          const threshold = window.innerHeight * 0.9;
          if (rect.bottom >= threshold) {
            const targetTop = window.innerHeight * 0.15;
            const delta = rect.top - targetTop;
            if (Math.abs(delta) <= 2) {
              return 'noop';
            }

            window.scrollBy({ top: delta, behavior: 'smooth' });
            return 'scrolled';
          }

          return 'noop';
        })();
        """

        beginProgrammaticPlaybackScroll(
            kind: .autoFollowInDocument,
            target: EPUBReference(
                resourceHref: normalizedResourceHref(for: currentClip.textResourceHref),
                fragmentID: fragmentID
            )
        )

        Task {
            let result = await navigator.evaluateJavaScript(script)
            guard case .success(let value) = result,
                  let action = value as? String
            else {
                await MainActor.run {
                    endProgrammaticPlaybackScroll()
                }
                return
            }

            await MainActor.run {
                if action == "scrolled" {
                    suppressPlaybackRetargetUntilClipChange = true
                } else {
                    endProgrammaticPlaybackScroll()
                }
            }
        }
    }

    private func matchesCurrentClip(_ reference: EPUBReference) -> Bool {
        guard let currentClip = playback.currentClip else {
            return false
        }

        return EPUBReference(
            resourceHref: normalizedResourceHref(for: currentClip.textResourceHref),
            fragmentID: currentClip.fragmentID
        ) == reference
    }

    @MainActor
    private func beginProgrammaticPlaybackScroll(kind: ProgrammaticPlaybackScrollKind, target: EPUBReference) {
        scrollSettledPlaybackTask?.cancel()
        programmaticPlaybackScrollState = ProgrammaticPlaybackScrollState(kind: kind, target: target)
    }

    @MainActor
    private func maybeEndProgrammaticPlaybackScroll(with reference: EPUBReference?) {
        guard let state = programmaticPlaybackScrollState,
              let reference
        else {
            return
        }

        switch state.kind {
        case .goToClip:
            if state.target.resourceHref == reference.resourceHref {
                if state.target.fragmentID == nil || state.target.fragmentID == reference.fragmentID {
                    endProgrammaticPlaybackScroll()
                }
            }

        case .autoFollowInDocument:
            if reference == state.target {
                endProgrammaticPlaybackScroll()
            }
        }
    }

    @MainActor
    private func endProgrammaticPlaybackScroll() {
        programmaticPlaybackScrollState = nil
    }

    @MainActor
    private func firstVisibleSpokenReferenceIfCurrentClipIsOffscreen(
        currentClip: EPUBMediaOverlayClip,
        navigator: EPUBNavigatorViewController
    ) async -> EPUBReference? {
        guard let currentFragmentID = currentClip.fragmentID,
              !currentFragmentID.isEmpty,
              let visibleLocator = await navigator.firstVisibleElementLocator()
        else {
            return nil
        }

        let currentReference = EPUBReference(
            resourceHref: normalizedResourceHref(for: currentClip.textResourceHref),
            fragmentID: currentFragmentID
        )
        let visibleReference = EPUBReference(
            resourceHref: normalizedResourceHref(for: visibleLocator.href.string),
            fragmentID: visibleLocator.locations.fragments.first
        )

        if currentReference == visibleReference {
            return nil
        }

        let visibleResourceHref = visibleReference.resourceHref
        let playableFragmentIDs = playableFragmentIDs(for: visibleResourceHref)
        guard !playableFragmentIDs.isEmpty
        else {
            return nil
        }

        guard let visibleFragmentID = await firstPlayableFragmentIDInViewport(
            fragmentIDs: playableFragmentIDs,
            navigator: navigator
        ) else {
            return nil
        }

        return EPUBReference(resourceHref: visibleResourceHref, fragmentID: visibleFragmentID)
    }

    private func playableFragmentIDs(for resourceHref: String) -> [String] {
        var fragmentIDs: [String] = []
        var seen = Set<String>()

        for clip in playback.clips {
            guard normalizedResourceHref(for: clip.textResourceHref) == resourceHref,
                  let fragmentID = clip.fragmentID,
                  !fragmentID.isEmpty,
                  seen.insert(fragmentID).inserted
            else {
                continue
            }

            fragmentIDs.append(fragmentID)
        }

        return fragmentIDs
    }

    @MainActor
    private func resolvedPlaybackStartTarget(with navigator: EPUBNavigatorViewController) async -> PlaybackStartTarget? {
        guard let visibleLocator = await navigator.firstVisibleElementLocator() else {
            return nil
        }

        let visibleResourceHref = normalizedResourceHref(for: visibleLocator.href.string)
        let playableIDs = playableFragmentIDs(for: visibleResourceHref)

        if !playableIDs.isEmpty,
           let visibleFragmentID = await firstPlayableFragmentIDInViewport(
            fragmentIDs: playableIDs,
            navigator: navigator
           ),
           let visibleClipIndex = exactClipIndex(for: EPUBReference(
            resourceHref: visibleResourceHref,
            fragmentID: visibleFragmentID
           )) {
            return PlaybackStartTarget(clipIndex: visibleClipIndex, shouldNavigate: false)
        }

        if !playableIDs.isEmpty,
           let forwardFragmentID = await firstPlayableFragmentIDAfterViewport(
            fragmentIDs: playableIDs,
            navigator: navigator
           ),
           let forwardClipIndex = exactClipIndex(for: EPUBReference(
            resourceHref: visibleResourceHref,
            fragmentID: forwardFragmentID
           )) {
            return PlaybackStartTarget(clipIndex: forwardClipIndex, shouldNavigate: true)
        }

        if let laterClipIndex = firstClipIndex(afterResourceHref: visibleResourceHref) {
            return PlaybackStartTarget(clipIndex: laterClipIndex, shouldNavigate: true)
        }

        return nil
    }

    @MainActor
    private func firstPlayableFragmentIDInViewport(
        fragmentIDs: [String],
        navigator: EPUBNavigatorViewController
    ) async -> String? {
        let fragmentIDsLiteral = javaScriptArrayLiteral(fragmentIDs)
        let script = """
        (() => {
          const fragmentIDs = \(fragmentIDsLiteral);

          const topInsideViewport = element => {
            if (!element) {
              return null;
            }

            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') {
              return null;
            }

            const rect = element.getBoundingClientRect();
            return rect.top >= 0 && rect.top <= window.innerHeight ? rect.top : null;
          };

          let firstVisible = null;
          for (const fragmentID of fragmentIDs) {
            const element = document.getElementById(fragmentID);
            const top = topInsideViewport(element);
            if (top === null) {
              continue;
            }

            if (!firstVisible || top < firstVisible.top) {
              firstVisible = { top, fragmentID };
            }
          }

          return firstVisible?.fragmentID ?? null;
        })();
        """

        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let value) = result,
              let fragmentID = value as? String,
              !fragmentID.isEmpty
        else {
            return nil
        }

        return fragmentID
    }

    @MainActor
    private func firstPlayableFragmentIDAfterViewport(
        fragmentIDs: [String],
        navigator: EPUBNavigatorViewController
    ) async -> String? {
        let fragmentIDsLiteral = javaScriptArrayLiteral(fragmentIDs)
        let script = """
        (() => {
          const fragmentIDs = \(fragmentIDsLiteral);

          let firstForward = null;
          for (const fragmentID of fragmentIDs) {
            const element = document.getElementById(fragmentID);
            if (!element) {
              continue;
            }

            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') {
              continue;
            }

            const rect = element.getBoundingClientRect();
            if (rect.top < window.innerHeight) {
              continue;
            }

            if (!firstForward || rect.top < firstForward.top) {
              firstForward = { top: rect.top, fragmentID };
            }
          }

          return firstForward?.fragmentID ?? null;
        })();
        """

        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let value) = result,
              let fragmentID = value as? String,
              !fragmentID.isEmpty
        else {
            return nil
        }

        return fragmentID
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

private func javaScriptStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    return "\"\(escaped)\""
}

private func javaScriptArrayLiteral(_ values: [String]) -> String {
    "[\(values.map(javaScriptStringLiteral).joined(separator: ", "))]"
}

private enum ReaderState {
    case loading
    case ready(publication: Publication, navigator: EPUBNavigatorViewController)
    case failed(String)
}

private struct ChapterListItem: Identifiable {
    let level: Int
    let link: ReadiumShared.Link

    var id: String {
        "\(level)-\(link.href)-\(link.title ?? "")"
    }

    var title: String {
        link.title ?? link.href
    }
}

private struct EPUBReference: Equatable {
    let resourceHref: String
    let fragmentID: String?
}

private enum ProgrammaticPlaybackScrollKind {
    case autoFollowInDocument
    case goToClip
}

private struct ProgrammaticPlaybackScrollState {
    let kind: ProgrammaticPlaybackScrollKind
    let target: EPUBReference
}

private struct PlaybackStartTarget {
    let clipIndex: Int
    let shouldNavigate: Bool
}

private struct ChapterDrawer: View {
    let items: [ChapterListItem]
    let selectedItemID: ChapterListItem.ID?
    let onSelect: (ChapterListItem) -> Void
    let onClose: () -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Chapters")
                        .font(.headline)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()

                Divider()

                if items.isEmpty {
                    ContentUnavailableView(
                        "No Chapters",
                        systemImage: "list.bullet.rectangle",
                        description: Text("This book doesn't expose a table of contents.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(items) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    Text(item.title)
                                        .fontWeight(selectedItemID == item.id ? .semibold : .regular)
                                        .foregroundStyle(selectedItemID == item.id ? .blue : .primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 12)
                                        .padding(.leading, 16 + CGFloat(item.level * 18))
                                        .padding(.trailing, 16)
                                        .background(
                                            selectedItemID == item.id
                                                ? Color.blue.opacity(0.1)
                                                : Color.clear
                                        )
                                }
                                .buttonStyle(.plain)

                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: min(proxy.size.width * 0.82, 360), maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 18, x: -4, y: 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
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

private func flattenChapterLinks(_ links: [ReadiumShared.Link], level: Int = 0) -> [ChapterListItem] {
    links.flatMap { [ChapterListItem(level: level, link: $0)] + flattenChapterLinks($0.children, level: level + 1) }
}

private struct EPUBNavigatorHost: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    let onLocationDidChange: (Locator) -> Void
    let onViewportDidChange: () -> Void
    let onAudioTap: (EPUBReference) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLocationDidChange: onLocationDidChange,
            onViewportDidChange: onViewportDidChange,
            onAudioTap: onAudioTap
        )
    }

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator.delegate = context.coordinator
        context.coordinator.attach(to: navigator)
        return navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {
        context.coordinator.onLocationDidChange = onLocationDidChange
        context.coordinator.onViewportDidChange = onViewportDidChange
        context.coordinator.onAudioTap = onAudioTap
        context.coordinator.attach(to: uiViewController)
        uiViewController.delegate = context.coordinator
    }

    final class Coordinator: NSObject, EPUBNavigatorDelegate, UIGestureRecognizerDelegate, WKScriptMessageHandler {
        var onLocationDidChange: (Locator) -> Void
        var onViewportDidChange: () -> Void
        var onAudioTap: (EPUBReference) -> Void
        private weak var navigator: EPUBNavigatorViewController?
        private var panRecognizer: UIPanGestureRecognizer?
        private var currentViewport: EPUBNavigatorViewController.Viewport?
        private var lastBoundaryNavigationDate: Date?
        private let boundaryPullThreshold: CGFloat = 200
        private let boundaryProgressThreshold = 0.9997
        private let boundaryCooldown: TimeInterval = 1.0
        private let audioTapMessageName = "mediaOverlayAudioTap"

        init(
            onLocationDidChange: @escaping (Locator) -> Void,
            onViewportDidChange: @escaping () -> Void,
            onAudioTap: @escaping (EPUBReference) -> Void
        ) {
            self.onLocationDidChange = onLocationDidChange
            self.onViewportDidChange = onViewportDidChange
            self.onAudioTap = onAudioTap
        }

        func attach(to navigator: EPUBNavigatorViewController) {
            self.navigator = navigator

            if panRecognizer == nil {
                let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleBoundaryPan(_:)))
                panRecognizer.cancelsTouchesInView = false
                panRecognizer.delegate = self
                navigator.view.addGestureRecognizer(panRecognizer)
                self.panRecognizer = panRecognizer
            }
        }

        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            onLocationDidChange(locator)
        }

        func navigator(_ navigator: EPUBNavigatorViewController, viewportDidChange viewport: EPUBNavigatorViewController.Viewport?) {
            currentViewport = viewport
            onViewportDidChange()
        }

        func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
            userContentController.removeScriptMessageHandler(forName: audioTapMessageName)
            userContentController.add(self, name: audioTapMessageName)
            userContentController.addUserScript(
                WKUserScript(
                    source: audioTapScript(messageName: audioTapMessageName),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == audioTapMessageName,
                  let body = message.body as? [String: Any],
                  let href = body["href"] as? String
            else {
                return
            }

            let fragmentID = body["fragmentID"] as? String
            onAudioTap(EPUBReference(resourceHref: href, fragmentID: fragmentID))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func handleBoundaryPan(_ gestureRecognizer: UIPanGestureRecognizer) {
            guard gestureRecognizer.state == .ended,
                  let navigator,
                  let viewport = currentViewport,
                  let href = viewport.readingOrder.first,
                  let progression = viewport.progressions[href]
            else {
                return
            }

            let translation = gestureRecognizer.translation(in: gestureRecognizer.view)
            guard abs(translation.y) > abs(translation.x),
                  abs(translation.y) >= boundaryPullThreshold,
                  canTriggerBoundaryNavigation()
            else {
                return
            }

            if progression.upperBound >= boundaryProgressThreshold,
               translation.y < 0 {
                triggerBoundaryNavigation { await navigator.goForward(options: .animated) }
            } else if progression.lowerBound <= (1 - boundaryProgressThreshold),
                      translation.y > 0 {
                triggerBoundaryNavigation { await navigator.goBackward(options: .animated) }
            }
        }

        private func canTriggerBoundaryNavigation() -> Bool {
            guard let lastBoundaryNavigationDate else {
                return true
            }

            return Date().timeIntervalSince(lastBoundaryNavigationDate) > boundaryCooldown
        }

        private func triggerBoundaryNavigation(_ action: @escaping @MainActor () async -> Bool) {
            lastBoundaryNavigationDate = Date()
            Task { @MainActor in
                _ = await action()
            }
        }

        private func audioTapScript(messageName: String) -> String {
            """
            (() => {
              if (window.__immersiveReaderAudioTapInstalled) {
                return;
              }
              window.__immersiveReaderAudioTapInstalled = true;

              const messageHandler = window.webkit?.messageHandlers?.\(messageName);
              if (!messageHandler) {
                return;
              }

              const ignoredSelector = 'a, button, input, textarea, select, summary, label, [role="button"], [contenteditable="true"]';

              function nearestIdentifiedElement(target) {
                if (!(target instanceof Element)) {
                  return null;
                }

                if (target.closest(ignoredSelector)) {
                  return null;
                }

                var node = target;
                while (node) {
                  if (node.id) {
                    return node;
                  }
                  node = node.parentElement;
                }

                return null;
              }

              document.addEventListener('click', event => {
                const element = nearestIdentifiedElement(event.target);
                if (!element) {
                  return;
                }

                const href = window.location.pathname.replace(/^\\//, '');
                if (!href) {
                  return;
                }

                messageHandler.postMessage({
                  href,
                  fragmentID: element.id || null
                });
              }, true);
            })();
            """
        }
    }
}
