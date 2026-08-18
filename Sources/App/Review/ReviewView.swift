import AVKit
import SwiftUI

/// AppKit's AVPlayerView, not SwiftUI's VideoPlayer: the latter crashes on init in a
/// SwiftPM-only bundle (`_AVKit_SwiftUI` getSuperclassMetadata → fatalError).
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

struct ReviewView: View {
    let fileURL: URL
    @ObservedObject var appState: AppState

    @StateObject private var controller: PlayerController
    @State private var trim = TrimRange(duration: 0)
    @State private var fullScreen = PreviewWindowPresenter()

    init(fileURL: URL, appState: AppState) {
        self.fileURL = fileURL
        self.appState = appState
        _controller = StateObject(wrappedValue: PlayerController(url: fileURL))
    }

    var body: some View {
        VStack(spacing: 12) {
            if let notice = appState.endedEarlyNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            PlayerSurface(player: controller.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Button { openFullScreen() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .padding(6)
                            .background(.black.opacity(0.55), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help("Full screen")
                }

            HStack(spacing: 16) {
                Button { controller.skip(by: -10) } label: { Image(systemName: "gobackward.10") }
                Button { controller.togglePlay() } label: {
                    Image(systemName: playPauseIcon)
                }
                .keyboardShortcut(.space, modifiers: [])
                Button { controller.skip(by: 10) } label: { Image(systemName: "goforward.10") }
                Spacer()
                Text(fileInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.duration > 0 {
                TrimScrubberView(currentTime: controller.currentTime, trim: $trim,
                                 onSeek: { controller.seek(to: $0) })
            }

            HStack {
                Button("Retake") { appState.discardRecording(at: fileURL) }
                Spacer()
                Button("Save") {
                    controller.teardown()
                    appState.keepInLibrary()
                }
                Button("Upload") {
                    controller.teardown()
                    let effectiveTrim = trim.isNoop ? nil : trim
                    appState.reviewTrim = effectiveTrim
                    appState.beginUpload(entryId: appState.reviewingEntryId ?? "",
                                         fileURL: fileURL, trim: effectiveTrim)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onChange(of: controller.duration) { _, newDuration in
            guard newDuration > 0, trim.duration == 0 else { return }
            trim = TrimRange(duration: newDuration)
        }
        .onDisappear { controller.teardown() }
    }

    private var fileInfo: String {
        let size = ByteCountFormatter.string(fromByteCount: controller.fileSizeBytes, countStyle: .file)
        let seconds = Int(controller.duration.rounded())
        return "\(size) · \(String(format: "%d:%02d", seconds / 60, seconds % 60))"
    }

    private var playPauseIcon: String {
        if controller.didFinish { return "arrow.counterclockwise" }
        return controller.isPlaying ? "pause.fill" : "play.fill"
    }

    private func openFullScreen() {
        if controller.isPlaying { controller.togglePlay() }   // avoid two copies playing at once
        fullScreen.present(url: fileURL, startAt: controller.currentTime)
    }
}
