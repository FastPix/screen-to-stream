import CoreGraphics
import Foundation

/// Thread-safe PiP center (normalized, origin bottom-left). Written on the main thread as the
/// overlay is dragged, read on the capture thread per composed frame.
final class PiPPosition: @unchecked Sendable {
    private let lock = NSLock()
    private var _center = CGPoint(x: 0.85, y: 0.15)

    var center: CGPoint {
        get { lock.lock(); defer { lock.unlock() }; return _center }
        set { lock.lock(); _center = newValue; lock.unlock() }
    }
}
