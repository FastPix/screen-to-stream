import XCTest
import CoreMedia
@testable import App

final class TimestampPolicyTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    func testPassesThroughRawIncreasingPTS() {
        var policy = TimestampPolicy(sessionStart: t(100))
        XCTAssertEqual(policy.videoPTS(for: t(100)), t(100))
        XCTAssertEqual(policy.videoPTS(for: t(100.5)), t(100.5))
    }

    func testDropsNonMonotonicPTS() {
        var policy = TimestampPolicy(sessionStart: t(100))
        XCTAssertEqual(policy.videoPTS(for: t(100.5)), t(100.5))
        // A duplicate/backward PTS (as a live resize burst delivers) is dropped, not nudged —
        // nudging crams the burst into a sliver of time and inflates the encoded frame rate.
        XCTAssertNil(policy.videoPTS(for: t(100.5)))
        XCTAssertNil(policy.videoPTS(for: t(100.2)))
        // A later frame after the drops still passes.
        XCTAssertEqual(policy.videoPTS(for: t(100.7)), t(100.7))
    }

    func testDropsVideoBeforeSessionStart() {
        var policy = TimestampPolicy(sessionStart: t(100))
        XCTAssertNil(policy.videoPTS(for: t(99.9)))
    }

    func testDropsPreSessionAudio() {
        let policy = TimestampPolicy(sessionStart: t(100))
        XCTAssertTrue(policy.shouldDropAudio(at: t(99.9)))
        XCTAssertFalse(policy.shouldDropAudio(at: t(100.1)))
    }

    func testAcceptsAudioExactlyAtSessionStart() {
        let policy = TimestampPolicy(sessionStart: t(100))
        XCTAssertFalse(policy.shouldDropAudio(at: t(100)))
    }
}
