import AVFoundation
import ScreenCaptureKit

enum CaptureSource: Identifiable, Equatable {
    case display(SCDisplay)
    case window(SCWindow)

    var id: String {
        switch self {
        case .display(let display): return "display-\(display.displayID)"
        case .window(let window): return "window-\(window.windowID)"
        }
    }

    var title: String {
        switch self {
        case .display(let display):
            return "Display \(display.displayID)"
        case .window(let window):
            return window.title?.isEmpty == false ? window.title! : (window.owningApplication?.applicationName ?? "Window")
        }
    }

    var subtitle: String {
        switch self {
        case .display(let display):
            return "\(display.width) × \(display.height)"
        case .window(let window):
            return window.owningApplication?.applicationName ?? ""
        }
    }

    /// True pixel size. SCDisplay.width/height and SCWindow.frame are in POINTS; multiply by each
    /// display's real backing scale (Retina built-in 2×, 1080p external 1×).
    var pixelSize: (width: Int, height: Int) {
        switch self {
        case .display(let display):
            if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                return (mode.pixelWidth, mode.pixelHeight)
            }
            return (display.width * 2, display.height * 2)
        case .window(let window):
            let scale = Self.backingScale(at: window.frame)
            return (Int(window.frame.width * scale), Int(window.frame.height * scale))
        }
    }

    /// Backing scale of the display containing the rect (CG top-left coords, matching
    /// SCWindow.frame). Falls back to 2×.
    static func backingScale(at rect: CGRect) -> CGFloat {
        var id = CGMainDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithRect(rect, 1, &id, &count)
        guard count > 0, let mode = CGDisplayCopyDisplayMode(id) else { return 2 }
        let bounds = CGDisplayBounds(id)
        guard bounds.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / bounds.width
    }

    var appIcon: NSImage? {
        guard case .window(let window) = self,
              let bundleID = window.owningApplication?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct CameraDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let isAvailable: Bool
    let unavailableReason: String?
}

