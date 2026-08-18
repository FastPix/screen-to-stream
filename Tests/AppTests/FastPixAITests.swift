import XCTest
@testable import App

final class FastPixAITests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func api() -> FastPixAPI {
        FastPixAPI(session: StubURLProtocol.session(), authProvider: { "Basic xyz" })
    }

    func testTriggersChaptersWhenEnabled() async {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1/chapters", status: 200,
            json: #"{"success":true}"#)

        await api().triggerEnrichment(mediaId: "m1", features: AIFeatures(generateSubtitles: true, generateChapters: true))

        let request = StubURLProtocol.recordedRequests().first
        XCTAssertEqual(request?.httpMethod, "PATCH")
        XCTAssertEqual(request?.url?.absoluteString, "https://api.fastpix.com/v1/on-demand/m1/chapters")
    }

    func testTriggersNothingWhenDisabled() async {
        await api().triggerEnrichment(mediaId: "m1", features: AIFeatures(generateSubtitles: true, generateChapters: false))
        XCTAssertEqual(StubURLProtocol.recordedRequests().count, 0)
    }

    func testTriggerSwallowsErrorResponse() async {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1/chapters", status: 400,
            json: #"{"error":{"message":"AI features are not available for this organization"}}"#)

        // Must not throw — signature is non-throwing and the test passing is the assertion.
        await api().triggerEnrichment(mediaId: "m1", features: AIFeatures(generateSubtitles: false, generateChapters: true))
    }

    func testDeleteMediaSucceedsOn200() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 200,
            json: #"{"success":true}"#)

        try await api().deleteMedia(id: "m1")

        let request = StubURLProtocol.recordedRequests().first
        XCTAssertEqual(request?.httpMethod, "DELETE")
        XCTAssertEqual(request?.url?.absoluteString, "https://api.fastpix.com/v1/on-demand/m1")
    }

    func testDeleteMediaThrowsOnNotFound() async {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 404,
            json: #"{"success":false}"#)

        do {
            try await api().deleteMedia(id: "m1")
            XCTFail("expected throw")
        } catch let error as FastPixAPIError {
            XCTAssertEqual(error.statusCode, 404)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
