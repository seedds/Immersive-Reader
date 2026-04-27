//
//  MediaOverlayPlaybackController.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class MediaOverlayPlaybackController: ObservableObject {
    enum State: Equatable {
        case unavailable
        case ready
        case playing
        case paused
        case failed(String)

        var isPlaying: Bool {
            if case .playing = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .unavailable
    @Published private(set) var clips: [EPUBMediaOverlayClip] = []
    @Published private(set) var currentClipIndex: Int?

    private static var nextTransitionID: Int = 0
    private let seamlessAutoAdvanceTolerance: Double = 0.1
    private var playbackRate = ReaderSettings.defaultPlaybackSpeed

    private var player: AVPlayer?
    private var loadedAudioPath: String?
    private var boundaryObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var currentTransitionID: Int?

    var currentClip: EPUBMediaOverlayClip? {
        guard let currentClipIndex, clips.indices.contains(currentClipIndex) else {
            return nil
        }
        return clips[currentClipIndex]
    }

    func load(from jsonPath: String?) {
        stop(reason: "load")

        guard let jsonPath else {
            state = .unavailable
            clips = []
            currentClipIndex = nil
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            let manifest = try JSONDecoder().decode(EPUBMediaOverlayManifest.self, from: data)
            clips = manifest.documents.flatMap(\.clips).filter { clip in
                FileManager.default.fileExists(atPath: clip.audioPath)
            }
            currentClipIndex = nil
            state = clips.isEmpty ? .unavailable : .ready
        } catch {
            clips = []
            currentClipIndex = nil
            state = .failed(error.localizedDescription)
        }
    }

    func togglePlayback() {
        if state.isPlaying {
            pause(reason: "togglePlayback")
        } else {
            play(reason: "togglePlayback")
        }
    }

    func play(reason: String = "directPlay") {
        guard !clips.isEmpty else {
            state = .unavailable
            return
        }

        if currentClipIndex == nil {
            currentClipIndex = 0
        }

        guard let clip = currentClip else {
            state = .unavailable
            return
        }

        let transitionID = nextPlaybackTransitionID()
        currentTransitionID = transitionID
        start(clip, reason: reason, transitionID: transitionID)
    }

    func pause(reason: String = "directPause") {
        player?.pause()
        deactivateAudioSession(reason: "pause[\(reason)]")
        currentTransitionID = nil
        if clips.isEmpty {
            state = .unavailable
        } else {
            state = .paused
        }
    }

    func stop(reason: String = "directStop") {
        player?.pause()
        removeObservers(reason: "stop[\(reason)]")
        player = nil
        loadedAudioPath = nil
        deactivateAudioSession(reason: "stop[\(reason)]")
        currentTransitionID = nil
        currentClipIndex = clips.isEmpty ? nil : currentClipIndex
        state = clips.isEmpty ? .unavailable : .ready
    }

    func previousClip(reason: String = "manualPrevious") {
        guard let currentClipIndex, currentClipIndex > 0 else {
            return
        }
        self.currentClipIndex = currentClipIndex - 1
        if state.isPlaying {
            play(reason: "previousClip[\(reason)]")
        }
    }

    func nextClip(reason: String = "manualNext") {
        guard let currentClipIndex else {
            return
        }

        guard let currentClip = currentClip else {
            return
        }

        let nextIndex = clips.index(after: currentClipIndex)
        guard clips.indices.contains(nextIndex) else {
            player?.pause()
            removeObservers(reason: "nextClip.noNext[\(reason)]")
            deactivateAudioSession(reason: "nextClip.noNext[\(reason)]")
            currentTransitionID = nil
            state = .ready
            return
        }

        let nextClip = clips[nextIndex]
        if continueCurrentItemForAutomaticAdvanceIfPossible(
            from: currentClip,
            to: nextClip,
            fromIndex: currentClipIndex,
            toIndex: nextIndex,
            reason: reason
        ) {
            return
        }

        self.currentClipIndex = nextIndex
        if state.isPlaying {
            play(reason: "nextClip[\(reason)]")
        }
    }

    func selectClip(at index: Int, autoplay: Bool, reason: String = "directSelect") {
        guard clips.indices.contains(index) else {
            return
        }
        player?.pause()
        removeObservers(reason: "selectClip[\(reason)]")
        deactivateAudioSession(reason: "selectClip[\(reason)]")
        currentTransitionID = nil

        currentClipIndex = index

        if autoplay {
            play(reason: "selectClip[\(reason)]")
        } else {
            state = .paused
        }
    }

    func setPlaybackRate(_ rate: Double) {
        let normalizedRate = ReaderSettings.normalizedPlaybackSpeed(rate)
        playbackRate = normalizedRate
        applyPlaybackRateIfNeeded(shouldUpdateActiveRate: state.isPlaying, reason: "setPlaybackRate")
    }

    private func start(_ clip: EPUBMediaOverlayClip, reason: String, transitionID: Int) {
        removeObservers(reason: "start[\(reason)]")

        do {
            try configureAudioSession()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let player = preparedPlayer(for: clip)
        player.pause()
        player.seek(to: CMTime(seconds: clip.clipBegin, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, clip, player] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.isCurrentClip(clip) else {
                    return
                }

                guard self.currentTransitionID == transitionID else {
                    return
                }

                self.addObservers(for: clip, reason: reason, transitionID: transitionID)
                player.play()
                self.state = .playing
                self.applyPlaybackRateIfNeeded(
                    player: player,
                    shouldUpdateActiveRate: true,
                    reason: "start[\(reason)]",
                    transitionID: transitionID
                )
            }
        }
    }

    private func preparedPlayer(for clip: EPUBMediaOverlayClip) -> AVPlayer {
        if let player,
           loadedAudioPath == clip.audioPath,
           player.currentItem != nil {
            return player
        }

        let item = AVPlayerItem(url: URL(fileURLWithPath: clip.audioPath))
        item.audioTimePitchAlgorithm = .timeDomain

        if let player {
            player.replaceCurrentItem(with: item)
            loadedAudioPath = clip.audioPath
            return player
        }

        let player = AVPlayer(playerItem: item)
        self.player = player
        loadedAudioPath = clip.audioPath
        return player
    }

    private func applyPlaybackRateIfNeeded(
        player: AVPlayer? = nil,
        shouldUpdateActiveRate: Bool,
        reason: String,
        transitionID: Int? = nil
    ) {
        guard let player = player ?? self.player else {
            return
        }

        player.currentItem?.audioTimePitchAlgorithm = .timeDomain

        guard shouldUpdateActiveRate else {
            return
        }

        player.rate = Float(playbackRate)
    }

    private func isCurrentClip(_ clip: EPUBMediaOverlayClip) -> Bool {
        guard let currentClip else {
            return false
        }

        return currentClip.audioPath == clip.audioPath &&
            currentClip.textResourceHref == clip.textResourceHref &&
            currentClip.fragmentID == clip.fragmentID &&
            currentClip.clipBegin == clip.clipBegin &&
            currentClip.clipEnd == clip.clipEnd
    }

    private func addObservers(for clip: EPUBMediaOverlayClip, reason: String, transitionID: Int) {
        guard let player else { return }

        if let clipEnd = clip.clipEnd, clipEnd > clip.clipBegin {
            boundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: clipEnd, preferredTimescale: 600))],
                queue: .main
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.nextClip(reason: "boundaryObserver transitionID=\(transitionID)")
                }
            }
        }

        if clip.clipEnd == nil, let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.nextClip(reason: "itemEndObserver transitionID=\(transitionID)")
                }
            }
        }
    }

    private func removeObservers(reason: String) {
        if let boundaryObserver, let player {
            player.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func continueCurrentItemForAutomaticAdvanceIfPossible(
        from currentClip: EPUBMediaOverlayClip,
        to nextClip: EPUBMediaOverlayClip,
        fromIndex: Int,
        toIndex: Int,
        reason: String
    ) -> Bool {
        guard state.isPlaying,
              isAutomaticAdvanceReason(reason),
              let player,
              player.currentItem != nil,
              currentClip.audioPath == nextClip.audioPath,
              loadedAudioPath == nextClip.audioPath,
              let currentClipEnd = currentClip.clipEnd,
              abs(currentClipEnd - nextClip.clipBegin) <= seamlessAutoAdvanceTolerance
        else {
            return false
        }

        let currentTime = player.currentTime().seconds
        guard currentTime.isFinite,
              abs(currentTime - nextClip.clipBegin) <= seamlessAutoAdvanceTolerance
        else {
            return false
        }

        removeObservers(reason: "continueSameAudioWithoutSeek[\(reason)]")
        currentClipIndex = toIndex

        let transitionID = nextPlaybackTransitionID()
        currentTransitionID = transitionID
        addObservers(for: nextClip, reason: "continueSameAudioWithoutSeek[\(reason)]", transitionID: transitionID)
        state = .playing
        return true
    }

    private func isAutomaticAdvanceReason(_ reason: String) -> Bool {
        reason.hasPrefix("boundaryObserver") || reason.hasPrefix("itemEndObserver")
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func deactivateAudioSession(reason: String) {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func nextPlaybackTransitionID() -> Int {
        Self.nextTransitionID += 1
        return Self.nextTransitionID
    }

    deinit {
        let player = player
        let boundaryObserver = boundaryObserver
        let endObserver = endObserver
        DispatchQueue.main.async {
            if let boundaryObserver, let player {
                player.removeTimeObserver(boundaryObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
        }
    }
}
