import XCTest
@testable import MCPCore

final class ServerTranscriptTests: XCTestCase {
    private func server() -> Server {
        let json = """
        { "schemaVersion": 1, "entries": [
          { "id": "a", "kind": "recording", "createdAt": 1000, "status": "ready",
            "title": "Demo", "durationSec": 12, "tags": ["demo"],
            "playbackURL": "https://play.fastpix.com/?playbackId=pb_a", "chapters": [],
            "ai": {"summary":"pending","chapters":"pending","transcript":"pending"} } ] }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("t-\(UUID().uuidString).json")
        try! Data(json.utf8).write(to: url)
        return Server(recordings: HistoryReader.load(url))
    }

    private func request(_ method: String, id: Int?, params: JSONValue? = nil) -> RPCRequest {
        RPCRequest(jsonrpc: "2.0", id: id.map(RPCID.number), method: method, params: params)
    }

    func testInitializeHandshake() async {
        let response = await server().handle(request("initialize", id: 1))
        XCTAssertEqual(response?.result?["protocolVersion"]?.stringValue, Server.protocolVersion)
        XCTAssertNotNil(response?.result?["capabilities"]?["tools"])
    }

    func testInitializedNotificationHasNoResponse() async {
        let response = await server().handle(request("notifications/initialized", id: nil))
        XCTAssertNil(response)
    }

    func testToolsListNamesBothTools() async {
        let response = await server().handle(request("tools/list", id: 2))
        guard case .array(let tools)? = response?.result?["tools"] else { return XCTFail() }
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        XCTAssertEqual(names, ["list_recordings", "get_recording",
                               "start_recording", "stop_recording", "get_recording_status"])
    }

    func testCallListRecordings() async throws {
        let response = await server().handle(request("tools/call", id: 3,
            params: .object(["name": .string("list_recordings"), "arguments": .object([:])])))
        let text = try contentText(response)
        XCTAssertTrue(text.contains("\"id\":\"a\""))
    }

    func testCallGetRecordingReturnsPlaybackURL() async throws {
        let response = await server().handle(request("tools/call", id: 4,
            params: .object(["name": .string("get_recording"),
                             "arguments": .object(["id": .string("a")])])))
        let text = try contentText(response)
        XCTAssertTrue(text.contains("https://play.fastpix.com/?playbackId=pb_a"))
    }

    func testUnknownMethodErrors() async {
        let response = await server().handle(request("bogus/method", id: 9))
        XCTAssertEqual(response?.error?.code, -32601)
    }

    private func contentText(_ response: RPCResponse?) throws -> String {
        guard case .array(let content)? = response?.result?["content"],
              case .object(let first)? = content.first, case .string(let text)? = first["text"] else {
            throw NSError(domain: "test", code: 1)
        }
        return text
    }
}
