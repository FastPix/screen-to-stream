import XCTest
@testable import App

final class VideoFormatTests: XCTestCase {
    func testFloorsToMultipleOfSixteen() {
        let size = VideoFormat.encodeSize(width: 2940, height: 1912)
        XCTAssertEqual(size.width % 16, 0)
        XCTAssertEqual(size.height % 16, 0)
        XCTAssertLessThanOrEqual(size.width, 2940)
        XCTAssertLessThanOrEqual(size.height, 1912)
    }

    func testClampsToFourK() {
        let size = VideoFormat.encodeSize(width: 6016, height: 3384)
        XCTAssertLessThanOrEqual(size.width, 3840)
        XCTAssertLessThanOrEqual(size.height, 2160)
        XCTAssertEqual(size.width % 16, 0)
        XCTAssertEqual(size.height % 16, 0)
    }

    func testPreservesAspectRatioWhenClamping() {
        let size = VideoFormat.encodeSize(width: 6016, height: 3384)
        XCTAssertEqual(Double(size.width) / Double(size.height), 16.0 / 9.0, accuracy: 0.05)
    }

    func testNeverReturnsZeroForTinySources() {
        let size = VideoFormat.encodeSize(width: 8, height: 8)
        XCTAssertGreaterThanOrEqual(size.width, 16)
        XCTAssertGreaterThanOrEqual(size.height, 16)
    }

    func testBitrateIsPixelsTimesFour() {
        XCTAssertEqual(VideoFormat.bitrate(width: 1920, height: 1080), 1920 * 1080 * 4)
    }
}
