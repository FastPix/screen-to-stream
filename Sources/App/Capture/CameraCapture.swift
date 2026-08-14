import AVFoundation
import CoreVideo

enum CameraCaptureError: Error {
    case deviceNotFound(String)
    case cannotAddInput
}

/// Camera frames for the composited PiP. The engine's fill timer reads `latestFrame` so the PiP
/// keeps moving even when screen frames stall.
final class CameraCapture: NSObject {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.fastpix.screen-to-stream.camera")
    private let lock = NSLock()

    private var _latestFrame: CVPixelBuffer?
    private var onFrame: ((CVPixelBuffer) -> Void)?
    private(set) var currentDeviceID: String?

    var latestFrame: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return _latestFrame
    }

    /// Idempotent: one session serves the preview overlay and the recording compositor. Re-calling
    /// for the same device is a no-op so recording never restarts the camera.
    func start(deviceID: String, onFrame: ((CVPixelBuffer) -> Void)? = nil) throws {
        if let onFrame { self.onFrame = onFrame }

        if currentDeviceID == deviceID, session.isRunning { return }

        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            throw CameraCaptureError.deviceNotFound(deviceID)
        }

        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.sessionPreset = .hd1280x720

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)

        if session.outputs.isEmpty {
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CameraCaptureError.cannotAddInput
            }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
        }
        session.commitConfiguration()

        currentDeviceID = deviceID
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        AppLogger.shared.log("Capture", "camera started: \(device.localizedName)")
    }

    func stop() {
        currentDeviceID = nil
        guard session.isRunning else { return }

        session.stopRunning()
        lock.lock()
        _latestFrame = nil
        lock.unlock()
        AppLogger.shared.log("Capture", "camera stopped")
    }

    var previewSession: AVCaptureSession { session }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        _latestFrame = buffer
        lock.unlock()
        onFrame?(buffer)
    }
}
