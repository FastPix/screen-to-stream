import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct CaptureOptions {
    var source: CaptureSource
    var cameraDeviceID: String?
    var systemAudio: Bool = true
    var microphone: Bool = true
    var pipDiameter: Double = 0.22
    /// Encode canvas; AppState sets it from `CaptureEngine.captureSize` so writer and engine agree.
    var encodeSize: (width: Int, height: Int)?
}

enum CaptureError: Error, LocalizedError {
    case warmupTimeout
    case noFrames
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .warmupTimeout: return "Screen capture did not start in time. If you picked a window, it may be minimized or hidden — restore it and try again."
        case .noFrames: return "No frames were captured."
        case .streamFailed(let reason): return reason
        }
    }
}

/// Owns every capture source and the compositing step, then hands composed frames to a MediaSink.
/// Knows nothing about files, uploads, or where frames end up.
final class CaptureEngine: NSObject {
    var onError: ((Error) -> Void)?

    private let compositor = Compositor()
    private let camera: CameraCapture
    private let pipPosition: PiPPosition
    private let micSession = AVCaptureSession()

    init(camera: CameraCapture = CameraCapture(), pipPosition: PiPPosition = PiPPosition()) {
        self.camera = camera
        self.pipPosition = pipPosition
        super.init()
    }
    private let ingestQueue = DispatchQueue(label: "com.fastpix.screen-to-stream.engine")

    private var stream: SCStream?
    private var sink: MediaSink?
    private var options: CaptureOptions?
    private var pixelBufferPool: CVPixelBufferPool?

    private var sessionStarted = false
    private var policy: TimestampPolicy?
    private var videoSize: (width: Int, height: Int) = (0, 0)
    private var screenFramesReceived = 0
    private var screenFramesUsed = 0

    private var lastScreenBuffer: CVPixelBuffer?
    private var lastScreenCrop: CGRect?
    private var lastScreenPTS: CMTime = .zero
    private var fillTimer: DispatchSourceTimer?
    private var geometryFramesLogged = 0

    // MARK: - Warmup

    /// Throwaway stream that runs until the first real frame, so TCC prompts and SCK init happen
    /// before the countdown, not during recording. Returns the measured content pixel size, or nil
    /// if the frame carried no usable geometry (callers fall back to `captureSize(for:)`).
    @discardableResult
    static func warmup(source: CaptureSource) async throws -> (width: Int, height: Int)? {
        let warmup = WarmupStream()
        try await warmup.run(source: source)
        return warmup.measuredContentPixels
    }

    // MARK: - Lifecycle

    /// Authoritative capture size from SCK: contentRect × pointPixelScale is exactly what the
    /// stream renders. Catalog-snapshotted window frames can be stale or bogus.
    static func captureSize(for source: CaptureSource) async throws -> (width: Int, height: Int) {
        let filter = try await contentFilter(for: source)
        let scale = CGFloat(filter.pointPixelScale)
        return VideoFormat.encodeSize(width: Int(filter.contentRect.width * scale),
                                      height: Int(filter.contentRect.height * scale))
    }

