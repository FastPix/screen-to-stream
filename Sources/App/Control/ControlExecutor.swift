import Foundation

/// Maps a validated ControlCommand onto the AppState recording flow, driving the same methods the
/// UI buttons do.
@MainActor
struct ControlExecutor {
    unowned let appState: AppState

    func handle(_ command: ControlCommand) async -> ControlResult {
        switch command.kind {
        case "start_recording": return await start(command)
        case "stop_recording": return await stop(command)
        default:
            return reject(command, "unknown command '\(command.kind)'")
        }
    }

    // MARK: - start

    private func start(_ command: ControlCommand) async -> ControlResult {
        if let rejection = Self.startRejection(screen: appState.screen) {
            return reject(command, rejection)
        }

        // Dismisses any leftover review/settings/error/done screen before starting.
        appState.showSourcePicker()
        await appState.catalog.refreshSources()

        let source: CaptureSource
        switch (command.source ?? "display").lowercased() {
        case "window":
            guard let query = command.window, !query.isEmpty else {
                return reject(command, "a window source needs a 'window' title to match")
            }
            let candidates = appState.catalog.windows.map { (id: $0.id, title: $0.title, app: $0.subtitle) }
            guard let id = Self.matchWindow(query, in: candidates),
                  let match = appState.catalog.windows.first(where: { $0.id == id }) else {
                let titles = appState.catalog.windows.prefix(5).map { $0.title }.joined(separator: ", ")
                return reject(command, "no window matching '\(query)'. Open windows: \(titles)")
            }
            source = match
        default:
            let displays = appState.catalog.displays
            guard !displays.isEmpty else {
                return reject(command, "no display available to record")
            }
            let index = (command.display ?? 1) - 1   // display is 1-based
            guard displays.indices.contains(index) else {
                return reject(command, "display \(command.display ?? 0) not found — \(displays.count) display(s) connected")
            }
            source = displays[index]
        }

        // Per-recording override, not a preferences write — persisting it would cap every later manual upload.
        appState.uploadResolutionOverride = command.resolution.map { Self.resolution(from: $0) }
        appState.selectedSource = source   // camera overlay lands on the recorded display

        let flags = Self.flags(from: command)
        if flags.camera, let camera = appState.catalog.cameras.first(where: { $0.isAvailable }) {
            // Position before selecting the camera so the overlay is created at the preset.
            appState.pendingOverlayCenter = Self.pipCenter(from: command.cameraPosition)
            appState.previewCameraID = camera.id
        } else {
            appState.previewCameraID = nil
        }

        var options = CaptureOptions(source: source, cameraDeviceID: appState.previewCameraID,
                                     systemAudio: flags.systemAudio, microphone: flags.microphone)
        options.pipDiameter = Self.pipDiameter(from: command.cameraSize)
        appState.startRecording(options: options)

        // Warmup (~15 s SCK init) blows past the MCP client's tool-call timeout; wait only long
        // enough to catch an immediate failure, then acknowledge while warmup finishes in the background.
        _ = await waitUntil(6) {
            if case .countdown = self.appState.screen { return true }
            if case .recording = self.appState.screen { return true }
            if case .error = self.appState.screen { return true }
            return false
        }
        if case .error(let message) = appState.screen { return reject(command, "failed to start: \(message)") }

        let state: String
        if case .recording = appState.screen { state = "recording" } else { state = "starting (countdown)" }
        return ControlResult(id: command.id, accepted: true,
                             message: "recording \(state) — \(source.title)")
    }

    // MARK: - stop

