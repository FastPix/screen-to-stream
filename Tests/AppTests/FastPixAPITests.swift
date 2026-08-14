import XCTest
@testable import App

final class FastPixAPITests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func api(auth: String? = "Basic xyz") -> FastPixAPI {
        FastPixAPI(session: StubURLProtocol.session(), authProvider: { auth })
    }

    func testCreateUploadDecodesUrlAndUploadIdKeys() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/upload", status: 201,
            json: #"{"success":true,"data":{"url":"https://s/u","uploadId":"up_1"}}"#)

        let response: CreateUploadResponse = try await api().send(
            request(path: "/v1/on-demand/upload", method: "POST"), decode: CreateUploadResponse.self)

        XCTAssertEqual(response.signedURL.absoluteString, "https://s/u")
        XCTAssertEqual(response.uploadId, "up_1")
    }

    func testMediaResponseDecodesReadyShape() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 200,
            json: #"{"success":true,"data":{"id":"m1","status":"Ready","playbackIds":[{"id":"pb_1"}],"duration":"00:00:06","thumbnail":"https://img/x.png"}}"#)

        let media: MediaResponse = try await api().send(
            request(path: "/v1/on-demand/m1", method: "GET"), decode: MediaResponse.self)

        XCTAssertEqual(media.status, "Ready")
        XCTAssertEqual(media.playbackIds.first?.id, "pb_1")
        XCTAssertEqual(media.duration, "00:00:06")
        XCTAssertEqual(media.thumbnail, "https://img/x.png")
    }

    func testNon2xxThrowsTypedError() async {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 401,
            json: #"{"code":401,"message":"unauthorized"}"#)

        do {
            _ = try await api().send(request(path: "/v1/on-demand/m1", method: "GET"),
                                     decode: MediaResponse.self)
            XCTFail("expected throw")
        } catch let error as FastPixAPIError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertTrue(error.body.contains("unauthorized"))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testGetRetriesOnceOn500ThenSucceeds() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 500, json: "{}")
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 200,
            json: #"{"success":true,"data":{"id":"m1","status":"Ready","playbackIds":[]}}"#)

        let media: MediaResponse = try await api().send(
            request(path: "/v1/on-demand/m1", method: "GET"), decode: MediaResponse.self)

        XCTAssertEqual(media.status, "Ready")
        XCTAssertEqual(StubURLProtocol.recordedRequests().count, 2)
    }

    func testPostIsNotRetried() async {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/upload", status: 500, json: "{}")

        _ = try? await api().send(request(path: "/v1/on-demand/upload", method: "POST"),
                                  decode: CreateUploadResponse.self)

        XCTAssertEqual(StubURLProtocol.recordedRequests().count, 1)
    }

    func testAuthorizedThrowsWhenNoCredentials() {
        var req = request(path: "/v1/on-demand/upload", method: "POST")
        XCTAssertThrowsError(try api(auth: nil).authorized(&req))
    }

    private func request(path: String, method: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.fastpix.com\(path)")!)
        req.httpMethod = method
        return req
    }
}
