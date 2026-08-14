import XCTest
@testable import MCPCore

final class JSONRPCTests: XCTestCase {
    func testEncodeIsNewlineTerminatedJSON() throws {
        let response = RPCResponse.success(id: .number(1), .object(["ok": .bool(true)]))
        let data = Framing.encode(response)

        XCTAssertEqual(data.last, 0x0A)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? Int, 1)
    }

    func testDecodePullsOneMessageLeavingRemainder() {
        var buffer = Data(#"{"jsonrpc":"2.0","id":1,"method":"a"}"#.utf8)
        buffer.append(0x0A)
        buffer.append(Data(#"{"jsonrpc":"2.0","id":2,"method":"b"}"#.utf8))   // partial, no newline

        let first = Framing.decode(from: &buffer)
        XCTAssertEqual(first?.method, "a")
        XCTAssertNil(Framing.decode(from: &buffer))   // second line incomplete

        buffer.append(0x0A)
        XCTAssertEqual(Framing.decode(from: &buffer)?.method, "b")
    }

    func testDecodeSkipsBlankLines() {
        var buffer = Data("\n".utf8)
        buffer.append(Data(#"{"jsonrpc":"2.0","id":1,"method":"x"}"#.utf8))
        buffer.append(0x0A)
        XCTAssertEqual(Framing.decode(from: &buffer)?.method, "x")
    }
}
