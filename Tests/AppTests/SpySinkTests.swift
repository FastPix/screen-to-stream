import XCTest
import CoreMedia
@testable import App

final class SpySinkTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    func testFirstFrameStartsSessionAtRawPTS() {
        let sink = SpySink()
        let engine = CaptureEngine()
        engine.beginTesting(sink: sink)

        engine.ingest(video: TestBuffers.make(width: 64, height: 64), pts: t(10))

        XCTAssertEqual(sink.started, t(10))
        XCTAssertEqual(sink.videoPTS, [t(10)])
    }

    func testDuplicatePTSIsDropped() {
        let sink = SpySink()
        let engine = CaptureEngine()
        engine.beginTesting(sink: sink)

        engine.ingest(video: TestBuffers.make(width: 64, height: 64), pts: t(10))
        engine.ingest(video: TestBuffers.make(width: 64, height: 64), pts: t(10))

        // The duplicate (as a live-resize burst delivers) is dropped, not crammed forward.
        XCTAssertEqual(sink.videoPTS, [t(10)])
    }

    func testMismatchedBufferIsNormalizedToCanvas() {
        let sink = SpySink()
        let engine = CaptureEngine()
        engine.beginTesting(sink: sink)   // canvas is 64×64 in test mode

        // A wrongly-sized frame (as delivered after a stream reconfiguration) still reaches the
        // writer at the fixed canvas size — never at the mismatched size that would corrupt it.
        engine.ingest(video: TestBuffers.make(width: 200, height: 80), pts: t(10))

        XCTAssertEqual(sink.videoSizes.count, 1)
        XCTAssertEqual(sink.videoSizes[0].width, 64)
        XCTAssertEqual(sink.videoSizes[0].height, 64)
    }

    func testFillIntervalMatchesFillTimerPeriod() {
        // Fill frames advance the clock by the real timer period (1/24 s), not a nominal 1/600 s
        // — the old value compressed a static window's recorded timeline ~25×.
        XCTAssertEqual(CaptureEngine.fillInterval, CMTime(value: 25, timescale: 600))
    }

    /// Regression: the engine is reused for every recording. State left over from the previous
    /// one (sessionStarted) meant the second sink never got start(), so every frame was dropped
    /// and the recording failed with "no frames were captured".
    func testSecondRecordingOnAReusedEngineStartsItsOwnSink() {
        let engine = CaptureEngine()

        let first = SpySink()
        engine.beginTesting(sink: first)
        engine.ingest(video: TestBuffers.make(width: 64, height: 64), pts: t(10))
        XCTAssertEqual(first.started, t(10))
        XCTAssertEqual(first.videoPTS.count, 1)

        // A new recording with a fresh sink — as AppState does on every Start.
        let second = SpySink()
        engine.beginTesting(sink: second)
        engine.ingest(video: TestBuffers.make(width: 64, height: 64), pts: t(50))

        XCTAssertEqual(second.started, t(50), "second recording must start its own writer session")
        XCTAssertEqual(second.videoPTS.count, 1, "frames must reach the second sink")
    }

    func testAudioBeforeFirstVideoFrameIsDropped() {
        let sink = SpySink()
        let engine = CaptureEngine()
        engine.beginTesting(sink: sink)

        engine.ingest(audio: makeSilentAudio(at: t(5)), source: .system)
        engine.ingest(video: TestBuffers.make(width: 64, height: 64), pts: t(10))
        engine.ingest(audio: makeSilentAudio(at: t(11)), source: .microphone)

        XCTAssertEqual(sink.audio.count, 1)
        XCTAssertEqual(sink.audio.first?.source, .microphone)
    }

    private func makeSilentAudio(at pts: CMTime) -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &description)

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
                             dataReady: false, makeDataReadyCallback: nil,
                             refcon: nil, formatDescription: description,
                             sampleCount: 1, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                             sampleSizeArray: nil, sampleBufferOut: &buffer)
        return buffer!
    }
}
