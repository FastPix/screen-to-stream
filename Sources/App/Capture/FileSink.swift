import AVFoundation
import CoreMedia
import CoreVideo

enum FileSinkError: Error, LocalizedError {
    case cannotCreateWriter
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateWriter:
            return "Couldn't create the video file writer."
        case .writerFailed(let reason):
            return "The recording didn't produce a video file (\(reason))."
        }
    }
}

/// AVAssetWriter sink: HEVC video plus discrete system/mic audio tracks. Sharing one audio input
/// across sources corrupts pitch.
final class FileSink: MediaSink {
    let outputURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemAudioInput: AVAssetWriterInput?
    private let micAudioInput: AVAssetWriterInput?

    private var policy: TimestampPolicy?
    private let queue = DispatchQueue(label: "com.fastpix.screen-to-stream.filesink")

    var pixelBufferPool: CVPixelBufferPool? { adaptor.pixelBufferPool }

    init(outputURL: URL, width: Int, height: Int, systemAudio: Bool, microphone: Bool) throws {
        self.outputURL = outputURL

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
            throw FileSinkError.cannotCreateWriter
        }
        self.writer = writer

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: VideoFormat.bitrate(width: width, height: height),
                AVVideoExpectedSourceFrameRateKey: 60,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        writer.add(videoInput)

        systemAudioInput = systemAudio ? Self.makeAudioInput(channels: 2, bitrate: 128_000) : nil
        micAudioInput = microphone ? Self.makeAudioInput(channels: 1, bitrate: 64_000) : nil

        for input in [systemAudioInput, micAudioInput].compactMap({ $0 }) {
            writer.add(input)
        }
    }

    func start(at pts: CMTime) throws {
        guard writer.startWriting() else {
            throw FileSinkError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }

        writer.startSession(atSourceTime: pts)
        policy = TimestampPolicy(sessionStart: pts)
        AppLogger.shared.log("Capture", "FileSink session started at \(pts.seconds)s → \(outputURL.lastPathComponent)")
    }

    func append(video buffer: CVPixelBuffer, pts: CMTime) {
        queue.sync {
            guard writer.status == .writing, videoInput.isReadyForMoreMediaData,
                  let stamped = policy?.videoPTS(for: pts) else { return }

            adaptor.append(buffer, withPresentationTime: stamped)
        }
    }

    func append(audio buffer: CMSampleBuffer, source: AudioSource) {
        queue.sync {
            guard writer.status == .writing else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard policy?.shouldDropAudio(at: pts) == false else { return }

            let input = source == .system ? systemAudioInput : micAudioInput
            guard let input, input.isReadyForMoreMediaData else { return }

            input.append(buffer)
        }
    }

    private var finished = false
    private var cachedOutcome: Result<SinkResult, Error>?

    func finish() async throws -> SinkResult {
        // Idempotent: a stream error can trigger stop, then a manual Stop again; markAsFinished on
        // an already-finished input aborts the process.
        if let cached = queue.sync(execute: { cachedOutcome }) {
            return try cached.get()
        }
        queue.sync { finished = true }

        let outcome: Result<SinkResult, Error>

        // Only finalize a live writer; markAsFinished/finishWriting on a failed or never-started
        // writer throws an uncatchable ObjC exception (crash).
        if writer.status == .writing {
            for input in [videoInput, systemAudioInput, micAudioInput].compactMap({ $0 }) {
                input.markAsFinished()
            }
            await writer.finishWriting()
        }

        // A never-started writer leaves a 0-byte file; reject it so a broken 0 KB recording isn't
        // surfaced as success.
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        if writer.status == .completed, size > 0 {
            AppLogger.shared.log("Capture", "FileSink finished → \(outputURL.path)")
            outcome = .success(.file(outputURL))
        } else {
            try? FileManager.default.removeItem(at: outputURL)
            let reason = writer.error?.localizedDescription ?? "no frames were captured"
            AppLogger.shared.log("Capture", "FileSink produced no usable file: \(reason)")
            outcome = .failure(FileSinkError.writerFailed(reason))
        }

        queue.sync { cachedOutcome = outcome }
        return try outcome.get()
    }

    private static func makeAudioInput(channels: Int, bitrate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: bitrate,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }
}
