import AppKit
import SwiftUI

/// Floating elapsed-timer + stop control shown while the main panel is hidden.
final class StopPillWindow: NSWindow {
    init(onStop: @escaping () -> Void, elapsed: @escaping () -> TimeInterval) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 44),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        // .statusBar, not .floating: keeps the stop control reachable over full-screen video.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        contentView = NSHostingView(rootView: StopPillView(onStop: onStop, elapsed: elapsed))

        if let screenFrame = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screenFrame.midX - 90, y: screenFrame.maxY - 80))
        }
    }

    func show() {
        orderFrontRegardless()
    }
}

private struct StopPillView: View {
    let onStop: () -> Void
    let elapsed: () -> TimeInterval

    @State private var display = "0:00"
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text(display)
                .font(.system(.body, design: .monospaced))
            Button("Stop", action: onStop)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .onReceive(tick) { _ in
            let seconds = Int(elapsed())
            display = String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
    }
}
