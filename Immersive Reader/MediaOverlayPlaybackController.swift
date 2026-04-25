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

    private var player: AVPlayer?
    private var boundaryObserver: Any?
    private var endObserver: NSObjectProtocol?

    var currentClip: EPUBMediaOverlayClip? {
        guard let currentClipIndex, clips.indices.contains(currentClipIndex) else {
            return nil
        }
        return clips[currentClipIndex]
    }

    var currentClipNumberText: String {
        guard let currentClipIndex else { return "0 of \(clips.count)" }
        return "\(currentClipIndex + 1) of \(clips.count)"
    }

    func load(from jsonPath: String?) {
        stop()

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
            currentClipIndex = clips.isEmpty ? nil : 0
            state = clips.isEmpty ? .unavailable : .ready
        } catch {
            clips = []
            currentClipIndex = nil
            state = .failed(error.localizedDescription)
        }
    }

    func togglePlayback() {
        if state.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
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

        start(clip)
    }

    func pause() {
        player?.pause()
        deactivateAudioSession()
        if clips.isEmpty {
            state = .unavailable
        } else {
            state = .paused
        }
    }

    func stop() {
        player?.pause()
        removeObservers()
        player = nil
        deactivateAudioSession()
        currentClipIndex = clips.isEmpty ? nil : currentClipIndex
        state = clips.isEmpty ? .unavailable : .ready
    }

    func previousClip() {
        guard let currentClipIndex, currentClipIndex > 0 else {
            return
        }
        self.currentClipIndex = currentClipIndex - 1
        if state.isPlaying {
            play()
        }
    }

    func nextClip() {
        guard let currentClipIndex else {
            return
        }

        let nextIndex = clips.index(after: currentClipIndex)
        guard clips.indices.contains(nextIndex) else {
            player?.pause()
            removeObservers()
            deactivateAudioSession()
            state = .ready
            return
        }

        self.currentClipIndex = nextIndex
        if state.isPlaying {
            play()
        }
    }

    private func start(_ clip: EPUBMediaOverlayClip) {
        removeObservers()

        do {
            try configureAudioSession()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let player = AVPlayer(url: URL(fileURLWithPath: clip.audioPath))
        self.player = player
        player.seek(to: CMTime(seconds: clip.clipBegin, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, clip, player] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.addObservers(for: clip)
                player.play()
                self.state = .playing
            }
        }
    }

    private func addObservers(for clip: EPUBMediaOverlayClip) {
        guard let player else { return }

        if let clipEnd = clip.clipEnd, clipEnd > clip.clipBegin {
            boundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: clipEnd, preferredTimescale: 600))],
                queue: .main
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.nextClip()
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
                    self?.nextClip()
                }
            }
        }
    }

    private func removeObservers() {
        if let boundaryObserver, let player {
            player.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
