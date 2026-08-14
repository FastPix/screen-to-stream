import XCTest
@testable import MCPCore

/// Pins the control-channel JSON contract from the server side. The literal below is the exact
/// shape the app's ControlProtocolTests also asserts — a key rename on either side fails here.
final class ControlProtocolTests: XCTestCase {
    private let commandJSON = #"""
    {"v":1,"id":"c1","issuedAt":1000,"kind":"start_recording","source":"window","window":"Safari","display":2,"resolution":"2160p","camera":true,"cameraPosition":"top-left","cameraSize":"large","microphone":false,"systemAudio":true}
    """#

    func testDecodesTheSharedCommandContract() throws {
        let command = try JSONDecoder().decode(ControlCommand.self, from: Data(commandJSON.utf8))
        XCTAssertEqual(command.id, "c1")
        XCTAssertEqual(command.issuedAt, 1000)
        XCTAssertEqual(command.kind, "start_recording")
        XCTAssertEqual(command.window, "Safari")
        XCTAssertEqual(command.display, 2)
        XCTAssertEqual(command.resolution, "2160p")
        XCTAssertEqual(command.camera, true)
        XCTAssertEqual(command.cameraPosition, "top-left")
        XCTAssertEqual(command.cameraSize, "large")
        XCTAssertEqual(command.microphone, false)
        XCTAssertEqual(command.systemAudio, true)
    }

    func testResultEncodesExpectedKeys() throws {
        let result = ControlResult(id: "c1", accepted: false, message: "control is disabled")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
        XCTAssertEqual(json["id"] as? String, "c1")
        XCTAssertEqual(json["accepted"] as? Bool, false)
        XCTAssertEqual(json["message"] as? String, "control is disabled")
    }

    func testStateDecodes() throws {
        let state = try JSONDecoder().decode(ControlState.self,
            from: Data(#"{"state":"recording","elapsedSec":12.5,"entryId":"e1"}"#.utf8))
        XCTAssertEqual(state.state, "recording")
        XCTAssertEqual(state.elapsedSec, 12.5)
        XCTAssertEqual(state.entryId, "e1")
    }
}
