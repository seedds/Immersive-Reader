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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @SwiftUI.AppStorage(ReaderSettings.fontSizeKey) private var readerFontSize = ReaderSettings.defaultFontSize
    @SwiftUI.AppStorage(ReaderSettings.fontFamilyKey) private var readerFontFamilyRawValue = ""
    @SwiftUI.AppStorage(ReaderSettings.themeKey) private var readerThemeRawValue = AppThemeOption.system.rawValue
    @SwiftUI.AppStorage(ReaderSettings.readAloudColorKey) private var readerReadAloudColorRawValue = ReaderSettings.defaultReadAloudColorHex
    @SwiftUI.AppStorage(ReaderSettings.playbackSpeedKey) private var readerPlaybackSpeed = ReaderSettings.defaultPlaybackSpeed
    @StateObject private var playback = MediaOverlayPlaybackController()

    let book: Book

    @State private var state: ReaderState = .loading
    @State private var chapterItems: [ChapterListItem] = []
    @State private var isChapterDrawerPresented = false
    @State private var currentLocationReference: EPUBReference?
    @State private var suppressNextClipNavigation = false
    @State private var suppressNextTapPlaybackNavigation = false
    @State private var programmaticPlaybackScrollState: ProgrammaticPlaybackScrollState?
    @State private var suppressPlaybackRetargetUntilClipChange = false
    @State private var readingOrderResourceHrefs: [String] = []
    @State private var isPlaybackSpeedControlPresented = false
    @State private var isReaderSettingsControlPresented = false

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Opening EPUB...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready(_, let navigator):
                ZStack(alignment: .trailing) {
                    VStack(spacing: 0) {
                        ZStack {
                            EPUBNavigatorHost(
                                navigator: navigator,
                                onLocationDidChange: { locator in
                                    handleLocationDidChange(locator, navigator: navigator)
                                },
                                onViewportDidChange: {
                                    Task {
                                        await handleViewportDidChange(navigator: navigator)
                                    }
                                },
                                onAudioTap: { reference in
                                    Task {
                                        await playFromTappedReference(reference, navigator: navigator)
                                    }
                                }
                            )
                            .ignoresSafeArea(edges: .bottom)

                            if isBottomControlPresented {
                                Color.black.opacity(0.001)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        dismissBottomControls()
                                    }
                            }
                        }

                        if !playback.clips.isEmpty {
                            MediaOverlayPlaybackBar(
                                playback: playback,
                                playbackSpeed: $readerPlaybackSpeed,
                                fontSize: $readerFontSize,
                                isSpeedControlPresented: $isPlaybackSpeedControlPresented,
                                isReaderSettingsControlPresented: $isReaderSettingsControlPresented,
                                toggleSpeedControl: togglePlaybackSpeedControl,
                                toggleReaderSettingsControl: toggleReaderSettingsControl,
                                playPause: {
                                    if playback.state.isPlaying {
                                        playback.pause(reason: "playPauseButton.pause")
                                        applyCurrentClipDecoration(with: navigator)
                                    } else {
                                        Task {
                                            await startPlaybackFromVisibleOrForwardPosition(with: navigator)
                                        }
                                    }
                                },
                                previous: {
                                    suppressPlaybackRetargetUntilClipChange = false
                                    playback.previousClip(reason: "playbackBar.previousButton")
                                    handleCurrentClipChange(oldIndex: nil, newIndex: playback.currentClipIndex, navigator: navigator)
                                },
                                next: {
                                    suppressPlaybackRetargetUntilClipChange = false
                                    playback.nextClip(reason: "playbackBar.nextButton")
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
                .onChange(of: readerThemeRawValue) { _, _ in
                    applyReaderPreferences(to: navigator)
                }
                .onChange(of: readerReadAloudColorRawValue) { _, _ in
                    applyCurrentClipDecoration(with: navigator)
                }
                .onChange(of: readerPlaybackSpeed) { _, newValue in
                    playback.setPlaybackRate(newValue)
                }
                .onChange(of: colorScheme) { _, _ in
                    if ReaderSettings.appTheme(from: readerThemeRawValue) == .system {
                        applyReaderPreferences(to: navigator)
                    }
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
                        dismissBottomControls()
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
            persistLastPlayedClip()
            isPlaybackSpeedControlPresented = false
            isReaderSettingsControlPresented = false
            playback.stop(reason: "readerView.onDisappear")
        }
    }

    @MainActor
    private func openBook() async {
        guard case .loading = state else {
            return
        }

        book.lastOpenedAt = Date()
        try? modelContext.save()
        playback.setPlaybackRate(readerPlaybackSpeed)
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
            restoreLastPlayedClipSelectionIfAvailable(with: navigator)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func readerPreferences() -> EPUBPreferences {
        EPUBPreferences(
            fontFamily: ReaderSettings.fontFamily(from: readerFontFamilyRawValue),
            fontSize: ReaderSettings.normalizedFontSize(readerFontSize),
            publisherStyles: false,
            scroll: true,
            theme: ReaderSettings.appTheme(from: readerThemeRawValue).readiumTheme(for: colorScheme)
        )
    }

    @MainActor
    private func applyReaderPreferences(to navigator: EPUBNavigatorViewController) {
        navigator.submitPreferences(readerPreferences())
    }

    private var isBottomControlPresented: Bool {
        isPlaybackSpeedControlPresented || isReaderSettingsControlPresented
    }

    private func dismissBottomControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isPlaybackSpeedControlPresented = false
            isReaderSettingsControlPresented = false
        }
    }

    private func togglePlaybackSpeedControl() {
        withAnimation(.easeInOut(duration: 0.2)) {
            let shouldPresent = !isPlaybackSpeedControlPresented
            isPlaybackSpeedControlPresented = shouldPresent
            if shouldPresent {
                isReaderSettingsControlPresented = false
            }
        }
    }

    private func toggleReaderSettingsControl() {
        withAnimation(.easeInOut(duration: 0.2)) {
            let shouldPresent = !isReaderSettingsControlPresented
            isReaderSettingsControlPresented = shouldPresent
            if shouldPresent {
                isPlaybackSpeedControlPresented = false
            }
        }
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
    private func persistLastPlayedClip() {
        guard let clip = playback.currentClip else {
            book.lastPlayedTextResourceHref = nil
            book.lastPlayedFragmentID = nil
            book.lastPlayedClipBegin = nil
            book.lastPlayedClipEnd = nil
            try? modelContext.save()
            return
        }

        book.lastPlayedTextResourceHref = normalizedResourceHref(for: clip.textResourceHref)
        book.lastPlayedFragmentID = clip.fragmentID
        book.lastPlayedClipBegin = clip.clipBegin
        book.lastPlayedClipEnd = clip.clipEnd
        try? modelContext.save()
    }

    @MainActor
    private func restoreLastPlayedClipSelectionIfAvailable(with navigator: EPUBNavigatorViewController) {
        guard let restoredIndex = restoredLastPlayedClipIndex() else {
            navigator.apply(decorations: [], in: mediaOverlayDecorationGroup)
            return
        }

        suppressNextClipNavigation = true
        playback.selectClip(at: restoredIndex, autoplay: false, reason: "restoreLastPlayedClip")
        navigateToCurrentClip(with: navigator)
        applyCurrentClipDecoration(with: navigator)
    }

    private func restoredLastPlayedClipIndex() -> Int? {
        guard let storedResourceHref = book.lastPlayedTextResourceHref,
              let storedClipBegin = book.lastPlayedClipBegin
        else {
            return nil
        }

        let normalizedStoredResourceHref = normalizedResourceHref(for: storedResourceHref)
        if let exactMatch = playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == normalizedStoredResourceHref &&
            clip.fragmentID == book.lastPlayedFragmentID &&
            clip.clipBegin == storedClipBegin &&
            clip.clipEnd == book.lastPlayedClipEnd
        }) {
            return exactMatch
        }

        return playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == normalizedStoredResourceHref &&
            clip.fragmentID == book.lastPlayedFragmentID
        })
    }

    @MainActor
    private func handleLocationDidChange(_ locator: Locator, navigator: EPUBNavigatorViewController) {
        currentLocationReference = normalizedReference(for: locator.href.string)
        saveLocation(locator)

        maybeEndProgrammaticPlaybackScroll(with: currentLocationReference)
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
    private func selectChapter(_ item: ChapterListItem, navigator: EPUBNavigatorViewController) async {
        suppressPlaybackRetargetUntilClipChange = false

        withAnimation(.easeInOut(duration: 0.2)) {
            isChapterDrawerPresented = false
        }

        let wasPlaying = playback.state.isPlaying
        if let clipIndex = firstClipIndex(for: item.link) {
            playback.selectClip(at: clipIndex, autoplay: wasPlaying, reason: "chapterSelect")
            navigateToCurrentClip(with: navigator)
            applyCurrentClipDecoration(with: navigator)
            return
        }

        if wasPlaying {
            playback.pause(reason: "chapterSelect.noClipMatch")
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

        let currentClipVisibility = await currentClipPlaybackVisibility(with: navigator)
        if currentClipVisibility != .notVisible {
            let shouldAlignToTop = currentClipVisibility == .visibleNeedsTopAlignment
            playback.play(reason: "startPlaybackFromVisibleOrForwardPosition.resumeVisibleCurrentClip")
            if shouldAlignToTop {
                await alignCurrentClipTopForPlayback(with: navigator)
            }
            applyCurrentClipDecoration(with: navigator)
            return
        }

        guard let target = await resolvedPlaybackStartTarget(with: navigator) else {
            return
        }

        if playback.currentClipIndex != target.clipIndex {
            if !target.shouldNavigate {
                suppressNextClipNavigation = true
            }
            playback.selectClip(at: target.clipIndex, autoplay: true, reason: "startPlaybackFromVisibleOrForwardPosition")
            if target.shouldNavigate {
                navigateToCurrentClip(with: navigator)
            } else if target.shouldAlignToTop {
                await alignCurrentClipTopForPlayback(with: navigator)
            }
            return
        }

        playback.play(reason: "startPlaybackFromVisibleOrForwardPosition.resumeCurrentClip")
        if target.shouldNavigate {
            navigateToCurrentClip(with: navigator)
        } else if target.shouldAlignToTop {
            await alignCurrentClipTopForPlayback(with: navigator)
            applyCurrentClipDecoration(with: navigator)
        } else {
            applyCurrentClipDecoration(with: navigator)
        }
    }

    @MainActor
    private func currentClipPlaybackVisibility(with navigator: EPUBNavigatorViewController) async -> FragmentPlaybackVisibility {
        guard let currentClip = playback.currentClip,
              let fragmentID = currentClip.fragmentID,
              !fragmentID.isEmpty,
              let visibleLocator = await navigator.firstVisibleElementLocator()
        else {
            return .notVisible
        }

        guard normalizedResourceHref(for: currentClip.textResourceHref) == normalizedResourceHref(for: visibleLocator.href.string) else {
            return .notVisible
        }

        return await fragmentPlaybackVisibility(for: fragmentID, navigator: navigator)
    }

    @MainActor
    private func fragmentPlaybackVisibility(for fragmentID: String, navigator: EPUBNavigatorViewController) async -> FragmentPlaybackVisibility {
        let fragmentIDLiteral = javaScriptStringLiteral(fragmentID)
        let script = """
        (() => {
          const element = document.getElementById(\(fragmentIDLiteral));
          if (!element) {
            return 'notVisible';
          }

          const style = window.getComputedStyle(element);
          if (style.display === 'none' || style.visibility === 'hidden') {
            return 'notVisible';
          }

          const rect = element.getBoundingClientRect();
          if (!(rect.bottom > 0 && rect.top < window.innerHeight)) {
            return 'notVisible';
          }

          const topThreshold = window.innerHeight * 0.05;
          return rect.top < topThreshold ? 'visibleNeedsTopAlignment' : 'visible';
        })();
        """

        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let value) = result,
              let visibility = value as? String
        else {
            return .notVisible
        }

        switch visibility {
        case "visible":
            return .visible
        case "visibleNeedsTopAlignment":
            return .visibleNeedsTopAlignment
        default:
            return .notVisible
        }
    }

    @MainActor
    private func alignCurrentClipTopForPlayback(with navigator: EPUBNavigatorViewController) async {
        guard let currentClip = playback.currentClip,
              let fragmentID = currentClip.fragmentID,
              !fragmentID.isEmpty
        else {
            return
        }

        _ = await alignFragmentTopForPlayback(fragmentID: fragmentID, navigator: navigator)
    }

    @MainActor
    private func alignFragmentTopForPlayback(fragmentID: String, navigator: EPUBNavigatorViewController) async -> String {

        let fragmentIDLiteral = javaScriptStringLiteral(fragmentID)
        let script = """
        (() => {
          const element = document.getElementById(\(fragmentIDLiteral));
          if (!element) {
            return 'missing';
          }

          const style = window.getComputedStyle(element);
          if (style.display === 'none' || style.visibility === 'hidden') {
            return 'missing';
          }

          const rect = element.getBoundingClientRect();
          if (!(rect.bottom > 0 && rect.top < window.innerHeight)) {
            return 'notVisible';
          }

          const targetTop = window.innerHeight * 0.05;
          const delta = rect.top - targetTop;
          if (Math.abs(delta) <= 2) {
            return 'noop';
          }

          window.scrollBy({ top: delta, behavior: 'smooth' });
          return 'scrolled';
        })();
        """

        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let value) = result,
              let action = value as? String
        else {
            return "failed"
        }

        return action
    }

    @MainActor
    private func playFromTappedReference(_ reference: EPUBReference, navigator: EPUBNavigatorViewController) async {
        guard let clipIndex = exactClipIndex(for: reference) else {
            return
        }

        suppressPlaybackRetargetUntilClipChange = false
        suppressNextTapPlaybackNavigation = true
        playback.selectClip(at: clipIndex, autoplay: true, reason: "audioTap")
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
        persistLastPlayedClip()

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
          const topThreshold = window.innerHeight * 0.05;
          const bottomThreshold = window.innerHeight * 0.9;
          let targetTop = null;

          if (rect.top <= topThreshold) {
            targetTop = topThreshold;
          } else if (rect.bottom >= bottomThreshold) {
            targetTop = window.innerHeight * 0.15;
          }

          if (targetTop !== null) {
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

    @MainActor
    private func beginProgrammaticPlaybackScroll(kind: ProgrammaticPlaybackScrollKind, target: EPUBReference) {
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
           let visibleTarget = await firstPlayableFragmentIDInViewport(
            fragmentIDs: playableIDs,
            navigator: navigator
           ),
            let visibleClipIndex = exactClipIndex(for: EPUBReference(
            resourceHref: visibleResourceHref,
            fragmentID: visibleTarget.fragmentID
             )) {
            return PlaybackStartTarget(clipIndex: visibleClipIndex, shouldNavigate: false, shouldAlignToTop: visibleTarget.shouldAlignToTop)
        }

        if !playableIDs.isEmpty,
           let beforeFragmentID = await firstPlayableFragmentIDBeforeViewport(
            fragmentIDs: playableIDs,
            navigator: navigator
           ),
           let beforeClipIndex = exactClipIndex(for: EPUBReference(
            resourceHref: visibleResourceHref,
            fragmentID: beforeFragmentID
            )) {
            return PlaybackStartTarget(clipIndex: beforeClipIndex, shouldNavigate: true, shouldAlignToTop: false)
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
            return PlaybackStartTarget(clipIndex: forwardClipIndex, shouldNavigate: true, shouldAlignToTop: false)
        }

        if let laterClipIndex = firstClipIndex(afterResourceHref: visibleResourceHref) {
            return PlaybackStartTarget(clipIndex: laterClipIndex, shouldNavigate: true, shouldAlignToTop: false)
        }

        return nil
    }

    @MainActor
    private func firstPlayableFragmentIDInViewport(
        fragmentIDs: [String],
        navigator: EPUBNavigatorViewController
    ) async -> VisibleFragmentTarget? {
        let fragmentIDsLiteral = javaScriptArrayLiteral(fragmentIDs)
        let script = """
        (() => {
          const fragmentIDs = \(fragmentIDsLiteral);
          const topThreshold = window.innerHeight * 0.05;

          const topIntersectingViewport = element => {
            if (!element) {
              return null;
            }

            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') {
              return null;
            }

            const rect = element.getBoundingClientRect();
            if (!(rect.bottom > 0 && rect.top < window.innerHeight)) {
              return null;
            }

            return {
              top: rect.top,
              needsTopAlignment: rect.top < topThreshold
            };
          };

          let firstVisible = null;
          for (const fragmentID of fragmentIDs) {
            const element = document.getElementById(fragmentID);
            const visiblePosition = topIntersectingViewport(element);
            if (visiblePosition === null) {
              continue;
            }

            if (!firstVisible || visiblePosition.top < firstVisible.top) {
              firstVisible = {
                top: visiblePosition.top,
                fragmentID,
                needsTopAlignment: visiblePosition.needsTopAlignment
              };
            }
          }

          return firstVisible ? [firstVisible.fragmentID, firstVisible.needsTopAlignment] : null;
        })();
        """

        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let value) = result,
              let payload = value as? [Any],
              payload.count == 2,
              let fragmentID = payload[0] as? String,
              !fragmentID.isEmpty
        else {
            return nil
        }

        let shouldAlignToTop = payload[1] as? Bool ?? false
        return VisibleFragmentTarget(fragmentID: fragmentID, shouldAlignToTop: shouldAlignToTop)
    }

    @MainActor
    private func firstPlayableFragmentIDBeforeViewport(
        fragmentIDs: [String],
        navigator: EPUBNavigatorViewController
    ) async -> String? {
        let fragmentIDsLiteral = javaScriptArrayLiteral(fragmentIDs)
        let script = """
        (() => {
          const fragmentIDs = \(fragmentIDsLiteral);

          let nearestBefore = null;
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
            if (rect.bottom > 0) {
              continue;
            }

            if (!nearestBefore || rect.bottom > nearestBefore.bottom) {
              nearestBefore = { bottom: rect.bottom, fragmentID };
            }
          }

          return nearestBefore?.fragmentID ?? null;
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
                    style: .highlight(
                        tint: ReaderSettings.uiColor(from: readerReadAloudColorRawValue),
                        isActive: true
                    )
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

private enum FragmentPlaybackVisibility: CustomStringConvertible, Equatable {
    case notVisible
    case visible
    case visibleNeedsTopAlignment

    var description: String {
        switch self {
        case .notVisible:
            return "notVisible"
        case .visible:
            return "visible"
        case .visibleNeedsTopAlignment:
            return "visibleNeedsTopAlignment"
        }
    }
}

private struct VisibleFragmentTarget {
    let fragmentID: String
    let shouldAlignToTop: Bool
}

private struct PlaybackStartTarget {
    let clipIndex: Int
    let shouldNavigate: Bool
    let shouldAlignToTop: Bool
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
    @Binding var playbackSpeed: Double
    @Binding var fontSize: Double
    @Binding var isSpeedControlPresented: Bool
    @Binding var isReaderSettingsControlPresented: Bool
    let toggleSpeedControl: () -> Void
    let toggleReaderSettingsControl: () -> Void
    let playPause: () -> Void
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSpeedControlPresented || isReaderSettingsControlPresented {
                Group {
                    if isSpeedControlPresented {
                        PlaybackSpeedControlPanel(playbackSpeed: $playbackSpeed)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if isReaderSettingsControlPresented {
                        ReaderTypographyControlPanel(fontSize: $fontSize)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 0) {
                Button(action: toggleSpeedControl) {
                    Text(ReaderSettings.playbackSpeedText(playbackSpeed))
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button(action: previous) {
                    Image(systemName: "backward.fill")
                }
                .disabled(playback.currentClipIndex == nil || playback.currentClipIndex == 0)
                .frame(maxWidth: .infinity)

                Button(action: playPause) {
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 36)
                        .background(.blue, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button(action: next) {
                    Image(systemName: "forward.fill")
                }
                .disabled(!canGoForward)
                .frame(maxWidth: .infinity)

                Button(action: toggleReaderSettingsControl) {
                    Image(systemName: "textformat.size")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 36)
                        .background(Color(uiColor: .secondarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .animation(.easeInOut(duration: 0.2), value: isSpeedControlPresented)
        .animation(.easeInOut(duration: 0.2), value: isReaderSettingsControlPresented)
    }

    private var canGoForward: Bool {
        guard let currentClipIndex = playback.currentClipIndex else {
            return false
        }
        return currentClipIndex < playback.clips.count - 1
    }
}

private struct PlaybackSpeedControlPanel: View {
    @Binding var playbackSpeed: Double

    var body: some View {
        ReaderControlPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Playback Speed")
                        .font(.subheadline.weight(.semibold))

                    Spacer(minLength: 12)

                    Text(ReaderSettings.playbackSpeedText(playbackSpeed))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { ReaderSettings.normalizedPlaybackSpeed(playbackSpeed) },
                        set: { playbackSpeed = ReaderSettings.normalizedPlaybackSpeed($0) }
                    ),
                    in: ReaderSettings.playbackSpeedRange,
                    step: ReaderSettings.playbackSpeedStep
                )
            }
        }
    }
}

private struct ReaderTypographyControlPanel: View {
    @Binding var fontSize: Double

    var body: some View {
        ReaderControlPanel {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Font Size")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(fontSize.formatted(.number.precision(.fractionLength(1))))
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { ReaderSettings.normalizedFontSize(fontSize) },
                            set: { fontSize = ReaderSettings.normalizedFontSize($0) }
                        ),
                        in: ReaderSettings.fontSizeRange,
                        step: ReaderSettings.fontSizeStep
                    )
                }
            }
        }
    }
}

private struct ReaderControlPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.black.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
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
        private enum BoundaryEdge {
            case top
            case bottom
        }

        var onLocationDidChange: (Locator) -> Void
        var onViewportDidChange: () -> Void
        var onAudioTap: (EPUBReference) -> Void
        private weak var navigator: EPUBNavigatorViewController?
        private var panRecognizer: UIPanGestureRecognizer?
        private var currentViewport: EPUBNavigatorViewController.Viewport?
        private var armedBoundaryEdge: BoundaryEdge?
        private var boundaryPanStartEdge: BoundaryEdge?
        private var boundaryPanReachedEdge: BoundaryEdge?
        private var boundaryPanStartedWithArmedEdge = false
        private var lastBoundaryNavigationDate: Date?
        private let boundaryPullThreshold: CGFloat = 100
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
            if let currentBoundaryEdge = currentBoundaryEdge() {
                boundaryPanReachedEdge = currentBoundaryEdge
            } else if currentBoundaryEdge() != armedBoundaryEdge {
                armedBoundaryEdge = nil
            }
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
            switch gestureRecognizer.state {
            case .began:
                boundaryPanStartEdge = currentBoundaryEdge()
                boundaryPanReachedEdge = boundaryPanStartEdge
                boundaryPanStartedWithArmedEdge = boundaryPanStartEdge == armedBoundaryEdge

            case .changed:
                if let currentBoundaryEdge = currentBoundaryEdge() {
                    boundaryPanReachedEdge = currentBoundaryEdge
                }

            case .ended:
                defer {
                    boundaryPanStartEdge = nil
                    boundaryPanReachedEdge = nil
                    boundaryPanStartedWithArmedEdge = false
                }

                guard let targetBoundaryEdge = boundaryPanReachedEdge ?? currentBoundaryEdge() else {
                    armedBoundaryEdge = nil
                    return
                }

                let translation = gestureRecognizer.translation(in: gestureRecognizer.view)
                let isVerticalPull = abs(translation.y) > abs(translation.x)
                let isPullingTowardBoundary =
                    (targetBoundaryEdge == .bottom && translation.y < 0) ||
                    (targetBoundaryEdge == .top && translation.y > 0)

                guard isVerticalPull, isPullingTowardBoundary else {
                    armedBoundaryEdge = currentBoundaryEdge() == targetBoundaryEdge ? targetBoundaryEdge : nil
                    return
                }

                guard boundaryPanStartedWithArmedEdge,
                      boundaryPanStartEdge == targetBoundaryEdge,
                      abs(translation.y) >= boundaryPullThreshold,
                      canTriggerBoundaryNavigation(),
                      let navigator
                else {
                    armedBoundaryEdge = targetBoundaryEdge
                    return
                }

                armedBoundaryEdge = nil

                if targetBoundaryEdge == .bottom {
                    triggerBoundaryNavigation { await navigator.goForward(options: .animated) }
                } else {
                    triggerBoundaryNavigation { await navigator.goBackward(options: .animated) }
                }

            case .cancelled, .failed:
                boundaryPanStartEdge = nil
                boundaryPanReachedEdge = nil
                boundaryPanStartedWithArmedEdge = false

            default:
                break
            }
        }

        private func currentBoundaryEdge() -> BoundaryEdge? {
            guard let viewport = currentViewport,
                  let href = viewport.readingOrder.first,
                  let progression = viewport.progressions[href]
            else {
                return nil
            }

            if progression.upperBound >= boundaryProgressThreshold {
                return .bottom
            }

            if progression.lowerBound <= (1 - boundaryProgressThreshold) {
                return .top
            }

            return nil
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
