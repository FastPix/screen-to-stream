import XCTest
@testable import App

final class FastPixUploadTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func api() -> FastPixAPI {
        FastPixAPI(session: StubURLProtocol.session(), authProvider: { "Basic xyz" })
    }

    func testCreateUploadPostsExpectedBody() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/upload", status: 201,
            json: #"{"success":true,"data":{"url":"https://s/u","uploadId":"up_1"}}"#)

        let response = try await api().createUpload(appVersion: "0.1.0", maxResolution: "1080p")
        XCTAssertEqual(response.uploadId, "up_1")

        let body = StubURLProtocol.recordedBody(for: "https://api.fastpix.com/v1/on-demand/upload")!
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let settings = json["pushMediaSettings"] as! [String: Any]
        XCTAssertEqual(json["corsOrigin"] as? String, "*")
        XCTAssertEqual(settings["maxResolution"] as? String, "1080p")
        XCTAssertEqual(settings["generateSubtitles"] as? Bool, true)
        XCTAssertEqual((settings["metadata"] as? [String: Any])?["source"] as? String, "screen-to-stream")

        let request = StubURLProtocol.recordedRequests().first!
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testCreateUploadOmitsSubtitlesWhenDisabled() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/upload", status: 201,
            json: #"{"success":true,"data":{"url":"https://s/u","uploadId":"up_1"}}"#)

        _ = try await api().createUpload(appVersion: "0.1.0", maxResolution: "1080p",
                                         features: AIFeatures(generateSubtitles: false, generateChapters: false))

        let body = StubURLProtocol.recordedBody(for: "https://api.fastpix.com/v1/on-demand/upload")!
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let settings = json["pushMediaSettings"] as! [String: Any]
        XCTAssertNil(settings["generateSubtitles"])
        // AI feature flags never go in the create body regardless.
        XCTAssertNil(settings["chapters"])
    }

    func testMediaGetsByIdAtExpectedURL() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 200,
            json: #"{"success":true,"data":{"id":"m1","status":"Ready","playbackIds":[{"id":"pb_1"}]}}"#)

        let media = try await api().media(id: "m1")
        XCTAssertEqual(media.playbackIds.first?.id, "pb_1")

        let request = StubURLProtocol.recordedRequests().first!
        XCTAssertEqual(request.url?.absoluteString, "https://api.fastpix.com/v1/on-demand/m1")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testTestConnectionHitsListEndpoint() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand?limit=1", status: 200,
            json: #"{"success":true,"data":[]}"#)

        try await api().testConnection()

        let request = StubURLProtocol.recordedRequests().first!
        XCTAssertEqual(request.url?.absoluteString, "https://api.fastpix.com/v1/on-demand?limit=1")
        XCTAssertEqual(request.httpMethod, "GET")
    }
}
