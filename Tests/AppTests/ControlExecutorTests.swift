import XCTest
@testable import App

final class ControlExecutorTests: XCTestCase {
    func testResolutionMapping() {
        XCTAssertEqual(ControlExecutor.resolution(from: nil), "1080p")
        XCTAssertEqual(ControlExecutor.resolution(from: "4k"), "2160p")
        XCTAssertEqual(ControlExecutor.resolution(from: "4K"), "2160p")
        XCTAssertEqual(ControlExecutor.resolution(from: "2160p"), "2160p")
        XCTAssertEqual(ControlExecutor.resolution(from: "1080p"), "1080p")
        XCTAssertEqual(ControlExecutor.resolution(from: "720p"), "720p")
        XCTAssertEqual(ControlExecutor.resolution(from: "480p"), "480p")
        // No pass-through: unknown strings must never reach the API.
        XCTAssertEqual(ControlExecutor.resolution(from: "garbage"), "1080p")
        XCTAssertEqual(ControlExecutor.resolution(from: "9999p"), "1080p")
    }

    func testFlagDefaults() {
        let bare = ControlCommand(id: "c", issuedAt: 0, kind: "start_recording")
        let flags = ControlExecutor.flags(from: bare)
        XCTAssertFalse(flags.camera)        // camera off by default
        XCTAssertTrue(flags.microphone)     // mic on
        XCTAssertTrue(flags.systemAudio)    // system audio on
    }

    func testFlagOverrides() {
        let command = ControlCommand(id: "c", issuedAt: 0, kind: "start_recording",
                                     camera: true, microphone: false, systemAudio: false)
        let flags = ControlExecutor.flags(from: command)
        XCTAssertTrue(flags.camera)
        XCTAssertFalse(flags.microphone)
        XCTAssertFalse(flags.systemAudio)
    }

    @MainActor
    func testStartRejectionByScreen() {
        // Only actively-busy screens reject — and these are exactly the non-idle states the
        // status file reports, so status "idle" always means start will be accepted.
        XCTAssertEqual(ControlExecutor.startRejection(screen: .recording), "already recording")
        XCTAssertEqual(ControlExecutor.startRejection(screen: .countdown(3)), "already recording")
        XCTAssertNotNil(ControlExecutor.startRejection(screen: .uploading))

        for idle in [AppState.Screen.sourcePicker, .library, .permissions,
                     .review(URL(fileURLWithPath: "/x.mov")), .settings,
                     .done(playbackURL: "u"), .error("boom")] {
            XCTAssertNil(ControlExecutor.startRejection(screen: idle), "\(idle) should allow start")
        }
    }

    func testPipCenterPresets() {
        XCTAssertEqual(ControlExecutor.pipCenter(from: "bottom-left"), CGPoint(x: 0.15, y: 0.15))
        XCTAssertEqual(ControlExecutor.pipCenter(from: "TOP-RIGHT"), CGPoint(x: 0.85, y: 0.85))
        XCTAssertEqual(ControlExecutor.pipCenter(from: "top_left"), CGPoint(x: 0.15, y: 0.85))
        XCTAssertEqual(ControlExecutor.pipCenter(from: "center"), CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(ControlExecutor.pipCenter(from: nil))          // default position
        XCTAssertNil(ControlExecutor.pipCenter(from: "diagonal"))   // unknown → default
    }

    func testPipDiameterPresets() {
        XCTAssertEqual(ControlExecutor.pipDiameter(from: "small"), 0.15)
        XCTAssertEqual(ControlExecutor.pipDiameter(from: "large"), 0.30)
        XCTAssertEqual(ControlExecutor.pipDiameter(from: "medium"), 0.22)
        XCTAssertEqual(ControlExecutor.pipDiameter(from: nil), 0.22)
    }

    func testWindowMatching() {
        let candidates = [
            (id: "w1", title: "Package.swift — screen-to-stream", app: "Code"),
            (id: "w2", title: "FastPix — Safari", app: "Safari"),
            (id: "w3", title: "Inbox", app: "Mail"),
        ]
        XCTAssertEqual(ControlExecutor.matchWindow("Inbox", in: candidates), "w3")     // exact title
        XCTAssertEqual(ControlExecutor.matchWindow("package", in: candidates), "w1")   // title contains
        XCTAssertEqual(ControlExecutor.matchWindow("safari", in: candidates), "w2")    // title contains (before app)
        XCTAssertEqual(ControlExecutor.matchWindow("mail", in: candidates), "w3")      // app-name contains
        XCTAssertNil(ControlExecutor.matchWindow("nonexistent", in: candidates))
    }

    @MainActor
    func testControlStatePublishesRecordingState() throws {
        let dir = ControlDirectory()
        try? FileManager.default.removeItem(at: dir.stateFile)

        let state = AppState()
        state.setControlEnabled(true)
        defer { state.setControlEnabled(false) }

        // At idle after enabling, state.json says idle.
        let data = try Data(contentsOf: dir.stateFile)
        let published = try JSONDecoder().decode(ControlState.self, from: data)
        XCTAssertEqual(published.state, "idle")
    }
}
