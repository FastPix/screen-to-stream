import XCTest
@testable import App

final class HistoryEntryTests: XCTestCase {
    private func local(status: String? = nil) -> HistoryEntry {
        var entry = HistoryEntry.local(id: "r1",
                                       fileURL: URL(fileURLWithPath: "/tmp/rec.mov"),
                                       durationSec: 12, thumbnailPath: "/tmp/t.jpg")
        if let status { entry.status = status }
        return entry
    }

    func testLocalFactoryProducesLocalEntry() {
        let entry = local()
        XCTAssertEqual(entry.id, "r1")
        XCTAssertEqual(entry.statusValue, .local)
        XCTAssertFalse(entry.isUploaded)
        XCTAssertEqual(entry.localFileURL, "/tmp/rec.mov")
        XCTAssertEqual(entry.durationSec, 12)
        XCTAssertEqual(entry.thumbnailPath, "/tmp/t.jpg")
        XCTAssertNil(entry.mediaId)
        XCTAssertNil(entry.playbackId)
    }

    func testStatusValueRoundTrips() {
        for raw in ["local", "uploading", "processing", "ready", "failed"] {
            XCTAssertEqual(local(status: raw).statusValue.rawValue, raw)
        }
    }

    func testUnknownStatusFallsBackToLocal() {
        XCTAssertEqual(local(status: "bogus").statusValue, .local)
    }

    func testIsUploadedOnlyWhenReady() {
        XCTAssertTrue(local(status: "ready").isUploaded)
        XCTAssertFalse(local(status: "processing").isUploaded)
    }

    func testLocalFileExistsReflectsDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exists-\(UUID().uuidString).mov")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = HistoryEntry.local(id: "r", fileURL: url, durationSec: nil, thumbnailPath: nil)
        XCTAssertTrue(entry.localFileExists)

        let missing = HistoryEntry.local(id: "r", fileURL: URL(fileURLWithPath: "/nope/x.mov"),
                                         durationSec: nil, thumbnailPath: nil)
        XCTAssertFalse(missing.localFileExists)
    }
}
