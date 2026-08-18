import CoreMedia
import CoreVideo
import Foundation
@testable import App

final class SpySink: MediaSink {
    private(set) var started: CMTime?
    private(set) var videoPTS: [CMTime] = []
    private(set) var videoSizes: [(width: Int, height: Int)] = []
    private(set) var audio: [(pts: CMTime, source: AudioSource)] = []
    private(set) var finished = false

    func start(at pts: CMTime) throws {
        started = pts
    }

    func append(video: CVPixelBuffer, pts: CMTime) {
        videoPTS.append(pts)
        videoSizes.append((CVPixelBufferGetWidth(video), CVPixelBufferGetHeight(video)))
    }

    func append(audio buffer: CMSampleBuffer, source: AudioSource) {
        audio.append((CMSampleBufferGetPresentationTimeStamp(buffer), source))
    }

    func finish() async throws -> SinkResult {
        finished = true
        return .file(URL(fileURLWithPath: "/dev/null"))
    }
}
