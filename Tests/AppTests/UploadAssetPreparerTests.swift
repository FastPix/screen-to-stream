import XCTest
import AVFoundation
import CoreMedia
@testable import App

final class UploadAssetPreparerTests: XCTestCase {
    func testNeedsExportOnlyWhenTrimmed() {
        XCTAssertFalse(UploadAssetPreparer.needsExport(trim: nil))
        XCTAssertFalse(UploadAssetPreparer.needsExport(trim: TrimRange(duration: 20)))  // noop

        var trimmed = TrimRange(duration: 20)
        trimmed.moveStart(to: 2)
        XCTAssertTrue(UploadAssetPreparer.needsExport(trim: trimmed))
    }

    func testMixesTwoAudioTracksIntoOne() async throws {
        let source = try await VideoFixture.makeWithAudio(seconds: 1, audioTracks: 2)
        defer { try? FileManager.default.removeItem(at: source) }

        let sourceAudio = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
        XCTAssertEqual(sourceAudio.count, 2)

        let result = try await UploadAssetPreparer().prepare(source: source, trim: nil)
        defer { if result != source { try? FileManager.default.removeItem(at: result) } }

        XCTAssertNotEqual(result, source)   // mixing produced a new file
        let outAudio = try await AVURLAsset(url: result).loadTracks(withMediaType: .audio)
        XCTAssertEqual(outAudio.count, 1)   // FastPix now gets a single combined track
    }

    func testPrepareWithoutTrimReturnsSameURL() async throws {
        let source = try await makeFixture(seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        let result = try await UploadAssetPreparer().prepare(source: source, trim: nil)
        XCTAssertEqual(result, source)
    }

    func testPrepareWithTrimShortensDuration() async throws {
        let source = try await makeFixture(seconds: 4)
        defer { try? FileManager.default.removeItem(at: source) }

        let full = try await AVURLAsset(url: source).load(.duration).seconds
        XCTAssertGreaterThan(full, 2.0)

        var trim = TrimRange(duration: full)
        trim.moveStart(to: 0.5)
        trim.moveEnd(to: 2.0)

        let result = try await UploadAssetPreparer().prepare(source: source, trim: trim)
        defer { try? FileManager.default.removeItem(at: result) }

        XCTAssertNotEqual(result, source)
        let trimmedDuration = try await AVURLAsset(url: result).load(.duration).seconds
        XCTAssertEqual(trimmedDuration, 1.5, accuracy: 0.4)
    }

    /// Offline HEVC fixture. `requestMediaDataWhenReady` pushes frames only when the encoder
    /// is ready, so nothing is dropped — unlike a tight real-time FileSink loop.
    private func makeFixture(seconds: Double, fps: Int = 30) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preparer-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let total = Int(seconds * Double(fps))
        let box = FrameCounter()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture")) {
                while input.isReadyForMoreMediaData {
                    if box.value >= total {
                        input.markAsFinished()
                        writer.finishWriting { continuation.resume() }
                        return
                    }
                    let pts = CMTime(value: CMTimeValue(box.value), timescale: CMTimeScale(fps))
                    adaptor.append(TestBuffers.make(width: 320, height: 240), withPresentationTime: pts)
                    box.value += 1
                }
            }
        }
        return url
    }

    private final class FrameCounter { var value = 0 }
}
