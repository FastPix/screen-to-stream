import AppKit
import AVFoundation
import ScreenCaptureKit

enum PermissionStatus {
    case granted
    case denied
    case undetermined
}

@MainActor
final class PermissionManager: ObservableObject {
    enum Pane {
        case screenRecording
        case camera
        case microphone
    }

    @Published var screen: PermissionStatus = .undetermined
    @Published var camera: PermissionStatus = .undetermined
    @Published var microphone: PermissionStatus = .undetermined

    func refresh() async {
        // Trust only the real SCK call; CGPreflight diverges from SCK on macOS 15+.
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            screen = .granted
        } catch {
            screen = CGPreflightScreenCaptureAccess() ? .denied : .undetermined
        }

        camera = Self.status(for: .video)
        microphone = Self.status(for: .audio)
        AppLogger.shared.log("App", "permissions screen=\(screen) camera=\(camera) mic=\(microphone)")
    }

    func requestScreen() async {
        CGRequestScreenCaptureAccess()
        await refresh()
    }

    func requestCamera() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        await refresh()
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await refresh()
    }

    func openSystemSettings(_ pane: Pane) {
        let anchor: String

        switch pane {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func status(for mediaType: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }
}
