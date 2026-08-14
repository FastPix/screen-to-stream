import AVFoundation

enum UploadAssetPreparerError: Error {
    case exportFailed(String)
    case noVideoTrack
    case cannotSetUpReaderWriter
}

/// Mixes the discrete system + mic audio tracks into ONE track and applies the trim in a single
/// pass. FastPix keeps only the first audio track on ingest, so unmixed tracks would drop the
/// audible one.
struct UploadAssetPreparer {
    /// Trim-only hint; `prepare` additionally mixes whenever there are 2+ audio tracks.
    static func needsExport(trim: TrimRange?) -> Bool {
        guard let trim else { return false }
        return !trim.isNoop
    }

    func prepare(source: URL, trim: TrimRange?) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let trimmed = trim.map { !$0.isNoop } ?? false

        // Nothing to do (also the path for an unreadable asset, which loads no tracks).
        if audioTracks.count <= 1, !trimmed { return source }

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw UploadAssetPreparerError.noVideoTrack
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-\(UUID().uuidString).mov")

        let reader = try AVAssetReader(asset: asset)
        var sessionStart = CMTime.zero
        if let trim, !trim.isNoop {
            reader.timeRange = trim.timeRange
            sessionStart = trim.timeRange.start   // passthrough keeps original PTS
        }

        // Video passes through untouched (no re-encode).
        let videoFormats = try await videoTrack.load(.formatDescriptions)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard reader.canAdd(videoOutput) else { throw UploadAssetPreparerError.cannotSetUpReaderWriter }
        reader.add(videoOutput)

        var audioMix: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let mix = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
            guard reader.canAdd(mix) else { throw UploadAssetPreparerError.cannotSetUpReaderWriter }
            reader.add(mix)
            audioMix = mix
        }

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                            sourceFormatHint: videoFormats.first)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw UploadAssetPreparerError.cannotSetUpReaderWriter }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioMix != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw UploadAssetPreparerError.cannotSetUpReaderWriter }
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading(), writer.startWriting() else {
            throw UploadAssetPreparerError.exportFailed(
                reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "start failed")
        }
        writer.startSession(atSourceTime: sessionStart)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(videoOutput, into: videoInput, label: "video") }
            if let audioMix, let audioInput {
                group.addTask { await Self.pump(audioMix, into: audioInput, label: "audio") }
            }
        }

        await writer.finishWriting()

        guard writer.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw UploadAssetPreparerError.exportFailed(
                writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "reader/writer did not complete")
        }

        AppLogger.shared.log("Upload", "prepared single-audio-track asset → \(output.lastPathComponent)")
        return output
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) async {
        let queue = DispatchQueue(label: "com.fastpix.screen-to-stream.prepare.\(label)")
        // The callback runs serially on `queue` and is the sole accessor, so crossing the Sendable
        // boundary is safe — AVAssetWriterInput/ReaderOutput just aren't marked Sendable.
        nonisolated(unsafe) let input = input
        nonisolated(unsafe) let output = output
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    input.append(sample)
                }
            }
        }
    }
}