    func start(options: CaptureOptions, sink: MediaSink) async throws {
        self.options = options
        self.sink = sink

        resetForNewRecording()

        if let size = options.encodeSize {
            videoSize = size
        } else {
            videoSize = try await Self.captureSize(for: options.source)
        }

        if let sink = sink as? FileSink {
            pixelBufferPool = sink.pixelBufferPool
        }

        if let cameraID = options.cameraDeviceID {
            try camera.start(deviceID: cameraID)
        }

        let filter = try await Self.contentFilter(for: options.source)
        let configuration = SCStreamConfiguration()
        configuration.width = videoSize.width
        configuration.height = videoSize.height
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = options.systemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        if case .window = options.source {
            // Window capture only scales down unless scalesToFit is set.
            configuration.scalesToFit = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: ingestQueue)

        if options.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: ingestQueue)
        }

        try await stream.startCapture()
        self.stream = stream

        if options.microphone {
            startMicrophone()
        }

        if options.cameraDeviceID != nil {
            startFillTimer()
        }

        AppLogger.shared.log("Capture", "engine started \(videoSize.width)×\(videoSize.height) source=\(options.source.title)")
    }

    func stop() async throws -> SinkResult {
        fillTimer?.cancel()
        fillTimer = nil

        try? await stream?.stopCapture()
        stream = nil

        if micSession.isRunning {
            micSession.stopRunning()
        }
        // Camera lifecycle is owned by AppState (shared with the preview overlay), not here.

        AppLogger.shared.log("Capture", "stop: screen frames received=\(screenFramesReceived) used=\(screenFramesUsed)")

        guard let sink else { throw CaptureError.noFrames }
        guard sessionStarted else { throw CaptureError.noFrames }

        return try await sink.finish()
    }

    var cameraPreviewSession: AVCaptureSession { camera.previewSession }

    // MARK: - Frame routing (unit-tested via SpySink)

    func beginTesting(sink: MediaSink) {
        resetForNewRecording()
        self.sink = sink
        videoSize = (64, 64)
    }

    /// Reused across recordings; per-recording state resets here or the next recording never
    /// starts its sink and silently drops every frame.
    private func resetForNewRecording() {
        sessionStarted = false
        policy = nil
        lastScreenBuffer = nil
        lastScreenCrop = nil
        lastScreenPTS = .zero
        screenFramesReceived = 0
        screenFramesUsed = 0
        geometryFramesLogged = 0
    }

    func ingest(video buffer: CVPixelBuffer, pts: CMTime, contentCrop: CGRect? = nil) {
        guard let sink else { return }

        if !sessionStarted {
            do {
                try sink.start(at: pts)
                sessionStarted = true
                policy = TimestampPolicy(sessionStart: pts)
            } catch {
                // Leave the session unstarted on failure, or every later frame is silently dropped.
                AppLogger.shared.log("Capture", "sink.start failed: \(error.localizedDescription)")
                onError?(error)
                return
            }
        }

        guard let stamped = policy?.videoPTS(for: pts) else { return }

        lastScreenBuffer = buffer
        lastScreenCrop = contentCrop
        lastScreenPTS = stamped

        let composed = compositor.compose(
            screen: buffer,
            contentPixelRect: contentCrop,
            camera: camera.latestFrame,
            pip: pipRect(),
            canvasWidth: videoSize.width, canvasHeight: videoSize.height,
            into: pixelBufferPool
        )
        sink.append(video: composed, pts: stamped)
    }

    func ingest(audio buffer: CMSampleBuffer, source: AudioSource) {
        guard let sink, sessionStarted else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard policy?.shouldDropAudio(at: pts) == false else { return }

        sink.append(audio: buffer, source: source)
    }

    // MARK: - Fill timer

    /// Window capture only delivers frames on content change; without this a static window freezes
    /// the PiP. Fill frames use the host clock (the timebase SCK stamps real frames with), never a
    /// synthetic increment, so the drop-based TimestampPolicy can't starve real frames.
    static let fillInterval = CMTime(value: 25, timescale: 600)   // 1/24 s

    private func startFillTimer() {
        let timer = DispatchSource.makeTimerSource(queue: ingestQueue)
        timer.schedule(deadline: .now() + 1.0 / 24.0, repeating: 1.0 / 24.0)
        timer.setEventHandler { [weak self] in
            guard let self, let screen = self.lastScreenBuffer, let sink = self.sink,
                  let cameraFrame = self.camera.latestFrame else { return }

            let now = CMClockGetTime(CMClockGetHostTimeClock())
            guard now - self.lastScreenPTS >= Self.fillInterval else { return }
            guard let stamped = self.policy?.videoPTS(for: now) else { return }

            self.lastScreenPTS = stamped
            let composed = self.compositor.compose(
                screen: screen, contentPixelRect: self.lastScreenCrop, camera: cameraFrame,
                pip: self.pipRect(),
                canvasWidth: self.videoSize.width, canvasHeight: self.videoSize.height,
                into: self.pixelBufferPool
            )
            sink.append(video: composed, pts: stamped)
        }
        timer.resume()
        fillTimer = timer
    }

    private func pipRect() -> CGRect {
        guard let options, options.cameraDeviceID != nil else { return .zero }

        // Live position, not the start-time snapshot, so the recorded PiP follows the overlay.
        let center = pipPosition.center
        return PiPGeometry.rect(
            centerX: center.x, centerY: center.y,
            diameter: options.pipDiameter,
            videoWidth: videoSize.width, videoHeight: videoSize.height
        )
    }

    // MARK: - Sources

    private func startMicrophone() {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else {
            AppLogger.shared.log("Capture", "microphone unavailable — continuing without it")
            return
        }

        let output = AVCaptureAudioDataOutput()
        micSession.beginConfiguration()

        // Session reused across recordings: clear old inputs/outputs or each recording adds
        // another pair and mic samples multiply.
        micSession.inputs.forEach(micSession.removeInput)
        micSession.outputs.forEach(micSession.removeOutput)

        if micSession.canAddInput(input), micSession.canAddOutput(output) {
            micSession.addInput(input)
            output.setSampleBufferDelegate(self, queue: ingestQueue)
            micSession.addOutput(output)
        }

        micSession.commitConfiguration()
        ingestQueue.async { [micSession] in
            micSession.startRunning()
        }
    }

    /// Excludes the app's own windows so recordings never show recorder chrome.
    private static func contentFilter(for source: CaptureSource) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }

        switch source {
        case .display(let display):
            return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        case .window(let window):
            // Re-resolve by windowID: the catalog's SCWindow frame can be stale, and the filter's
            // contentRect sizes the encode canvas.
            let fresh = content.windows.first { $0.windowID == window.windowID } ?? window
            return SCContentFilter(desktopIndependentWindow: fresh)
        }
    }
}

