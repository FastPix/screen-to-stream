import AVFoundation
import CoreMedia

/// Offline HEVC fixture for tests. `requestMediaDataWhenReady` pushes frames only when the
/// encoder is ready, so nothing is dropped (a tight real-time loop would drop most).
enum VideoFixture {
    static func make(seconds: Double, fps: Int = 30) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString).mov")

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
        let box = Counter()

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

    private final class Counter { var value = 0 }

    /// Video + N discrete mono audio tracks — mirrors a real recording (system + mic).
    static func makeWithAudio(seconds: Double, audioTracks: Int, fps: Int = 30) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("avfixture-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(videoInput)

        var audioInputs: [AVAssetWriterInput] = []
        for _ in 0..<audioTracks {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 48_000, AVEncoderBitRateKey: 64_000])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInputs.append(input)
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Audio: write all frames up front (small), then video via requestMediaDataWhenReady.
        let format = pcmFormat()
        let totalAudioFrames = Int(seconds * 48_000)
        let chunk = 4_800
        var offset = 0
        while offset < totalAudioFrames {
            let frames = min(chunk, totalAudioFrames - offset)
            let pts = CMTime(value: CMTimeValue(offset), timescale: 48_000)
            for input in audioInputs {
                input.append(silentPCM(frames: frames, pts: pts, format: format))
            }
            offset += frames
        }
        audioInputs.forEach { $0.markAsFinished() }

        let total = Int(seconds * Double(fps))
        let box = Counter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "avfixture")) {
                while videoInput.isReadyForMoreMediaData {
                    if box.value >= total {
                        videoInput.markAsFinished()
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

    private static func pcmFormat() -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return format!
    }

    private static func silentPCM(frames: Int, pts: CMTime, format: CMAudioFormatDescription) -> CMSampleBuffer {
        let bytes = frames * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                           blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                             makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                             sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 1, sampleSizeArray: [2], sampleBufferOut: &sample)
        return sample!
    }
}
