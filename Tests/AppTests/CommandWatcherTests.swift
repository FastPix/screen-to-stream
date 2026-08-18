import XCTest
@testable import App

@MainActor
final class CommandWatcherTests: XCTestCase {
    private func tempDirs() -> (commands: URL, results: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)")
        let commands = base.appendingPathComponent("commands")
        let results = base.appendingPathComponent("results")
        try? FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        return (commands, results)
    }

    private func drop(_ command: ControlCommand, into dir: URL) throws {
        let data = try JSONEncoder().encode(command)
        try data.write(to: dir.appendingPathComponent("\(command.id).json"))
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    /// Poll for a result file (the watcher writes it asynchronously).
    private func waitForResult(_ id: String, in dir: URL, timeout: Double = 2) async throws -> ControlResult? {
        let deadline = Date().addingTimeInterval(timeout)
        let url = dir.appendingPathComponent("\(id).json")
        while Date() < deadline {
            if let data = try? Data(contentsOf: url) {
                return try JSONDecoder().decode(ControlResult.self, from: data)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func testValidCommandInvokesHandlerAndWritesResult() async throws {
        let (commands, results) = tempDirs()
        var handled: ControlCommand?
        let watcher = CommandWatcher(directory: commands, resultsDirectory: results) { command in
            handled = command
            return ControlResult(id: command.id, accepted: true, message: "ok", entryId: "e1")
        }
        watcher.start()
        defer { watcher.stop() }

        try drop(ControlCommand(id: "c1", issuedAt: now(), kind: "start_recording"), into: commands)

        let result = try await waitForResult("c1", in: results)
        XCTAssertEqual(handled?.id, "c1")
        XCTAssertEqual(result?.accepted, true)
        XCTAssertEqual(result?.entryId, "e1")
        // The command file is consumed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: commands.appendingPathComponent("c1.json").path))
    }

    func testExpiredCommandIsRejectedNotHandled() async throws {
        let (commands, results) = tempDirs()
        var handlerCalled = false
        let watcher = CommandWatcher(directory: commands, resultsDirectory: results) { _ in
            handlerCalled = true
            return ControlResult(id: "x", accepted: true, message: "should not run")
        }
        watcher.start()
        defer { watcher.stop() }

        try drop(ControlCommand(id: "old", issuedAt: now() - 30, kind: "start_recording"), into: commands)

        let result = try await waitForResult("old", in: results)
        XCTAssertEqual(result?.accepted, false)
        XCTAssertTrue(result?.message.localizedCaseInsensitiveContains("expired") ?? false)
        XCTAssertFalse(handlerCalled)
    }

    func testGarbageFileIsRemovedWithoutCrashing() async throws {
        let (commands, results) = tempDirs()
        let watcher = CommandWatcher(directory: commands, resultsDirectory: results) { command in
            ControlResult(id: command.id, accepted: true, message: "ok")
        }
        watcher.start()
        defer { watcher.stop() }

        try Data("not json".utf8).write(to: commands.appendingPathComponent("junk.json"))
        // A valid command after it must still be processed.
        try drop(ControlCommand(id: "c2", issuedAt: now(), kind: "stop_recording"), into: commands)

        let result = try await waitForResult("c2", in: results)
        XCTAssertEqual(result?.accepted, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: commands.appendingPathComponent("junk.json").path))
    }

    func testInitialSweepProcessesPreexistingCommands() async throws {
        let (commands, results) = tempDirs()
        // Command already on disk before start() is called.
        try drop(ControlCommand(id: "pre", issuedAt: now(), kind: "stop_recording"), into: commands)

        let watcher = CommandWatcher(directory: commands, resultsDirectory: results) { command in
            ControlResult(id: command.id, accepted: true, message: "swept")
        }
        watcher.start()
        defer { watcher.stop() }

        let result = try await waitForResult("pre", in: results)
        XCTAssertEqual(result?.message, "swept")
    }
}
