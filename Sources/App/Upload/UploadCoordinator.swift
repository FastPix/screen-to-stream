import AppKit
import Foundation

enum UploadPhase: Equatable {
    case idle
    case preparing
    case transferring(Double)
    case processing
    case ready(playbackURL: String)
    case failed(String)
}

/// Orchestrates prepare → create → PUT → poll → history, driving the uploading UI via `phase`.
/// The prepared file is retained until `Ready`, so no failure ever loses a recording.
@MainActor
final class UploadCoordinator: ObservableObject {
    @Published private(set) var phase: UploadPhase = .idle
    /// Raw FastPix media status during polling (Created, Downloading, Processing, …) for the UI.
    @Published private(set) var liveStatus: String?

    private let api: FastPixAPI
    private let uploader: Uploader
    private let history: HistoryStore
    private let preparer: UploadAssetPreparer
    private let maxResolution: String
    private let appVersion: String
    private let sleeper: (Double) async throws -> Void
    private let clock: () -> Double
    private let copyToClipboard: (String) -> Void

    // Retained across retries.
    private var entryId: String = ""
    private var sourceURL: URL?
    private var preparedURL: URL?
    private var trim: TrimRange?
    private var keepLocal = false
    private var features = AIFeatures()
    private var signedURL: URL?
    private var uploadId: String?

    init(api: FastPixAPI,
         uploader: Uploader,
         history: HistoryStore,
         preparer: UploadAssetPreparer = UploadAssetPreparer(),
         maxResolution: String = "1080p",
         appVersion: String = AppVersion.current,
         sleeper: @escaping (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         clock: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate },
         copyToClipboard: @escaping (String) -> Void = UploadCoordinator.pasteboardCopy) {
        self.api = api
        self.uploader = uploader
        self.history = history
        self.preparer = preparer
        self.maxResolution = maxResolution
        self.appVersion = appVersion
        self.sleeper = sleeper
        self.clock = clock
        self.copyToClipboard = copyToClipboard
    }

    func start(entryId: String, fileURL: URL, trim: TrimRange?, keepLocal: Bool,
               features: AIFeatures = AIFeatures()) async {
        self.entryId = entryId
        sourceURL = fileURL
        self.trim = trim
        self.keepLocal = keepLocal
        self.features = features
        signedURL = nil
        uploadId = nil
        history.patch(id: entryId) { $0.status = HistoryEntry.Status.uploading.rawValue }
        await run(fromCreate: true)
    }

    /// Reuses an existing signed URL, else creates a fresh upload.
    func retry() async {
        await run(fromCreate: signedURL == nil || uploadId == nil)
    }

    func cancel() {
        uploader.cancel()
    }

    private func run(fromCreate: Bool) async {
        guard let sourceURL else { return }

        do {
            phase = .preparing
            let prepared: URL
            if let existing = preparedURL {
                prepared = existing
            } else {
                prepared = try await preparer.prepare(source: sourceURL, trim: trim)
            }
            preparedURL = prepared

            if fromCreate {
                let created = try await api.createUpload(appVersion: appVersion,
                                                         maxResolution: maxResolution, features: features)
                signedURL = created.signedURL
                uploadId = created.uploadId
            }
            guard let signedURL, let uploadId else { throw UploadError.missingUpload }

            phase = .transferring(0)
            try await uploader.upload(file: prepared, to: signedURL) { [weak self] fraction in
                Task { @MainActor in self?.phase = .transferring(fraction) }
            }

            phase = .processing
            persistProcessing(uploadId: uploadId)

            let media = try await pollUntilReady(uploadId: uploadId)
            try await complete(media: media, uploadId: uploadId)
        } catch {
            let message = describe(error)
            AppLogger.shared.log("Upload", "failed: \(message)")
            history.patch(id: entryId) { $0.status = HistoryEntry.Status.failed.rawValue }
            phase = .failed(message)
            // Source file retained for retry.
        }
    }

    /// Polls media status. A 404 in the post-PUT window means FastPix hasn't created the media
    /// yet — not a failure, keep waiting.
    private func pollUntilReady(uploadId: String) async throws -> MediaResponse {
        let media = try await StatusPoller.poll(
            probe: { () async throws -> MediaResponse? in
                do {
                    let media = try await self.api.media(id: uploadId)
                    self.liveStatus = media.status
                    return media
                } catch let error as FastPixAPIError where Self.isNotYetCreated(error) {
                    self.liveStatus = "Uploading to FastPix"
                    return nil   // upload landed, media not created yet
                }
            },
            isDone: { $0?.status == "Ready" || $0?.status == "Failed" },
            sleep: sleeper,
            now: clock
        )

        guard let media else { throw UploadError.processingTimeout }
        guard media.status == "Ready" else { throw UploadError.processingFailed }
        return media
    }

    private func complete(media: MediaResponse, uploadId: String) async throws {
        guard let playbackId = media.playbackIds.first?.id else { throw UploadError.noPlaybackId }

        let playbackURL = "https://play.fastpix.com/?playbackId=\(playbackId)"
        history.patch(id: entryId) {
            $0.status = HistoryEntry.Status.ready.rawValue
            $0.mediaId = uploadId
            $0.playbackId = playbackId
            $0.playbackURL = playbackURL
            $0.hlsURL = "https://stream.fastpix.com/\(playbackId).m3u8"
            if let seconds = media.duration.flatMap(Self.seconds(fromHMS:)) { $0.durationSec = seconds }
            if !keepLocal { $0.localFileURL = nil }
        }

        copyToClipboard(playbackURL)
        cleanupFiles()
        phase = .ready(playbackURL: playbackURL)

        // Fire-and-forget AI — never blocks or endangers the link above.
        await api.triggerEnrichment(mediaId: uploadId, features: features)
    }

    private func persistProcessing(uploadId: String) {
        history.patch(id: entryId) {
            $0.status = HistoryEntry.Status.processing.rawValue
            $0.mediaId = uploadId
        }
    }

    private func cleanupFiles() {
        if let prepared = preparedURL, prepared != sourceURL {
            try? FileManager.default.removeItem(at: prepared)
        }
        if !keepLocal, let sourceURL {
            try? FileManager.default.removeItem(at: sourceURL)
        }
    }

    // MARK: - Helpers

    enum UploadError: Error { case missingUpload, processingTimeout, processingFailed, noPlaybackId }

    private static func isNotYetCreated(_ error: FastPixAPIError) -> Bool {
        error.statusCode == 404
            || error.body.localizedCaseInsensitiveContains("not found")
            || error.body.localizedCaseInsensitiveContains("workspace")
    }

    static func seconds(fromHMS text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private func describe(_ error: Error) -> String {
        if let apiError = error as? FastPixAPIError {
            return "Upload failed (HTTP \(apiError.statusCode))."
        }
        if error is FastPixAPIClientError {
            return "No FastPix credentials — add them in Settings."
        }
        switch error {
        case UploadError.processingTimeout:
            return "Still processing — FastPix is working on it. It'll finish in the background."
        case UploadError.processingFailed:
            return "FastPix could not process this recording."
        default:
            return (error as NSError).localizedDescription
        }
    }

    nonisolated static func pasteboardCopy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
