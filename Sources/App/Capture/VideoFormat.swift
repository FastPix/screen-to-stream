import CoreMedia

/// Encoder-safe dimensions and bitrate. Hardware HEVC encoders allocate 16-px-aligned buffers;
/// unaligned sizes fail with -12737.
enum VideoFormat {
    static let maxWidth = 3840
    static let maxHeight = 2160

    static func encodeSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
        let scaledWidth = Double(width) * scale
        let scaledHeight = Double(height) * scale

        return (floorTo16(scaledWidth), floorTo16(scaledHeight))
    }

    static func bitrate(width: Int, height: Int) -> Int {
        width * height * 4
    }

    private static func floorTo16(_ value: Double) -> Int {
        max(16, Int(value / 16) * 16)
    }
}

/// Never retime sample buffers: the writer session starts at the first frame's raw PTS; pre-session
/// or non-monotonic buffers are dropped.
struct TimestampPolicy {
    private let sessionStart: CMTime
    private var lastVideoPTS: CMTime?

    init(sessionStart: CMTime) {
        self.sessionStart = sessionStart
    }

    /// Returns the PTS to stamp, or nil to drop the frame. Non-monotonic frames (from a live resize
    /// or a move to a differently-scaled display, where SCK re-delivers duplicate/backward
    /// timestamps) are dropped, not nudged, to keep the encoded frame rate honest.
    mutating func videoPTS(for pts: CMTime) -> CMTime? {
        guard pts >= sessionStart else { return nil }
        if let last = lastVideoPTS, pts <= last { return nil }

        lastVideoPTS = pts
        return pts
    }

    func shouldDropAudio(at pts: CMTime) -> Bool {
        pts < sessionStart
    }
}
