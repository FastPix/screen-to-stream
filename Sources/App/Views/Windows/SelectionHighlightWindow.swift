import AppKit

/// Border drawn around the display or window currently selected in the picker.
final class SelectionHighlightWindow: NSWindow {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let host = NSView()
        host.wantsLayer = true
        host.layer?.borderWidth = 4
        host.layer?.borderColor = NSColor.controlAccentColor.cgColor
        host.layer?.cornerRadius = 6
        contentView = host
    }

    func highlight(_ rect: CGRect) {
        // SCK frames are top-left origin; AppKit windows are bottom-left.
        guard let screenFrame = NSScreen.main?.frame else { return }

        let flipped = CGRect(
            x: rect.minX,
            y: screenFrame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        setFrame(flipped, display: true)
        orderFrontRegardless()
    }

    func clear() {
        orderOut(nil)
    }
}
