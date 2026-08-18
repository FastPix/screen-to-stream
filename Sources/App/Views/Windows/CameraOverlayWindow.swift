import AppKit
import AVFoundation

/// Draggable circular camera preview. Its on-screen position is what the compositor mirrors for the PiP.
final class CameraOverlayWindow: NSWindow {
    /// Fires with the normalized center whenever the circle is dragged.
    var onMove: ((CGPoint) -> Void)?

    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession, diameter: CGFloat = 160) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false   // ARC owns it; teardown() drops the last reference
        // .statusBar, not .floating: full-screen video players sit above .floating and hide the circle.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isMovableByWindowBackground = true

        let host = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        host.wantsLayer = true
        host.layer?.cornerRadius = diameter / 2
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 2
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor

        previewLayer.frame = host.bounds
        previewLayer.videoGravity = .resizeAspectFill
        // Mirror like a selfie camera; the compositor applies the same flip to the video.
        previewLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        host.layer?.addSublayer(previewLayer)
        contentView = host

        // Caller positions on the target screen right after init.

        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved),
                                               name: NSWindow.didMoveNotification, object: self)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    /// AVCaptureVideoPreviewLayer can stop rendering after a Space/full-screen change while the session
    /// keeps delivering frames; rebinding the session forces a fresh rendering connection.
    /// The isVisible guard is essential: without it a torn-down-but-still-alive overlay resurrects, stacking ghost previews.
    @objc private func activeSpaceChanged() {
        guard isVisible else { return }
        let session = previewLayer.session
        previewLayer.session = nil
        previewLayer.session = session
        orderFrontRegardless()
    }

    /// The shared session retains this layer, so dropping the Swift reference alone leaves the window
    /// alive (and resurrectable on the next Space change); unbinding the session breaks that retain.
    func teardown() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        previewLayer.session = nil
        orderOut(nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func windowMoved() {
        onMove?(normalizedCenter)
    }

    /// Normalized center, screen space, bottom-left origin — what PiPPosition stores and the compositor reads.
    var normalizedCenter: CGPoint {
        guard let screenFrame = screen?.frame ?? NSScreen.main?.frame else {
            return CGPoint(x: 0.85, y: 0.15)
        }

        return CGPoint(
            x: (frame.midX - screenFrame.minX) / screenFrame.width,
            y: (frame.midY - screenFrame.minY) / screenFrame.height
        )
    }

    func show() {
        orderFrontRegardless()
    }

    func positionBottomRight(on screen: NSScreen?) {
        guard let screenFrame = (screen ?? NSScreen.main)?.visibleFrame else { return }

        setFrameOrigin(NSPoint(
            x: screenFrame.maxX - frame.width - 40,
            y: screenFrame.minY + 40
        ))
    }

    /// Clamps the origin so the circle never straddles two displays; a straddling window would
    /// resolve normalizedCenter against the wrong screen.
    func position(atNormalized center: CGPoint, on screen: NSScreen?) {
        guard let screenFrame = (screen ?? NSScreen.main)?.frame else { return }

        let x = screenFrame.minX + center.x * screenFrame.width - frame.width / 2
        let y = screenFrame.minY + center.y * screenFrame.height - frame.height / 2
        setFrameOrigin(NSPoint(
            x: min(max(x, screenFrame.minX), screenFrame.maxX - frame.width),
            y: min(max(y, screenFrame.minY), screenFrame.maxY - frame.height)
        ))
    }

    func move(to screen: NSScreen) {
        position(atNormalized: normalizedCenter, on: screen)
    }
}
