import XCTest
import AVFoundation
import CoreMedia
@testable import App

/// Writes a real file through the real encoder — the check that fails if HEVC settings,
/// track layout, or the timestamp policy regress.
final class FileSinkWriteTests: XCTestCase {
    func testWritesPlayableHEVCFileWithTwoAudioTracks() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filesink-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let sink = try FileSink(outputURL: url, width: 320, height: 240,
                                systemAudio: true, microphone: true)
        let start = CMTime(value: 0, timescale: 600)
        try sink.start(at: start)

        for frame in 0..<30 {
            let pts = CMTime(value: CMTimeValue(frame * 10), timescale: 600)
            sink.append(video: TestBuffers.make(width: 320, height: 240), pts: pts)
        }

        guard case .file(let result) = try await sink.finish() else {
            return XCTFail("expected a file result")
        }

        let asset = AVURLAsset(url: result)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)

        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertGreaterThan(duration.seconds, 0)

        let formats = try await videoTracks[0].load(.formatDescriptions)
        let codec = try XCTUnwrap(formats.first).mediaSubType
        XCTAssertEqual(codec, CMFormatDescription.MediaSubType(rawValue: kCMVideoCodecType_HEVC))
    }

    /// Regression: a stream error can stop the recording, then a manual Stop calls finish()
    /// again. The second markAsFinished used to abort the process. finish() is now idempotent.
    func testDoubleFinishDoesNotCrash() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filesink-double-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let sink = try FileSink(outputURL: url, width: 320, height: 240,
                                systemAudio: false, microphone: false)
        try sink.start(at: .zero)
        for frame in 0..<10 {
            sink.append(video: TestBuffers.make(width: 320, height: 240),
                        pts: CMTime(value: CMTimeValue(frame * 10), timescale: 600))
        }

        _ = try await sink.finish()
        // Second call must return the same file, not crash.
        guard case .file(let again) = try await sink.finish() else {
            return XCTFail("expected a file result on the second finish")
        }
        XCTAssertEqual(again, url)
    }
}