    private func stop(_ command: ControlCommand) async -> ControlResult {
        guard case .recording = appState.screen else {
            return reject(command, "nothing is recording")
        }

        appState.stopRecording()
        _ = await waitUntil(30) {
            if case .review = self.appState.screen { return true }
            if case .error = self.appState.screen { return true }
            return false
        }
        if case .error(let message) = appState.screen { return reject(command, "stop failed: \(message)") }
        guard case .review(let fileURL) = appState.screen, let entryId = appState.reviewingEntryId else {
            return reject(command, "stop did not complete")
        }

        guard command.upload == true else {
            appState.keepInLibrary()
            return ControlResult(id: command.id, accepted: true, message: "saved to library", entryId: entryId)
        }

        appState.beginUpload(entryId: entryId, fileURL: fileURL, trim: nil)
        _ = await waitUntil(900) {
            if case .done = self.appState.screen { return true }
            if case .failed? = self.appState.uploadCoordinator?.phase { return true }
            return false
        }
        if case .done(let playbackURL) = appState.screen {
            return ControlResult(id: command.id, accepted: true, message: "uploaded",
                                 entryId: entryId, playbackURL: playbackURL)
        }
        if case .failed(let message)? = appState.uploadCoordinator?.phase {
            return ControlResult(id: command.id, accepted: false, message: message, entryId: entryId)
        }
        return ControlResult(id: command.id, accepted: false, message: "upload timed out", entryId: entryId)
    }

    // MARK: - Helpers

    private func reject(_ command: ControlCommand, _ message: String) -> ControlResult {
        ControlResult(id: command.id, accepted: false, message: message)
    }

    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    // MARK: - Pure mapping (unit-tested)

    /// Whitelisted FastPix maxResolution values; unknown input falls back to 1080p.
    nonisolated static func resolution(from value: String?) -> String {
        switch value?.lowercased() {
        case "2160p", "4k": return "2160p"
        case "1440p": return "1440p"
        case "720p": return "720p"
        case "480p": return "480p"
        default: return "1080p"
        }
    }

    nonisolated static func flags(from command: ControlCommand) -> (camera: Bool, microphone: Bool, systemAudio: Bool) {
        (camera: command.camera ?? false,
         microphone: command.microphone ?? true,
         systemAudio: command.systemAudio ?? true)
    }

    /// Rejects only while busy (recording, countdown, uploading); every other screen is idle and
    /// can start. Must stay consistent with the state file's idle ⟺ can-start contract.
    nonisolated static func startRejection(screen: AppState.Screen) -> String? {
        switch screen {
        case .recording, .countdown:
            return "already recording"
        case .uploading:
            return "an upload is in progress; try again once it finishes"
        default:
            return nil
        }
    }

    /// Named position presets → normalized center (0-1, origin bottom-left). nil/unknown → default.
    nonisolated static func pipCenter(from position: String?) -> CGPoint? {
        switch position?.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "bottom-right": return CGPoint(x: 0.85, y: 0.15)
        case "bottom-left":  return CGPoint(x: 0.15, y: 0.15)
        case "top-right":    return CGPoint(x: 0.85, y: 0.85)
        case "top-left":     return CGPoint(x: 0.15, y: 0.85)
        case "center":       return CGPoint(x: 0.5, y: 0.5)
        case "left":         return CGPoint(x: 0.12, y: 0.5)
        case "right":        return CGPoint(x: 0.88, y: 0.5)
        case "top":          return CGPoint(x: 0.5, y: 0.85)
        case "bottom":       return CGPoint(x: 0.5, y: 0.15)
        default:             return nil
        }
    }

    /// PiP size presets as a fraction of the video's shorter side.
    nonisolated static func pipDiameter(from size: String?) -> Double {
        switch size?.lowercased() {
        case "small":  return 0.15
        case "large":  return 0.30
        default:       return 0.22   // medium
        }
    }

    /// Fuzzy window match: exact title, then title-contains, then app-name-contains.
    nonisolated static func matchWindow(_ query: String, in candidates: [(id: String, title: String, app: String)]) -> String? {
        let q = query.lowercased()
        if let exact = candidates.first(where: { $0.title.lowercased() == q }) { return exact.id }
        if let title = candidates.first(where: { $0.title.lowercased().contains(q) }) { return title.id }
        if let app = candidates.first(where: { $0.app.lowercased().contains(q) }) { return app.id }
        return nil
    }
}
