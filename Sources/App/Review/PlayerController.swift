import AVFoundation
import Combine
import Foundation

/// AVPlayer wrapper for the review screen. Publishes time/duration/size for the UI.
@MainActor
final class PlayerController: ObservableObject {
    let player: AVPlayer

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var didFinish: Bool = false
    @Published private(set) var fileSizeBytes: Int64 = 0

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        player = AVPlayer(url: url)

        fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        // @Sendable observer closures: hop through a MainActor Task to mutate actor state.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in self.currentTime = time.seconds }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isPlaying = false
                self.didFinish = true
            }
        }

        Task {
            if let loaded = try? await player.currentItem?.asset.load(.duration) {
                duration = loaded.seconds
            }
        }
    }

    func togglePlay() {
        if didFinish {
            replay()
            return
        }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func replay() {
        didFinish = false
        seek(to: 0)
        player.play()
        isPlaying = true
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), duration)
        didFinish = false
        currentTime = clamped   // sync update; the periodic observer lags tight scrubbing
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func teardown() {
        player.pause()
        isPlaying = false
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}
