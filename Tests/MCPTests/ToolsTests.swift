import XCTest
@testable import MCPCore

final class ToolsTests: XCTestCase {
    private let fixture: [Recording] = {
        let json = """
        { "schemaVersion": 1, "entries": [
          { "id": "a", "kind": "recording", "createdAt": 1000, "status": "ready",
            "title": "Demo login flow", "durationSec": 12, "tags": ["demo","auth"],
            "playbackURL": "https://play.fastpix.com/?playbackId=pb_a", "chapters": [],
            "ai": {"summary":"pending","chapters":"pending","transcript":"pending"},
            "futureField": {"x": 1} },
          { "id": "b", "kind": "recording", "createdAt": 5000, "status": "local",
            "title": "Bug repro", "durationSec": 30, "tags": ["bug"],
            "chapters": [{"start":0,"end":5,"title":"Intro"}],
            "ai": {"summary":"pending","chapters":"pending","transcript":"pending"} } ] }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-\(UUID().uuidString).json")
        try! Data(json.utf8).write(to: url)
        return HistoryReader.load(url)
    }()

    func testLoadToleratesUnknownField() {
        XCTAssertEqual(fixture.count, 2)
        XCTAssertEqual(fixture.first?.id, "a")
    }

    func testListReturnsAll() throws {
        let result = Tools.listRecordings(nil, from: fixture)
        let items = try decodeContent(result)
        XCTAssertEqual(items.count, 2)
    }

    func testListFiltersByQuery() throws {
        let result = Tools.listRecordings(.object(["query": .string("login")]), from: fixture)
        let items = try decodeContent(result)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["id"] as? String, "a")
    }

    func testListFiltersByTag() throws {
        let result = Tools.listRecordings(.object(["tag": .string("bug")]), from: fixture)
        let items = try decodeContent(result)
        XCTAssertEqual(items.map { $0["id"] as? String }, ["b"])
    }

    func testListHonorsLimit() throws {
        let result = Tools.listRecordings(.object(["limit": .number(1)]), from: fixture)
        XCTAssertEqual(try decodeContent(result).count, 1)
    }

    func testGetReturnsFullRecord() throws {
        let result = Tools.getRecording(.object(["id": .string("a")]), from: fixture)
        let detail = try decodeSingle(result)
        XCTAssertEqual(detail["playbackURL"] as? String, "https://play.fastpix.com/?playbackId=pb_a")
    }

    func testGetUnknownIdIsError() {
        let result = Tools.getRecording(.object(["id": .string("zzz")]), from: fixture)
        guard case .object(let object) = result else { return XCTFail() }
        XCTAssertEqual(object["isError"], .bool(true))
    }

    // MARK: - Helpers: unwrap the MCP {content:[{text}]} envelope back into JSON.

    private func contentText(_ value: JSONValue) throws -> String {
        guard case .object(let obj) = value, case .array(let content)? = obj["content"],
              case .object(let first)? = content.first, case .string(let text)? = first["text"] else {
            throw NSError(domain: "test", code: 1)
        }
        return text
    }

    private func decodeContent(_ value: JSONValue) throws -> [[String: Any]] {
        let data = Data(try contentText(value).utf8)
        return try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }

    private func decodeSingle(_ value: JSONValue) throws -> [String: Any] {
        let data = Data(try contentText(value).utf8)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
