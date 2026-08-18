import XCTest
import CoreMedia
@testable import App

final class TrimRangeTests: XCTestCase {
    func testStartsAsFullRangeNoop() {
        let range = TrimRange(duration: 20)
        XCTAssertEqual(range.start, 0)
        XCTAssertEqual(range.end, 20)
        XCTAssertTrue(range.isNoop)
    }

    func testMoveStartClampsToZero() {
        var range = TrimRange(duration: 20)
        range.moveStart(to: -5)
        XCTAssertEqual(range.start, 0)
    }

    func testMoveEndClampsToDuration() {
        var range = TrimRange(duration: 20)
        range.moveEnd(to: 25)
        XCTAssertEqual(range.end, 20)
    }

    func testHandlesCannotCrossCloserThanMinimum() {
        var range = TrimRange(duration: 20)
        range.moveEnd(to: 10)
        range.moveStart(to: 15)
        XCTAssertEqual(range.start, 10 - TrimRange.minimumLength, accuracy: 0.001)

        range.moveEnd(to: range.start)
        XCTAssertEqual(range.end, range.start + TrimRange.minimumLength, accuracy: 0.001)
    }

    func testAnyMovedHandleIsNotNoop() {
        var range = TrimRange(duration: 20)
        range.moveStart(to: 1)
        XCTAssertFalse(range.isNoop)
        XCTAssertEqual(range.trimmedLength, 19, accuracy: 0.001)
    }

    func testTimeRangeUsesTimescale600() {
        var range = TrimRange(duration: 20)
        range.moveStart(to: 2.5)
        range.moveEnd(to: 10)
        XCTAssertEqual(range.timeRange.start, CMTime(seconds: 2.5, preferredTimescale: 600))
        XCTAssertEqual(range.timeRange.duration, CMTime(seconds: 7.5, preferredTimescale: 600))
    }
}
