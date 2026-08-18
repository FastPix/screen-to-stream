import CoreMedia
import CoreVideo
import Foundation

enum AudioSource {
    case system
    case microphone
}

enum SinkResult {
    case file(URL)
}

/// Where composed frames go. The capture pipeline knows nothing beyond this.
protocol MediaSink: AnyObject {
    func start(at pts: CMTime) throws
    func append(video: CVPixelBuffer, pts: CMTime)
    func append(audio: CMSampleBuffer, source: AudioSource)
    func finish() async throws -> SinkResult
}
