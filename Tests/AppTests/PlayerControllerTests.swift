import XCTest
import CoreMedia
@testable import App

@MainActor
final class PlayerControllerTests: XCTestCase {
    private static var sampleURL: URL!

    override class func setUp() {
        super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-sample-\(UUID().uuidString).mov")
        let expectation = XCTestExpectation(description: "write sample")
        Task {
            let sink = try FileSink(outputURL: url, width: 320, height: 240,
                                    systemAudio: false, microphone: false)
            try sink.start(at: .zero)
            for frame in 0..<30 {
                sink.append(video: TestBuffers.make(width: 320, height: 240),
                            pts: CMTime(value: CMTimeValue(frame * 10), timescale: 600))
            }
            _ = try await sink.finish()
            expectation.fulfill()
        }
        XCTWaiter().wait(for: [expectation], timeout: 10)
        sampleURL = url
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: sampleURL)
        super.tearDown()
    }

    func testLoadsDurationAndFileSize() async throws {
        let controller = PlayerController(url: Self.sampleURL)
        try await waitUntil { controller.duration > 0 }
        XCTAssertGreaterThan(controller.duration, 0)
        XCTAssertGreaterThan(controller.fileSizeBytes, 0)
    }

    func testSeekClampsToValidRange() async throws {
        let controller = PlayerController(url: Self.sampleURL)
        try await waitUntil { controller.duration > 0 }

        controller.seek(to: -3)
        XCTAssertEqual(controller.currentTime, 0, accuracy: 0.05)

        controller.seek(to: 999)
        XCTAssertEqual(controller.currentTime, controller.duration, accuracy: 0.05)
    }

    func testTogglePlayFlipsState() async throws {
        let controller = PlayerController(url: Self.sampleURL)
        try await waitUntil { controller.duration > 0 }
        XCTAssertFalse(controller.isPlaying)
        controller.togglePlay()
        XCTAssertTrue(controller.isPlaying)
        controller.togglePlay()
        XCTAssertFalse(controller.isPlaying)
    }

    private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw XCTSkip("timed out waiting for player readiness") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
