import XCTest
@testable import App

final class DirectUploaderTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func tempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func testSuccessfulPutCompletesAndReportsFinalProgress() async throws {
        StubURLProtocol.enqueue("https://s/u", status: 200, json: "")
        let file = try tempFile(bytes: 2048)
        defer { try? FileManager.default.removeItem(at: file) }

        var last: Double = -1
        try await DirectUploader(session: StubURLProtocol.session())
            .upload(file: file, to: URL(string: "https://s/u")!) { last = $0 }

        XCTAssertEqual(last, 1.0, accuracy: 0.0001)

        let request = StubURLProtocol.recordedRequests().first!
        XCTAssertEqual(request.httpMethod, "PUT")
    }

    func testHttpErrorThrows() async throws {
        StubURLProtocol.enqueue("https://s/u", status: 403, json: #"{"error":"denied"}"#)
        let file = try tempFile(bytes: 512)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            try await DirectUploader(session: StubURLProtocol.session())
                .upload(file: file, to: URL(string: "https://s/u")!) { _ in }
            XCTFail("expected throw")
        } catch let error as FastPixAPIError {
            XCTAssertEqual(error.statusCode, 403)
        }
    }
}
