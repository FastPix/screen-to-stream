import XCTest
@testable import App

/// Real end-to-end against api.fastpix.com through the production coordinator. Skipped unless
/// `FP_LIVE=1` with `FP_TOKEN_ID` / `FP_SECRET` set — never runs in CI or a normal `swift test`.
@MainActor
final class LiveUploadIntegrationTests: XCTestCase {
    func testRealRecordingUploadsToReady() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["FP_LIVE"] == "1", "set FP_LIVE=1 to run the live upload test")

        let tokenId = try XCTUnwrap(env["FP_TOKEN_ID"])
        let secret = try XCTUnwrap(env["FP_SECRET"])
        let header = "Basic " + Data("\(tokenId):\(secret)".utf8).base64EncodedString()

        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenToStream", isDirectory: true)
        let recording = try XCTUnwrap(
            (try? FileManager.default.contentsOfDirectory(at: movies, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "mov" }.sorted(by: { $0.path > $1.path }).first,
            "no recording in ~/Movies/ScreenToStream to upload")

        let history = HistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString)"))
        let coordinator = UploadCoordinator(
            api: FastPixAPI(authProvider: { header }),
            uploader: DirectUploader(),
            history: history,
            maxResolution: "1080p")

        // keepLocal: true — never delete the user's real recording.
        history.add(HistoryEntry.local(id: "live", fileURL: recording, durationSec: nil, thumbnailPath: nil))
        await coordinator.start(entryId: "live", fileURL: recording, trim: nil, keepLocal: true)

        guard case .ready(let playbackURL) = coordinator.phase else {
            return XCTFail("expected ready, got \(coordinator.phase)")
        }
        XCTAssertTrue(playbackURL.hasPrefix("https://play.fastpix.com/?playbackId="))
        XCTAssertEqual(history.entries.first?.status, "ready")
        print("LIVE OK → \(playbackURL)")
    }
}
