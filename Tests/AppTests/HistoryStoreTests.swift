import XCTest
@testable import App

@MainActor
final class HistoryStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(id: String, status: String = "ready") -> HistoryEntry {
        HistoryEntry(id: id, kind: "recording", createdAt: Date(),
                     mediaId: id, playbackId: "pb_\(id)",
                     playbackURL: "https://play.fastpix.com/?playbackId=pb_\(id)",
                     hlsURL: nil, durationSec: 6, localFileURL: nil,
                     status: status, title: nil, summary: nil, tags: [],
                     chapters: [], ai: .init(summary: "pending", chapters: "pending", transcript: "pending"))
    }

    func testAddPersistsAndReloads() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        store.add(entry(id: "a"))

        let reloaded = HistoryStore(directory: dir)
        XCTAssertEqual(reloaded.entries.map(\.id), ["a"])
    }

    func testUpdateReplacesById() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        store.add(entry(id: "a", status: "processing"))

        var updated = store.entries[0]
        updated.status = "ready"
        store.update(updated)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].status, "ready")
    }

    func testEnvelopeHasSchemaVersion() throws {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        store.add(entry(id: "a"))

        let data = try Data(contentsOf: dir.appendingPathComponent("history.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
    }

    func testDecodesEnvelopeWithUnknownEntryField() throws {
        let dir = tempDir()
        let json = """
        { "schemaVersion": 1, "entries": [
          { "id": "a", "kind": "live", "createdAt": 0, "status": "ready",
            "tags": [], "chapters": [],
            "ai": { "summary": "pending", "chapters": "pending", "transcript": "pending" },
            "futureField": { "streamKey": "sk_1" } } ] }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("history.json"))

        let store = HistoryStore(directory: dir)
        XCTAssertEqual(store.entries.map(\.id), ["a"])
        XCTAssertEqual(store.entries[0].kind, "live")
    }

    func testPendingProcessingFiltersByStatus() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir)
        store.add(entry(id: "a", status: "ready"))
        store.add(entry(id: "b", status: "processing"))

        XCTAssertEqual(store.pendingProcessing().map(\.id), ["b"])
    }
}
