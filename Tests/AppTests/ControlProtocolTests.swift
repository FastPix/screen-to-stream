import XCTest
@testable import App

final class ControlProtocolTests: XCTestCase {
    func testCommandRoundTripsWithExactKeyNames() throws {
        let command = ControlCommand(id: "c1", issuedAt: 1000, kind: "start_recording",
                                     source: "window", window: "Safari", display: 2,
                                     resolution: "2160p", camera: true,
                                     cameraPosition: "top-left", cameraSize: "large",
                                     microphone: false, systemAudio: true, upload: nil)
        let data = try JSONEncoder().encode(command)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // These keys are the cross-codebase contract — App and MCPCore must agree byte-for-byte.
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["id"] as? String, "c1")
        XCTAssertEqual(json["issuedAt"] as? Double, 1000)
        XCTAssertEqual(json["kind"] as? String, "start_recording")
        XCTAssertEqual(json["systemAudio"] as? Bool, true)
        XCTAssertEqual(json["camera"] as? Bool, true)
        XCTAssertEqual(json["display"] as? Int, 2)
        XCTAssertEqual(json["cameraPosition"] as? String, "top-left")
        XCTAssertEqual(json["cameraSize"] as? String, "large")

        let decoded = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(decoded, command)
    }

    func testResultRoundTripKeys() throws {
        let result = ControlResult(id: "c1", accepted: true, message: "ok",
                                   entryId: "e1", playbackURL: "https://play.fastpix.com/?playbackId=p")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
        XCTAssertEqual(json["accepted"] as? Bool, true)
        XCTAssertEqual(json["entryId"] as? String, "e1")
        XCTAssertEqual(json["playbackURL"] as? String, "https://play.fastpix.com/?playbackId=p")
    }

    func testStateRoundTripKeys() throws {
        let state = ControlState(state: "recording", elapsedSec: 12.5, entryId: "e1")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        XCTAssertEqual(json["state"] as? String, "recording")
        XCTAssertEqual(json["elapsedSec"] as? Double, 12.5)
    }

    func testExpiry() {
        let command = ControlCommand(id: "c1", issuedAt: 1000, kind: "stop_recording")
        XCTAssertTrue(command.isExpired(now: 1011))    // 11 s old
        XCTAssertFalse(command.isExpired(now: 1005))   // 5 s old
    }

    func testEnsureLayoutCreatesTreeWith0700() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-\(UUID().uuidString)")
        let dir = ControlDirectory(root: base)
        try dir.ensureLayout()

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.commands.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.results.path))

        let perms = try FileManager.default.attributesOfItem(atPath: base.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o700)
    }
}
