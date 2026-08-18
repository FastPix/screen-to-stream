import XCTest
@testable import App

@MainActor
final class UploadCoordinatorTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    private func makeSourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-\(UUID().uuidString).mov")
        try Data("video".utf8).write(to: url)
        return url
    }

    private func makeCoordinator(uploader: Uploader, copied: @escaping (String) -> Void,
                                 history: HistoryStore) -> UploadCoordinator {
        let api = FastPixAPI(session: StubURLProtocol.session(), authProvider: { "Basic xyz" })
        return UploadCoordinator(
            api: api, uploader: uploader, history: history,
            sleeper: { _ in },                          // no real waiting in tests
            clock: { 0 },                                // deadline never trips here
            copyToClipboard: copied
        )
    }

    func testHappyPathReachesReadyWithShareLink() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/upload", status: 201,
            json: #"{"success":true,"data":{"url":"https://s/u","uploadId":"m1"}}"#)
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 200,
            json: #"{"success":true,"data":{"id":"m1","status":"Ready","playbackIds":[{"id":"pb_1"}],"duration":"00:00:06"}}"#)

        let source = try makeSourceFile()
        var copied: String?
        let history = HistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("h-\(UUID().uuidString)"))
        let coordinator = makeCoordinator(uploader: FakeUploader(), copied: { copied = $0 }, history: history)

        history.add(HistoryEntry.local(id: "e1", fileURL: source, durationSec: nil, thumbnailPath: nil))
        await coordinator.start(entryId: "e1", fileURL: source, trim: nil, keepLocal: false)

        XCTAssertEqual(coordinator.phase, .ready(playbackURL: "https://play.fastpix.com/?playbackId=pb_1"))
        XCTAssertEqual(copied, "https://play.fastpix.com/?playbackId=pb_1")
        XCTAssertEqual(history.entries.count, 1)                 // updated in place, not duplicated
        XCTAssertEqual(history.entries.first?.status, "ready")
        XCTAssertEqual(history.entries.first?.playbackId, "pb_1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))  // deleted, keepLocal=false
    }

    func testFiresChaptersWhenEnabled() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/upload", status: 201,
            json: #"{"success":true,"data":{"url":"https://s/u","uploadId":"m1"}}"#)
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 200,
            json: #"{"success":true,"data":{"id":"m1","status":"Ready","playbackIds":[{"id":"pb_1"}]}}"#)
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1/chapters", status: 200,
            json: #"{"success":true}"#)

        let source = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let history = HistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("h-\(UUID().uuidString)"))
        let coordinator = makeCoordinator(uploader: FakeUploader(), copied: { _ in }, history: history)

        history.add(HistoryEntry.local(id: "e1", fileURL: source, durationSec: nil, thumbnailPath: nil))
        await coordinator.start(entryId: "e1", fileURL: source, trim: nil, keepLocal: false,
                                features: AIFeatures(generateSubtitles: true, generateChapters: true))

        XCTAssertTrue(StubURLProtocol.recordedRequests().contains {
            $0.url?.absoluteString == "https://api.fastpix.com/v1/on-demand/m1/chapters" && $0.httpMethod == "PATCH"
        })
    }

    func testNotFoundDuringPollingKeepsWaiting() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/upload", status: 201,
            json: #"{"success":true,"data":{"url":"https://s/u","uploadId":"m1"}}"#)
        // GCS PUT done but media not created yet → 404 twice, then Ready.
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 404,
            json: #"{"success":false,"error":{"code":"MEDIA_WORKSPACE_NOT_FOUND"}}"#)
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 404,
            json: #"{"success":false,"error":{"code":"MEDIA_WORKSPACE_NOT_FOUND"}}"#)
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 200,
            json: #"{"success":true,"data":{"id":"m1","status":"Ready","playbackIds":[{"id":"pb_1"}]}}"#)

        let source = try makeSourceFile()
        let history = HistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("h-\(UUID().uuidString)"))
        let coordinator = makeCoordinator(uploader: FakeUploader(), copied: { _ in }, history: history)

        history.add(HistoryEntry.local(id: "e1", fileURL: source, durationSec: nil, thumbnailPath: nil))
        await coordinator.start(entryId: "e1", fileURL: source, trim: nil, keepLocal: false)

        XCTAssertEqual(coordinator.phase, .ready(playbackURL: "https://play.fastpix.com/?playbackId=pb_1"))
        // create + 3 media polls
        XCTAssertEqual(StubURLProtocol.recordedRequests().count, 4)
    }

    func testCreate401FailsAndRetainsFile() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/upload", status: 401,
            json: #"{"code":401,"message":"unauthorized"}"#)

        let source = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let history = HistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("h-\(UUID().uuidString)"))
        let coordinator = makeCoordinator(uploader: FakeUploader(), copied: { _ in }, history: history)

        history.add(HistoryEntry.local(id: "e1", fileURL: source, durationSec: nil, thumbnailPath: nil))
        await coordinator.start(entryId: "e1", fileURL: source, trim: nil, keepLocal: false)

        guard case .failed(let message) = coordinator.phase else { return XCTFail("expected failed") }
        XCTAssertTrue(message.contains("401"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))  // never lose the recording
    }

    func testTransferFailureThenRetrySucceeds() async throws {
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/upload", status: 201,
            json: #"{"success":true,"data":{"url":"https://s/u","uploadId":"m1"}}"#)

        let source = try makeSourceFile()
        defer { try? FileManager.default.removeItem(at: source) }
        let uploader = FakeUploader(); uploader.failCount = 1     // first upload throws, then succeeds
        let history = HistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("h-\(UUID().uuidString)"))
        let coordinator = makeCoordinator(uploader: uploader, copied: { _ in }, history: history)

        history.add(HistoryEntry.local(id: "e1", fileURL: source, durationSec: nil, thumbnailPath: nil))
        await coordinator.start(entryId: "e1", fileURL: source, trim: nil, keepLocal: false)
        guard case .failed = coordinator.phase else { return XCTFail("expected failed after transfer error") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        // retry reuses the signed URL; enqueue the media Ready for the second attempt's poll
        StubURLProtocol.enqueue("https://api.fastpix.com/v1/on-demand/m1", status: 200,
            json: #"{"success":true,"data":{"id":"m1","status":"Ready","playbackIds":[{"id":"pb_1"}]}}"#)
        await coordinator.retry()

        XCTAssertEqual(coordinator.phase, .ready(playbackURL: "https://play.fastpix.com/?playbackId=pb_1"))
    }
}

final class FakeUploader: Uploader {
    var failCount = 0
    private var attempts = 0

    func upload(file: URL, to signedURL: URL, progress: @escaping (Double) -> Void) async throws {
        attempts += 1
        if attempts <= failCount {
            throw FastPixAPIError(statusCode: 0, body: "network dropped")
        }
        progress(0.5)
        progress(1.0)
    }

    func cancel() {}
}