// MARK: - SCStream plumbing

extension CaptureEngine: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .screen:
            screenFramesReceived += 1
            guard usableFrame(sampleBuffer), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            screenFramesUsed += 1
            logFrameGeometryIfEnabled(sampleBuffer, buffer: buffer)
            ingest(video: buffer,
                   pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                   contentCrop: Self.contentCrop(of: sampleBuffer, buffer: buffer))
        case .audio:
            ingest(audio: sampleBuffer, source: .system)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppLogger.shared.log("Capture", "stream stopped with error: \(error.localizedDescription)")
        onError?(CaptureError.streamFailed(error.localizedDescription))
    }

    /// The content's pixel box inside the buffer, from SCK's per-frame attachments; nil when the
    /// content fills the buffer or geometry is unreadable. See ContentBox.
    private static func contentCrop(of sampleBuffer: CMSampleBuffer, buffer: CVPixelBuffer) -> CGRect? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let rectDict = first[.contentRect],
              let contentRect = CGRect(dictionaryRepresentation: rectDict as! CFDictionary),
              let scaleFactor = first[.scaleFactor] as? Double else {
            return nil
        }

        return ContentBox.pixelRect(contentRect: contentRect, scaleFactor: scaleFactor,
                                    bufferWidth: CVPixelBufferGetWidth(buffer),
                                    bufferHeight: CVPixelBufferGetHeight(buffer))
    }

    /// Diagnostic only (FPDumpWindows): logs SCK's raw per-frame geometry attachments.
    private func logFrameGeometryIfEnabled(_ sampleBuffer: CMSampleBuffer, buffer: CVPixelBuffer) {
        guard UserDefaults.standard.bool(forKey: "FPDumpWindows"),
              geometryFramesLogged < 8 || screenFramesUsed % 120 == 0 else { return }
        geometryFramesLogged += 1

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let first = attachments.first else { return }

        let rect = (first[.contentRect]).flatMap { CGRect(dictionaryRepresentation: ($0 as! CFDictionary)) }
        let contentScale = first[.contentScale] as? Double ?? -1
        let scaleFactor = first[.scaleFactor] as? Double ?? -1
        let r = rect.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "nil"
        AppLogger.shared.log("Capture",
            "frameGeom buffer=\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) "
            + "contentRect=\(r) contentScale=\(contentScale) scaleFactor=\(scaleFactor)")
    }

    /// Accept `.complete` (new content) and `.idle` (unchanged, carries the last surface so a
    /// static screen keeps producing video). Keep frames whose status is unreadable but present.
    private func usableFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            return true
        }

        return status == .complete || status == .idle
    }
}

extension CaptureEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        ingest(audio: sampleBuffer, source: .microphone)
    }
}

// MARK: - Warmup

private final class WarmupStream: NSObject, SCStreamOutput {
    private var continuation: CheckedContinuation<Void, Error>?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.fastpix.screen-to-stream.warmup")
    private var resumed = false

    /// The source's true content size in pixels, measured from the first frame's attachments
    /// (contentRect / contentScale × scaleFactor). Metadata (SCWindow.frame, filter.contentRect)
    /// can be stale; the stream's own frames aren't.
    private(set) var measuredContentPixels: (width: Int, height: Int)?

    func run(source: CaptureSource) async throws {
        let filter: SCContentFilter
        switch source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let configuration = SCStreamConfiguration()
        configuration.width = 640
        configuration.height = 360
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    Task { try? await stream.startCapture() }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw CaptureError.warmupTimeout
            }

            try await group.next()
            group.cancelAll()
        }

        try? await stream.stopCapture()
        self.stream = nil
        AppLogger.shared.log("Capture", "warmup complete for \(source.title)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !resumed, type == .screen, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
           let first = attachments.first,
           let rectDict = first[.contentRect],
           let rect = CGRect(dictionaryRepresentation: rectDict as! CFDictionary),
           let contentScale = first[.contentScale] as? Double, contentScale > 0.01,
           let scaleFactor = first[.scaleFactor] as? Double, scaleFactor > 0 {
            let w = rect.width / contentScale * scaleFactor
            let h = rect.height / contentScale * scaleFactor
            if w > 32, h > 32 {
                measuredContentPixels = (Int(w), Int(h))
            }
        }

        resumed = true
        continuation?.resume()
        continuation = nil
    }
}
