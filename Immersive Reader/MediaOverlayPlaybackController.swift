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
        logPlaybackEvent("load.begin", extra: "jsonPath=\(jsonPath ?? "nil")")
        stop(reason: "load")

        guard let jsonPath else {
            state = .unavailable
            clips = []
            currentClipIndex = nil
            logPlaybackEvent("load.noManifest")
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
            logPlaybackEvent(
                "load.completed",
                clip: currentClip,
                extra: "clipCount=\(clips.count) currentClipIndex=\(String(describing: currentClipIndex)) state=\(String(describing: state))"
            )
        } catch {
            clips = []
            currentClipIndex = nil
            state = .failed(error.localizedDescription)
            logPlaybackEvent("load.failed", extra: "error=\(error.localizedDescription)")
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
            logPlaybackEvent("play.aborted", reason: reason, extra: "state=\(String(describing: state)) clipCount=0")
            return
        }

        if currentClipIndex == nil {
            currentClipIndex = 0
        }

        guard let clip = currentClip else {
            state = .unavailable
            logPlaybackEvent("play.aborted", reason: reason, extra: "state=\(String(describing: state)) currentClipIndex=nil")
            return
        }

        let transitionID = nextPlaybackTransitionID()
        currentTransitionID = transitionID
        logPlaybackEvent(
            "play",
            clip: clip,
            reason: reason,
            transitionID: transitionID,
            extra: "currentClipIndex=\(String(describing: currentClipIndex)) state=\(String(describing: state)) \(playerSnapshot())"
        )
        start(clip, reason: reason, transitionID: transitionID)
    }

    func pause(reason: String = "directPause") {
        logPlaybackEvent(
            "pause",
            clip: currentClip,
            reason: reason,
            transitionID: currentTransitionID,
            extra: "currentClipIndex=\(String(describing: currentClipIndex)) \(playerSnapshot())"
        )
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
        logPlaybackEvent(
            "stop",
            clip: currentClip,
            reason: reason,
            transitionID: currentTransitionID,
            extra: "currentClipIndex=\(String(describing: currentClipIndex)) \(playerSnapshot())"
        )
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
            logPlaybackEvent("previousClip.ignored", clip: currentClip, reason: reason, transitionID: currentTransitionID)
            return
        }
        logPlaybackEvent(
            "previousClip",
            clip: currentClip,
            reason: reason,
            transitionID: currentTransitionID,
            extra: "fromIndex=\(currentClipIndex) toIndex=\(currentClipIndex - 1)"
        )
        self.currentClipIndex = currentClipIndex - 1
        if state.isPlaying {
            play(reason: "previousClip[\(reason)]")
        }
    }

    func nextClip(reason: String = "manualNext") {
        guard let currentClipIndex else {
            logPlaybackEvent("nextClip.ignored", reason: reason, transitionID: currentTransitionID, extra: "currentClipIndex=nil")
            return
        }

        guard let currentClip = currentClip else {
            logPlaybackEvent("nextClip.ignored", reason: reason, transitionID: currentTransitionID, extra: "currentClip=nil")
            return
        }

        let nextIndex = clips.index(after: currentClipIndex)
        logPlaybackEvent(
            "nextClip",
            clip: currentClip,
            reason: reason,
            transitionID: currentTransitionID,
            extra: "fromIndex=\(currentClipIndex) candidateNextIndex=\(nextIndex) isPlaying=\(state.isPlaying) \(playerSnapshot())"
        )
        guard clips.indices.contains(nextIndex) else {
            player?.pause()
            removeObservers(reason: "nextClip.noNext[\(reason)]")
            deactivateAudioSession(reason: "nextClip.noNext[\(reason)]")
            currentTransitionID = nil
            state = .ready
            logPlaybackEvent("nextClip.reachedEnd", clip: currentClip, reason: reason, extra: "fromIndex=\(currentClipIndex)")
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
            logPlaybackEvent("selectClip.ignored", reason: reason, transitionID: currentTransitionID, extra: "targetIndex=\(index) clipCount=\(clips.count)")
            return
        }

        logPlaybackEvent(
            "selectClip",
            clip: clips[index],
            reason: reason,
            transitionID: currentTransitionID,
            extra: "targetIndex=\(index) autoplay=\(autoplay) previousIndex=\(String(describing: currentClipIndex)) \(playerSnapshot())"
        )
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
        logPlaybackEvent(
            "setPlaybackRate",
            clip: currentClip,
            transitionID: currentTransitionID,
            extra: "playbackRate=\(formattedSeconds(normalizedRate)) state=\(String(describing: state))"
        )
        applyPlaybackRateIfNeeded(shouldUpdateActiveRate: state.isPlaying, reason: "setPlaybackRate")
    }

    private func start(_ clip: EPUBMediaOverlayClip, reason: String, transitionID: Int) {
        logPlaybackEvent(
            "start",
            clip: clip,
            reason: reason,
            transitionID: transitionID,
            extra: "currentClipIndex=\(String(describing: currentClipIndex)) loadedAudioPath=\(loadedAudioPath ?? "nil") \(playerSnapshot())"
        )
        removeObservers(reason: "start[\(reason)]")

        do {
            try configureAudioSession()
        } catch {
            state = .failed(error.localizedDescription)
            logPlaybackEvent("start.failedAudioSession", clip: clip, reason: reason, transitionID: transitionID, extra: "error=\(error.localizedDescription)")
            return
        }

        let player = preparedPlayer(for: clip)
        player.pause()
        player.seek(to: CMTime(seconds: clip.clipBegin, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, clip, player] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.isCurrentClip(clip) else {
                    self.logPlaybackEvent(
                        "seekCompleted.ignoredStaleClip",
                        clip: clip,
                        reason: reason,
                        transitionID: transitionID,
                        extra: "currentClipIndex=\(String(describing: self.currentClipIndex)) currentTransitionID=\(String(describing: self.currentTransitionID)) \(self.playerSnapshot())"
                    )
                    return
                }

                guard self.currentTransitionID == transitionID else {
                    self.logPlaybackEvent(
                        "seekCompleted.ignoredStaleTransition",
                        clip: clip,
                        reason: reason,
                        transitionID: transitionID,
                        extra: "currentTransitionID=\(String(describing: self.currentTransitionID)) currentClipIndex=\(String(describing: self.currentClipIndex)) \(self.playerSnapshot())"
                    )
                    return
                }

                self.logPlaybackEvent(
                    "seekCompleted",
                    clip: clip,
                    reason: reason,
                    transitionID: transitionID,
                    extra: "currentClipIndex=\(String(describing: self.currentClipIndex)) \(self.playerSnapshot())"
                )
                self.addObservers(for: clip, reason: reason, transitionID: transitionID)
                player.play()
                self.state = .playing
                self.applyPlaybackRateIfNeeded(
                    player: player,
                    shouldUpdateActiveRate: true,
                    reason: "start[\(reason)]",
                    transitionID: transitionID
                )
                self.logPlaybackEvent(
                    "player.playInvoked",
                    clip: clip,
                    reason: reason,
                    transitionID: transitionID,
                    extra: "currentClipIndex=\(String(describing: self.currentClipIndex)) playbackRate=\(formattedSeconds(self.playbackRate)) \(self.playerSnapshot())"
                )
            }
        }
    }

    private func preparedPlayer(for clip: EPUBMediaOverlayClip) -> AVPlayer {
        if let player,
           loadedAudioPath == clip.audioPath,
           player.currentItem != nil {
            logPlaybackEvent("preparedPlayer.reuseCurrentItem", clip: clip, transitionID: currentTransitionID, extra: playerSnapshot(player: player))
            return player
        }

        let item = AVPlayerItem(url: URL(fileURLWithPath: clip.audioPath))
        item.audioTimePitchAlgorithm = .timeDomain

        if let player {
            logPlaybackEvent("preparedPlayer.replaceCurrentItem", clip: clip, transitionID: currentTransitionID, extra: playerSnapshot(player: player))
            player.replaceCurrentItem(with: item)
            loadedAudioPath = clip.audioPath
            return player
        }

        logPlaybackEvent("preparedPlayer.createPlayer", clip: clip, transitionID: currentTransitionID)
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
        logPlaybackEvent(
            "applyPlaybackRate",
            clip: currentClip,
            reason: reason,
            transitionID: transitionID ?? currentTransitionID,
            extra: "playbackRate=\(formattedSeconds(playbackRate)) \(playerSnapshot(player: player))"
        )
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
            logPlaybackEvent(
                "addBoundaryObserver",
                clip: clip,
                reason: reason,
                transitionID: transitionID,
                extra: "clipEnd=\(clipEnd) observerTime=\(formattedSeconds(clipEnd))"
            )
            boundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: clipEnd, preferredTimescale: 600))],
                queue: .main
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.logPlaybackEvent(
                        "boundaryObserverFired",
                        clip: clip,
                        reason: reason,
                        transitionID: transitionID,
                        extra: self?.playerSnapshot() ?? "player=nil"
                    )
                    self?.nextClip(reason: "boundaryObserver transitionID=\(transitionID)")
                }
            }
        }

        if clip.clipEnd == nil, let item = player.currentItem {
            logPlaybackEvent("addItemEndObserver", clip: clip, reason: reason, transitionID: transitionID)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.logPlaybackEvent(
                        "itemEndObserverFired",
                        clip: clip,
                        reason: reason,
                        transitionID: transitionID,
                        extra: self?.playerSnapshot() ?? "player=nil"
                    )
                    self?.nextClip(reason: "itemEndObserver transitionID=\(transitionID)")
                }
            }
        }
    }

    private func removeObservers(reason: String) {
        if boundaryObserver != nil || endObserver != nil {
            logPlaybackEvent(
                "removeObservers",
                clip: currentClip,
                reason: reason,
                transitionID: currentTransitionID,
                extra: "hadBoundaryObserver=\(boundaryObserver != nil) hadEndObserver=\(endObserver != nil)"
            )
        }

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
        logPlaybackEvent(
            "continueSameAudioWithoutSeek",
            clip: nextClip,
            reason: reason,
            transitionID: transitionID,
            extra: "fromIndex=\(fromIndex) toIndex=\(toIndex) currentTime=\(formattedSeconds(currentTime)) boundaryDelta=\(formattedSeconds(currentTime - nextClip.clipBegin))"
        )
        addObservers(for: nextClip, reason: "continueSameAudioWithoutSeek[\(reason)]", transitionID: transitionID)
        state = .playing
        return true
    }

    private func isAutomaticAdvanceReason(_ reason: String) -> Bool {
        reason.hasPrefix("boundaryObserver") || reason.hasPrefix("itemEndObserver")
    }

    private func logPlaybackEvent(
        _ event: String,
        clip: EPUBMediaOverlayClip? = nil,
        reason: String? = nil,
        transitionID: Int? = nil,
        extra: String? = nil
    ) {
        var parts: [String] = ["[Playback \(PlaybackDiagnostics.timestamp())] \(event)"]

        if let reason {
            parts.append("reason=\(reason)")
        }

        if let transitionID {
            parts.append("transitionID=\(transitionID)")
        }

        if let clip {
            let audioName = URL(fileURLWithPath: clip.audioPath).lastPathComponent
            parts.append(
                "clip(fragment=\(clip.fragmentID ?? "nil") href=\(clip.textResourceHref) begin=\(formattedSeconds(clip.clipBegin)) end=\(formattedOptionalSeconds(clip.clipEnd)) audio=\(audioName))"
            )
        } else {
            parts.append("clip=nil")
        }

        if let extra {
            parts.append(extra)
        }

        print(parts.joined(separator: " | "))
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func deactivateAudioSession(reason: String) {
        logPlaybackEvent("deactivateAudioSession", clip: currentClip, reason: reason, transitionID: currentTransitionID)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func nextPlaybackTransitionID() -> Int {
        Self.nextTransitionID += 1
        return Self.nextTransitionID
    }

    private func playerSnapshot(player: AVPlayer? = nil) -> String {
        guard let player = player ?? self.player else {
            return "player=nil"
        }

        let timeControlStatus: String
        switch player.timeControlStatus {
        case .paused:
            timeControlStatus = "paused"
        case .waitingToPlayAtSpecifiedRate:
            timeControlStatus = "waiting"
        case .playing:
            timeControlStatus = "playing"
        @unknown default:
            timeControlStatus = "unknown"
        }

        let itemStatus: String
        switch player.currentItem?.status {
        case .readyToPlay:
            itemStatus = "readyToPlay"
        case .failed:
            itemStatus = "failed"
        case .unknown, .none:
            itemStatus = "unknown"
        @unknown default:
            itemStatus = "unknownFuture"
        }

        return "playerTime=\(formattedTime(player.currentTime())) rate=\(formattedSeconds(Double(player.rate))) timeControlStatus=\(timeControlStatus) itemStatus=\(itemStatus) loadedAudioPath=\(loadedAudioPath ?? "nil")"
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

enum PlaybackDiagnostics {
    static func timestamp() -> String {
        formattedSeconds(Date().timeIntervalSince1970)
    }
}

private func formattedOptionalSeconds(_ value: Double?) -> String {
    guard let value else { return "nil" }
    return formattedSeconds(value)
}

private func formattedTime(_ value: CMTime) -> String {
    formattedSeconds(value.seconds)
}

private func formattedSeconds(_ value: Double) -> String {
    guard value.isFinite else { return "nan" }
    return String(format: "%.3f", value)
}
