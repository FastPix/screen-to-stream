import AVKit
import AppKit
import CoreMedia

/// Opens the recording in a large resizable window with native transport controls and enters
/// macOS full screen.
@MainActor
final class PreviewWindowPresenter {
    private var window: NSWindow?

    func present(url: URL, startAt seconds: Double) {
        let player = AVPlayer(url: url)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))

        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Preview"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = playerView
        window.center()

        NSApp.activate(ignoringOtherApps: true)   // accessory app must activate to take full screen
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        player.play()

        self.window = window
    }
}
