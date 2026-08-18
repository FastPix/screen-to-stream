import XCTest
@testable import App

final class StatusPollerTests: XCTestCase {
    func testDelaysDoubleAndCap() {
        let delays = Array(StatusPoller.delays(initial: 2, cap: 10, deadline: 600).prefix(5))
        XCTAssertEqual(delays, [2, 4, 8, 10, 10])
    }

    func testDelaysSumNeverExceedsDeadline() {
        var sum = 0.0
        for delay in StatusPoller.delays(initial: 2, cap: 10, deadline: 30) {
            sum += delay
            XCTAssertLessThanOrEqual(sum, 30)
        }
        XCTAssertGreaterThan(sum, 0)
    }

    func testPollReturnsWhenDone() async throws {
        var probeCount = 0
        var clock = 0.0

        let result = try await StatusPoller.poll(
            probe: { probeCount += 1; return probeCount },
            isDone: { $0 >= 3 },
            sleep: { clock += $0 },
            now: { clock }
        )

        XCTAssertEqual(result, 3)
        XCTAssertEqual(probeCount, 3)
    }

    func testPollThrowsPastDeadline() async {
        var clock = 0.0

        do {
            _ = try await StatusPoller.poll(
                probe: { "still processing" },
                isDone: { _ in false },
                sleep: { clock += $0 },
                now: { clock },
                deadline: 30
            )
            XCTFail("expected deadline")
        } catch StatusPollerError.deadlineExceeded {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
