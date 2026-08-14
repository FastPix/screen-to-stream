import AVFoundation
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Screen: Equatable {
        case permissions
        case sourcePicker
        case countdown(Int)
        case recording
        case review(URL)
        case library
        case settings
        case uploading
        case done(playbackURL: String)
        case error(String)
    }

    @Published private(set) var screen: Screen = .permissions
    /// Gates the picker's thumbnail refresh; a hidden panel must never screenshot every 5s.
    @Published var panelIsVisible = true
    @Published var endedEarlyNotice: String?
    /// nil means no trim.
    @Published var reviewTrim: TrimRange?
    @Published var previewCameraID: String? {
        didSet { updatePreviewCamera(from: oldValue) }
    }
    /// Published so the camera overlay can follow the chosen display across screens.
    @Published var selectedSource: CaptureSource?
    let pipPosition = PiPPosition()
    /// Normalized, bottom-left origin. Consumed by MenuBarController when creating the overlay.
    var pendingOverlayCenter: CGPoint?
    /// Per-recording upload cap from MCP; consumed once by the next upload, never persisted to Settings.
    var uploadResolutionOverride: String?

    let catalog = SourceCatalog()
    let camera = CameraCapture()
    lazy var engine = CaptureEngine(camera: camera, pipPosition: pipPosition)

    let history: HistoryStore
    let preferences = PreferencesStore()

    /// Injectable so tests never write to the real library.
    init(historyDirectory: URL = HistoryStore.defaultDirectory) {
        history = HistoryStore(directory: historyDirectory)
    }
    // Keychain read is off-main: a rebuilt ad-hoc binary can trigger a blocking allow-access dialog.
    @Published private(set) var hasCredentials: Bool = false
    @Published private(set) var uploadCoordinator: UploadCoordinator?

    /// Screen to return to when leaving Settings.
    private var settingsReturn: Screen = .sourcePicker
    private var pendingUpload: (entryId: String, fileURL: URL, trim: TrimRange?, fullScreen: Bool)?
    private var uploadPhaseSubscription: AnyCancellable?

    private(set) var reviewingEntryId: String?
    /// Upload in flight; the library row with this id shows live progress.
    @Published private(set) var currentUploadId: String?

    /// Overridable so tests never hit the network.
    var apiSession: URLSession = .shared

    // MCP control channel (opt-in; default off).
    private var commandWatcher: CommandWatcher?
    private var controlStateSubscription: AnyCancellable?
    /// Injectable so the resume poller doesn't sleep for real in tests.
    var pollSleeper: (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    var pollClock: () -> Double = { Date().timeIntervalSinceReferenceDate }

    private var countdownTask: Task<Void, Never>?
    private var recordingStart: Date?

    var elapsed: TimeInterval {
        recordingStart.map { Date().timeIntervalSince($0) } ?? 0
    }

    // MARK: - Navigation

    func permissionsSatisfied() {
        screen = .sourcePicker
    }

    func showPermissions() {
        screen = .permissions
    }

    func showSourcePicker() {
        endedEarlyNotice = nil
        reviewTrim = nil
        screen = .sourcePicker
    }

    /// A closed panel can keep the picker's timer alive and screenshot every display forever;
    /// gate refresh on visible AND on-picker.
    nonisolated static func shouldAutoRefreshPicker(panelVisible: Bool, screen: Screen) -> Bool {
        panelVisible && screen == .sourcePicker
    }

    // MARK: - Recording flow

    /// Warmup before the countdown so the 3-2-1 is not spent initializing SCK.
    func startRecording(options: CaptureOptions) {
        countdownTask = Task {
            let measured: (width: Int, height: Int)?
            do {
                measured = try await CaptureEngine.warmup(source: options.source)
            } catch {
                screen = .error(error.localizedDescription)
                return
            }

            for count in [3, 2, 1] {
                guard !Task.isCancelled else { return }
                screen = .countdown(count)
                try? await Task.sleep(for: .seconds(1))
            }

            guard !Task.isCancelled else { return }
            await beginCapture(options: options, measuredSize: measured)
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        screen = .sourcePicker
    }

    private var isStopping = false

    func stopRecording() {
        // Stream-error auto-stop and a Stop click can race; run once.
        guard !isStopping else { return }
        isStopping = true

        Task {
            defer { isStopping = false }
            do {
                let result = try await engine.stop()
                recordingStart = nil
                previewCameraID = nil

                switch result {
                case .file(let url):
                    registerLocalRecording(url)
                    screen = .review(url)
                }
            } catch {
                previewCameraID = nil
                screen = .error(error.localizedDescription)
            }
        }
    }

    /// Registers the recording as a local entry so it appears whether or not it's uploaded.
    private func registerLocalRecording(_ url: URL) {
        let id = UUID().uuidString
        reviewingEntryId = id

        let asset = AVURLAsset(url: url)
        let entry = HistoryEntry.local(id: id, fileURL: url, durationSec: nil, thumbnailPath: nil)
        history.add(entry)

        Task {
            let duration = try? await asset.load(.duration).seconds
            let thumbnail = await ThumbnailGenerator.generate(from: url, id: id)
            history.patch(id: id) {
                if let duration { $0.durationSec = duration }
                $0.thumbnailPath = thumbnail
            }
        }
    }

    func discardRecording(at url: URL) {
        if let id = reviewingEntryId {
            history.remove(id: id)
            reviewingEntryId = nil
        }
        try? FileManager.default.removeItem(at: url)
        showSourcePicker()
    }

    @Published var libraryError: String?

    func showLibrary() {
        screen = .library
    }

    /// Remove from the local library only — the FastPix asset and its link keep working.
    func removeFromLibrary(_ entry: HistoryEntry) {
        if currentUploadId == entry.id { return }   // don't yank an in-flight upload
        if let path = entry.localFileURL { try? FileManager.default.removeItem(atPath: path) }
        if let thumb = entry.thumbnailPath { try? FileManager.default.removeItem(atPath: thumb) }
        history.remove(id: entry.id)
    }

    /// Irreversibly deletes the FastPix asset, then the local entry. A 404 (already gone) counts as success.
    func deleteFromFastPix(_ entry: HistoryEntry) {
        guard let mediaId = entry.mediaId else { removeFromLibrary(entry); return }
        Task {
            do {
                try await FastPixAPI(session: apiSession).deleteMedia(id: mediaId)
            } catch let error as FastPixAPIError where error.isNotFound {
                // already deleted on the server — fall through and remove locally
            } catch {
                libraryError = "Couldn't delete from FastPix: \(error.localizedDescription)"
                return
            }
            removeFromLibrary(entry)
        }
    }

    func copyLink(_ entry: HistoryEntry) {
        guard let url = entry.playbackURL else { return }
        UploadCoordinator.pasteboardCopy(url)
    }

    // MARK: - MCP recording control (opt-in)

    /// Toggles the MCP command channel; while on, a CommandWatcher runs and state.json tracks the screen.
    func setControlEnabled(_ enabled: Bool) {
        preferences.allowMCPControl = enabled
        let directory = ControlDirectory()

        if enabled {
            try? directory.ensureLayout()
            FileManager.default.createFile(atPath: directory.enabledMarker.path, contents: nil)

            let watcher = CommandWatcher { [weak self] command in
                guard let self else {
                    return ControlResult(id: command.id, accepted: false, message: "app is closing")
                }
                return await ControlExecutor(appState: self).handle(command)
            }
            watcher.start()
            commandWatcher = watcher

            controlStateSubscription = $screen
                .receive(on: RunLoop.main)
                .sink { [weak self] screen in self?.publishControlState(for: screen) }
            publishControlState(for: screen)
        } else {
            commandWatcher?.stop()
            commandWatcher = nil
            controlStateSubscription = nil
            try? FileManager.default.removeItem(at: directory.enabledMarker)
            try? FileManager.default.removeItem(at: directory.stateFile)
        }
    }

    func startControlIfEnabled() {
        if preferences.allowMCPControl { setControlEnabled(true) }
    }

    private func publishControlState(for screen: Screen) {
        let state: ControlState
        switch screen {
        case .countdown:
            state = ControlState(state: "countdown")
        case .recording:
            state = ControlState(state: "recording", elapsedSec: elapsed, entryId: reviewingEntryId)
        case .uploading:
            state = ControlState(state: "uploading", entryId: currentUploadId)
        default:
            state = ControlState(state: "idle")
        }

        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: ControlDirectory().stateFile, options: .atomic)
    }

    /// At launch: an interrupted upload lost its bytes → back to local; an interrupted
    /// processing still exists server-side → re-poll to ready.
    func resumeInterrupted() {
        for entry in history.entries {
            switch entry.statusValue {
            case .uploading:
                history.patch(id: entry.id) { $0.status = HistoryEntry.Status.local.rawValue }
            case .processing:
                if let mediaId = entry.mediaId { repoll(entryId: entry.id, mediaId: mediaId) }
            default:
                break
            }
        }
    }

    private func repoll(entryId: String, mediaId: String) {
        let api = FastPixAPI(session: apiSession)
        Task {
            let media = try? await StatusPoller.poll(
                probe: { () async throws -> MediaResponse? in try? await api.media(id: mediaId) },
                isDone: { $0?.status == "Ready" || $0?.status == "Failed" },
                sleep: pollSleeper, now: pollClock)

            guard let media, media.status == "Ready", let pid = media.playbackIds.first?.id else { return }
            history.patch(id: entryId) {
                $0.status = HistoryEntry.Status.ready.rawValue
                $0.playbackId = pid
                $0.playbackURL = "https://play.fastpix.com/?playbackId=\(pid)"
                $0.hlsURL = "https://stream.fastpix.com/\(pid).m3u8"
            }
        }
    }

    func keepInLibrary() {
        reviewingEntryId = nil
        reviewTrim = nil
        screen = .library
    }

    // MARK: - Settings & credentials

    func showSettings() {
        settingsReturn = screen == .uploading ? .sourcePicker : screen
        screen = .settings
    }

    func closeSettings() {
        screen = settingsReturn == .settings ? .sourcePicker : settingsReturn
    }

    /// Read the Keychain off-main so a first-run allow dialog can't block launch.
    func loadCredentialsInBackground() {
        Task.detached {
            let present = CredentialStore.load() != nil
            await MainActor.run { self.hasCredentials = present }
        }
    }

    /// Resumes a pending upload once credentials become available.
    func refreshCredentials() {
        hasCredentials = CredentialStore.load() != nil
        if hasCredentials, let pending = pendingUpload {
            pendingUpload = nil
            startUpload(entryId: pending.entryId, fileURL: pending.fileURL,
                        trim: pending.trim, fullScreen: pending.fullScreen)
        }
    }

    // MARK: - Upload flow

    private var uploadPresentedFullScreen = false

    /// Review path: full-screen progress, then the Done screen.
    func beginUpload(entryId: String, fileURL: URL, trim: TrimRange?) {
        guard !entryId.isEmpty else { return }
        requestUpload(entryId: entryId, fileURL: fileURL, trim: trim, fullScreen: true)
    }

    /// Library path: inline row progress, no screen takeover.
    func uploadEntry(_ entry: HistoryEntry) {
        guard let path = entry.localFileURL else { return }
        requestUpload(entryId: entry.id, fileURL: URL(fileURLWithPath: path), trim: nil, fullScreen: false)
    }

    private func requestUpload(entryId: String, fileURL: URL, trim: TrimRange?, fullScreen: Bool) {
        guard currentUploadId == nil else { return }   // one upload at a time
        guard hasCredentials else {
            pendingUpload = (entryId, fileURL, trim, fullScreen)
            settingsReturn = fullScreen ? .sourcePicker : .library
            screen = .settings
            return
        }
        startUpload(entryId: entryId, fileURL: fileURL, trim: trim, fullScreen: fullScreen)
    }

    func retryUpload() {
        Task { await uploadCoordinator?.retry() }
    }

    func cancelUpload() {
        uploadCoordinator?.cancel()
        let wasFullScreen = uploadPresentedFullScreen
        finishUploadObservation()
        screen = wasFullScreen ? .sourcePicker : .library
    }

    private func startUpload(entryId: String, fileURL: URL, trim: TrimRange?, fullScreen: Bool) {
        let resolution = uploadResolutionOverride ?? preferences.maxResolution
        uploadResolutionOverride = nil   // one recording only, never persisted
        let coordinator = UploadCoordinator(
            api: FastPixAPI(session: apiSession),
            uploader: DirectUploader(),
            history: history,
            maxResolution: resolution)
        uploadCoordinator = coordinator
        currentUploadId = entryId
        uploadPresentedFullScreen = fullScreen
        if fullScreen { screen = .uploading }

        uploadPhaseSubscription = coordinator.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.mapUploadPhase(phase) }

        Task {
            await coordinator.start(entryId: entryId, fileURL: fileURL, trim: trim,
                                    keepLocal: preferences.keepLocalRecordings,
                                    features: preferences.aiFeatures)
        }
    }

    private func mapUploadPhase(_ phase: UploadPhase) {
        guard case .ready(let playbackURL) = phase else { return }
        let wasFullScreen = uploadPresentedFullScreen
        finishUploadObservation()
        reviewTrim = nil
        reviewingEntryId = nil
        if wasFullScreen { screen = .done(playbackURL: playbackURL) }
        // library flow: the row is already ready (coordinator patched the entry)
    }

    private func finishUploadObservation() {
        uploadCoordinator = nil
        uploadPhaseSubscription = nil
        currentUploadId = nil
    }

    private func updatePreviewCamera(from oldValue: String?) {
        guard previewCameraID != oldValue else { return }

        if let id = previewCameraID {
            try? camera.start(deviceID: id)
        } else {
            camera.stop()
        }
    }

    private func beginCapture(options: CaptureOptions, measuredSize: (width: Int, height: Int)? = nil) async {
        let outputURL = Self.newRecordingURL()

        do {
            // Prefer the size measured from warmup frames: window metadata can be stale
            // (Chromium keeps its pre-fullscreen frame), delivered pixels don't.
            let size: (width: Int, height: Int)
            if let measuredSize {
                size = VideoFormat.encodeSize(width: measuredSize.width, height: measuredSize.height)
            } else {
                size = try await CaptureEngine.captureSize(for: options.source)
            }
            var options = options
            options.encodeSize = size
            let sink = try FileSink(outputURL: outputURL, width: size.width, height: size.height,
                                    systemAudio: options.systemAudio, microphone: options.microphone)

            engine.onError = { [weak self] error in
                Task { @MainActor in
                    self?.handleMidRecordingFailure(error)
                }
            }

            try await engine.start(options: options, sink: sink)
            recordingStart = Date()
            screen = .recording
        } catch {
            AppLogger.shared.log("Capture", "start failed: \(error.localizedDescription)")
            previewCameraID = nil
            screen = .error(error.localizedDescription)
        }
    }

    /// A stream that dies mid-recording still has usable footage; finalize and show it.
    private func handleMidRecordingFailure(_ error: Error) {
        guard case .recording = screen else { return }

        endedEarlyNotice = "Recording ended early: \(error.localizedDescription)"
        stopRecording()
    }

    static func newRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenToStream", isDirectory: true)
            .appendingPathComponent("Recording-\(formatter.string(from: Date())).mov")
    }
}
