import XCTest
@testable import MCPCore

final class ControlToolsTests: XCTestCase {
    private func tempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctl-\(UUID().uuidString)")
        let dir = ControlDirectory(root: root)
        try? FileManager.default.createDirectory(at: dir.commands, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dir.results, withIntermediateDirectories: true)
        return root
    }

    private func enable(_ root: URL) {
        FileManager.default.createFile(atPath: ControlDirectory(root: root).enabledMarker.path, contents: nil)
    }

    private func contentText(_ value: JSONValue) throws -> String {
        guard case .object(let obj) = value, case .array(let content)? = obj["content"],
              case .object(let first)? = content.first, case .string(let text)? = first["text"] else {
            throw NSError(domain: "test", code: 1)
        }
        return text
    }

    func testSendRoundTripsAgainstFakeResponder() async throws {
        let root = tempRoot(); enable(root)
        let dir = ControlDirectory(root: root)
        let client = ControlClient(root: root, launcher: {})

        // Fake app: wait for the command, write a result with the same id.
        let responder = Task {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let file = (try? FileManager.default.contentsOfDirectory(at: dir.commands, includingPropertiesForKeys: nil))?
                    .first(where: { $0.pathExtension == "json" }),
                   let data = try? Data(contentsOf: file),
                   let command = try? JSONDecoder().decode(ControlCommand.self, from: data) {
                    let result = ControlResult(id: command.id, accepted: true, message: "recording started")
                    try? JSONEncoder().encode(result).write(to: dir.results.appendingPathComponent("\(command.id).json"))
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        let command = ControlCommand(id: "c1", issuedAt: Date().timeIntervalSince1970, kind: "start_recording")
        let result = await client.send(command, timeout: 3)
        await responder.value

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.message, "recording started")
    }

    func testSendTimesOutWhenNoResponder() async {
        let root = tempRoot(); enable(root)
        let client = ControlClient(root: root, launcher: {})
        let result = await client.send(
            ControlCommand(id: "c2", issuedAt: Date().timeIntervalSince1970, kind: "stop_recording"),
            timeout: 0.5)
        XCTAssertFalse(result.accepted)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("timed out"))
    }

    func testDisabledRootReportsDisabled() async throws {
        let root = tempRoot()   // no enabled marker
        let client = ControlClient(root: root, launcher: {})
        XCTAssertFalse(client.isEnabled)

        let result = await Tools.startRecording(nil, control: client)
        let text = try contentText(result)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("disabled"))
        // start on a disabled channel is an error result.
        if case .object(let obj) = result { XCTAssertEqual(obj["isError"], .bool(true)) }
    }

    func testStatusReadsStateFile() throws {
        let root = tempRoot(); enable(root)
        let dir = ControlDirectory(root: root)
        try JSONEncoder().encode(ControlState(state: "recording", elapsedSec: 5))
            .write(to: dir.stateFile)

        let client = ControlClient(root: root, launcher: {})
        let text = try contentText(Tools.recordingStatus(control: client))
        XCTAssertTrue(text.contains("recording"))
    }
}
