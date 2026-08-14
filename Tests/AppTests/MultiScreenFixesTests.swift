import XCTest
@testable import App

/// Covers the pure decisions behind the multi-screen fixes (Issues A/B/C).
final class MultiScreenFixesTests: XCTestCase {

    // MARK: - Window listing predicate (Issues A + B)

    private func facts(layer: Int = 0, width: CGFloat = 400, height: CGFloat = 300,
                       bundle: String? = "com.example.app",
                       onScreen: Bool = true, covers: Bool = false,
                       exceeds: Bool = false) -> SourceCatalog.WindowFacts {
        SourceCatalog.WindowFacts(layer: layer, width: width, height: height, bundleID: bundle,
                                  isOnScreen: onScreen, coversDisplay: covers,
                                  exceedsAnyDisplay: exceeds)
    }

    func testListsStandardAppWindow() {
        XCTAssertTrue(SourceCatalog.isListable(facts(), ownBundleID: "com.fastpix.app"))
    }

    func testDropsNonZeroLayer() {
        // Desktop / menu-bar / overlay windows live on other layers — this drops the phantom
        // per-display "Finder" desktop rows (Issue A).
        XCTAssertFalse(SourceCatalog.isListable(facts(layer: -1), ownBundleID: nil))
        XCTAssertFalse(SourceCatalog.isListable(facts(layer: 25), ownBundleID: nil))
    }

    func testDropsTinyWindows() {
        XCTAssertFalse(SourceCatalog.isListable(facts(width: 50, height: 300), ownBundleID: nil))
        XCTAssertFalse(SourceCatalog.isListable(facts(width: 300, height: 50), ownBundleID: nil))
    }

    func testDropsOwnAndUnknownAndSystemUI() {
        XCTAssertFalse(SourceCatalog.isListable(facts(bundle: "com.fastpix.app"), ownBundleID: "com.fastpix.app"))
        XCTAssertFalse(SourceCatalog.isListable(facts(bundle: nil), ownBundleID: nil))
        XCTAssertFalse(SourceCatalog.isListable(facts(bundle: "com.apple.dock"), ownBundleID: nil))
        XCTAssertFalse(SourceCatalog.isListable(facts(bundle: "com.apple.loginwindow"), ownBundleID: nil))
    }

    func testDropsInvisiblePreloadWindows() {
        // The window-dump evidence: layer-0 hidden preloads (blank Settings panes, browser
        // autofill templates, loginwindow) are all offscreen and cover no display.
        XCTAssertFalse(SourceCatalog.isListable(facts(width: 500, height: 500, onScreen: false),
                                                ownBundleID: nil))
    }

    func testDropsDesktopSpanningHelperWindows() {
        // Chromium keeps a desktop-union-sized overlay titled like the playing video —
        // capturing it records the whole desktop with the video in one slice.
        XCTAssertFalse(SourceCatalog.isListable(facts(width: 3389, height: 1009,
                                                      covers: true, exceeds: true),
                                                ownBundleID: nil))
    }

    func testExceedsEveryDisplay() {
        let displays = [CGRect(x: 0, y: 0, width: 1470, height: 956),
                        CGRect(x: -1920, y: -124, width: 1920, height: 1080)]
        // Desktop-union-wide helper: bigger than both displays.
        XCTAssertTrue(SourceCatalog.exceedsEveryDisplay(CGRect(x: 0, y: 0, width: 3389, height: 1009),
                                                        displays: displays))
        // A fullscreen window fits its display; a big window fits the larger display.
        XCTAssertFalse(SourceCatalog.exceedsEveryDisplay(CGRect(x: 0, y: 0, width: 1470, height: 923),
                                                         displays: displays))
        XCTAssertFalse(SourceCatalog.exceedsEveryDisplay(CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                                         displays: displays))
        XCTAssertFalse(SourceCatalog.exceedsEveryDisplay(CGRect(x: 0, y: 0, width: 800, height: 600),
                                                         displays: []))
    }

    func testListsFullScreenWindowOnBackgroundSpace() {
        // Full-screen windows on non-displayed Spaces report isOnScreen=false but cover a display.
        XCTAssertTrue(SourceCatalog.isListable(facts(width: 1470, height: 923,
                                                     onScreen: false, covers: true),
                                               ownBundleID: nil))
    }

    func testCoversMatchesFullScreenFramesAcrossApps() {
        let display = CGRect(x: 0, y: 0, width: 1470, height: 956)
        // Firefox/VS Code full screen: display height minus the menu bar.
        XCTAssertTrue(SourceCatalog.covers(CGRect(x: 0, y: 33, width: 1470, height: 923),
                                           anyOf: [display]))
        // Brave/Chromium full screen reports a shorter frame (~88% height) — must still cover.
        XCTAssertTrue(SourceCatalog.covers(CGRect(x: 0, y: 0, width: 1470, height: 842),
                                           anyOf: [display]))
        // Junk is nowhere near 80% height, or doesn't span the width.
        XCTAssertFalse(SourceCatalog.covers(CGRect(x: 0, y: 0, width: 1470, height: 117),
                                            anyOf: [display]))
        XCTAssertFalse(SourceCatalog.covers(CGRect(x: 0, y: 0, width: 500, height: 500),
                                            anyOf: [display]))
        // Off-display frame (a second monitor's fullscreen window vs the wrong display).
        XCTAssertFalse(SourceCatalog.covers(CGRect(x: 2000, y: 0, width: 1470, height: 923),
                                            anyOf: [display]))
    }

    // MARK: - Idle-capture gate (Issue C)

    @MainActor
    func testPickerRefreshOnlyWhenVisibleAndOnPicker() {
        XCTAssertTrue(AppState.shouldAutoRefreshPicker(panelVisible: true, screen: .sourcePicker))
        XCTAssertFalse(AppState.shouldAutoRefreshPicker(panelVisible: false, screen: .sourcePicker))
        XCTAssertFalse(AppState.shouldAutoRefreshPicker(panelVisible: true, screen: .library))
        XCTAssertFalse(AppState.shouldAutoRefreshPicker(panelVisible: true, screen: .recording))
    }
}
