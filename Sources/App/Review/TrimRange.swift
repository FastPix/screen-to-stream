import CoreMedia

/// Non-destructive trim selection for the review screen. Pre-upload export reads `timeRange`.
struct TrimRange: Equatable {
    static let minimumLength = 0.5

    let duration: Double
    private(set) var start: Double
    private(set) var end: Double

    init(duration: Double) {
        self.duration = duration
        self.start = 0
        self.end = duration
    }

    mutating func moveStart(to seconds: Double) {
        start = min(max(0, seconds), end - Self.minimumLength)
    }

    mutating func moveEnd(to seconds: Double) {
        end = max(min(duration, seconds), start + Self.minimumLength)
    }

    var isNoop: Bool { start == 0 && end == duration }
    var trimmedLength: Double { end - start }

    var timeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: trimmedLength, preferredTimescale: 600)
        )
    }
}