@MainActor
final class SourceCatalog: ObservableObject {
    /// Windows owned by these bundles are chrome, not content.
    nonisolated private static let systemUIBundles: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.systemuiserver",
        "com.apple.wallpaper.agent",
        "com.apple.WallpaperAgent",
        "com.apple.screenshot.launcher",
        "com.apple.screencaptureui",
        "com.apple.loginwindow",
    ]

    /// The facts the picker predicate needs, decoupled from SCWindow so it's unit-testable.
    struct WindowFacts {
        let layer: Int
        let width: CGFloat
        let height: CGFloat
        let bundleID: String?
        /// SCWindow.isOnScreen — true only for windows on a currently *displayed* Space.
        let isOnScreen: Bool
        /// Whether the window's frame covers some display (see `covers(_:anyOf:)`).
        let coversDisplay: Bool
        /// Whether the frame is bigger than every physical display (see `exceedsEveryDisplay`).
        let exceedsAnyDisplay: Bool
    }

    /// Whether a window belongs in the picker: standard layer-0 windows, on-screen or covering a
    /// display (full-screen apps live on their own background Space), above the size floor, not own
    /// or system chrome. A window minimized from full-screen can slip through; picking it fails
    /// with the warmup-timeout message rather than recording black.
    nonisolated static func isListable(_ w: WindowFacts, ownBundleID: String?) -> Bool {
        guard let bundle = w.bundleID else { return false }
        guard w.layer == 0 else { return false }
        guard w.width > 100, w.height > 100 else { return false }
        guard w.isOnScreen || w.coversDisplay else { return false }
        guard !w.exceedsAnyDisplay else { return false }
        guard bundle != ownBundleID else { return false }
        return !systemUIBundles.contains(bundle)
    }

    /// A frame larger than every physical display is a compositor helper (Chromium keeps a
    /// desktop-union-sized overlay), not a recordable window.
    nonisolated static func exceedsEveryDisplay(_ frame: CGRect, displays: [CGRect]) -> Bool {
        guard !displays.isEmpty else { return false }
        return !displays.contains { d in
            frame.width <= d.width + 40 && frame.height <= d.height + 40
        }
    }

    /// Full-screen detector: frame overlaps a display, spans its full width, at least 80% of its
    /// height. Loose on height because apps report different full-screen frames (menu bar,
    /// Chromium noticeably shorter).
    nonisolated static func covers(_ frame: CGRect, anyOf displays: [CGRect]) -> Bool {
        displays.contains { d in
            frame.intersects(d)
                && frame.width >= d.width - 2
                && frame.height >= d.height * 0.8
        }
    }

    @Published private(set) var displays: [CaptureSource] = []
    @Published private(set) var windows: [CaptureSource] = []
    @Published private(set) var cameras: [CameraDevice] = []
    @Published private(set) var thumbnails: [String: CGImage] = [:]

    func refresh() async {
        await refreshScreenSources()
        cameras = Self.discoverCameras()
        await captureThumbnails()
    }

    /// Sources without the slow per-window/display thumbnail capture, for the MCP control path.
    func refreshSources() async {
        await refreshScreenSources()
        cameras = Self.discoverCameras()
    }

    private func captureThumbnails() async {
        await withTaskGroup(of: (String, CGImage?).self) { group in
            for source in displays + windows {
                group.addTask {
                    await (source.id, Self.thumbnail(for: source))
                }
            }

            for await (id, image) in group {
                if let image {
                    thumbnails[id] = image
                }
            }
        }
    }

    private static func thumbnail(for source: CaptureSource) async -> CGImage? {
        let filter: SCContentFilter

        switch source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let (width, height) = source.pixelSize
        let scale = 280.0 / Double(max(width, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(Double(width) * scale), 32)
        configuration.height = max(Int(Double(height) * scale), 32)
        configuration.showsCursor = false

        return try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: configuration)
    }

    private func refreshScreenSources() async {
        // excludeDesktopWindows removes Finder's per-display desktop rows; onScreenWindowsOnly
        // false includes full-screen apps, which live on their own Space.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false
        ) else {
            AppLogger.shared.log("Capture", "source refresh failed — screen recording not granted?")
            return
        }

        let ownBundleID = Bundle.main.bundleIdentifier

        if UserDefaults.standard.bool(forKey: "FPDumpWindows") {
            for w in content.windows {
                AppLogger.shared.log("Capture", "window layer=\(w.windowLayer) onScreen=\(w.isOnScreen) "
                    + "frame=\(Int(w.frame.width))x\(Int(w.frame.height)) app=\(w.owningApplication?.bundleIdentifier ?? "?") title=\(w.title ?? "")")
            }
        }

        let displayFrames = content.displays.map { $0.frame }
        displays = content.displays.map { CaptureSource.display($0) }
        windows = content.windows
            .filter { window in
                Self.isListable(WindowFacts(layer: window.windowLayer,
                                            width: window.frame.width,
                                            height: window.frame.height,
                                            bundleID: window.owningApplication?.bundleIdentifier,
                                            isOnScreen: window.isOnScreen,
                                            coversDisplay: Self.covers(window.frame, anyOf: displayFrames),
                                            exceedsAnyDisplay: Self.exceedsEveryDisplay(window.frame, displays: displayFrames)),
                                ownBundleID: ownBundleID)
            }
            .map { CaptureSource.window($0) }
    }

    private static func discoverCameras() -> [CameraDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )

        return session.devices.map { device in
            do {
                _ = try AVCaptureDeviceInput(device: device)
                return CameraDevice(id: device.uniqueID, name: device.localizedName,
                                    isAvailable: true, unavailableReason: nil)
            } catch {
                return CameraDevice(id: device.uniqueID, name: device.localizedName,
                                    isAvailable: false,
                                    unavailableReason: error.localizedDescription)
            }
        }
    }
}
