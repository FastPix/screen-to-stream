import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let panel: NSPanel

    private var cameraOverlay: CameraOverlayWindow?
    private var stopPill: StopPillWindow?
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let permissions = PermissionManager()
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.title = "ScreenToStream"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Show on the current Space instead of yanking to another.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: ContentView(appState: appState, permissions: permissions)
        )

        statusItem.button?.image = NSImage(systemSymbolName: "record.circle",
                                           accessibilityDescription: "ScreenToStream")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        observeState()
        applyActivationPolicy(dockVisible: appState.preferences.showDockIcon)
        showPanel()
    }

    /// .regular shows the app in Dock and Cmd-Tab; .accessory is the menu-bar-only default.
    private func applyActivationPolicy(dockVisible: Bool) {
        NSApp.setActivationPolicy(dockVisible ? .regular : .accessory)
    }

    @objc func showPanel() {
        panel.center()
        panel.orderFrontRegardless()
        appState.panelIsVisible = true
    }

    private func hidePanel() {
        panel.orderOut(nil)
        appState.panelIsVisible = false
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show ScreenToStream", action: #selector(showPanel), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Library", action: #selector(openLibrary), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ScreenToStream",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // reset so the next left-click toggles the panel again
    }

    @objc private func openLibrary() {
        showPanel()
        appState.showLibrary()
    }

    @objc private func openSettings() {
        showPanel()
        appState.showSettings()
    }

    private func observeState() {
        appState.$screen
            .receive(on: RunLoop.main)
            .sink { [weak self] screen in self?.apply(screen) }
            .store(in: &cancellables)

        appState.$previewCameraID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshCameraOverlay() }
            .store(in: &cancellables)

        appState.preferences.$showDockIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in self?.applyActivationPolicy(dockVisible: visible) }
            .store(in: &cancellables)

        appState.$selectedSource
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.moveOverlayToTargetScreen() }
            .store(in: &cancellables)
    }

    private func apply(_ screen: AppState.Screen) {
        switch screen {
        case .recording:
            hidePanel()
            showStopPill()
            statusItem.button?.image = NSImage(systemSymbolName: "stop.circle.fill",
                                               accessibilityDescription: "Stop recording")
        default:
            stopPill?.orderOut(nil)
            stopPill = nil
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle",
                                               accessibilityDescription: "ScreenToStream")
            if !panel.isVisible {
                panel.orderFrontRegardless()   // don't recenter mid-flow
                appState.panelIsVisible = true
            }
        }

        refreshCameraOverlay()
    }

    private func showStopPill() {
        let pill = StopPillWindow(
            onStop: { [weak self] in self?.appState.stopRecording() },
            elapsed: { [weak self] in self?.appState.elapsed ?? 0 }
        )
        pill.show()
        stopPill = pill
    }

    /// The overlay circle exists only while a camera is selected on picker/countdown/recording;
    /// anything else tears it down.
    private func refreshCameraOverlay() {
        let shouldShow: Bool
        switch appState.screen {
        case .sourcePicker, .countdown, .recording:
            shouldShow = appState.previewCameraID != nil
        default:
            shouldShow = false
        }

        if shouldShow {
            guard cameraOverlay == nil else { return }
            let target = targetOverlayScreen()
            let overlay = CameraOverlayWindow(session: appState.camera.previewSession)
            overlay.onMove = { [weak self] center in self?.appState.pipPosition.center = center }
            if let preset = appState.pendingOverlayCenter {   // MCP camera_position preset
                overlay.position(atNormalized: preset, on: target)
                appState.pendingOverlayCenter = nil
            } else {
                overlay.positionBottomRight(on: target)
            }
            overlay.show()
            appState.pipPosition.center = overlay.normalizedCenter   // seed before the first frame
            cameraOverlay = overlay
        } else {
            cameraOverlay?.teardown()
            cameraOverlay = nil
        }
    }

    /// The screen the overlay lives on: the selected display, or the main screen for a window/no selection.
    private func targetOverlayScreen() -> NSScreen? {
        switch appState.selectedSource {
        case .display(let display):
            return NSScreen.screens.first { $0.displayID == display.displayID } ?? NSScreen.main
        case .window, .none:
            return NSScreen.main
        }
    }

    private func moveOverlayToTargetScreen() {
        guard let overlay = cameraOverlay, let screen = targetOverlayScreen() else { return }
        overlay.move(to: screen)
        appState.pipPosition.center = overlay.normalizedCenter
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

extension MenuBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }

        appState.panelIsVisible = false
        // Closing the panel (not quitting) must not leave the camera or its circle running.
        appState.previewCameraID = nil
        refreshCameraOverlay()
    }
}
