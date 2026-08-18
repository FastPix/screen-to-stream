import Foundation

/// Server-side half of the control channel: writes a command file, polls for the matching result
/// file, and reads `state.json`. Reports honestly when the app isn't running rather than hanging.
public struct ControlClient {
    let directory: ControlDirectory
    let launcher: () -> Void
    let clock: () -> Double

    public init(root: URL = ControlDirectory.defaultRoot,
                launcher: @escaping () -> Void = ControlClient.openApp,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.directory = ControlDirectory(root: root)
        self.launcher = launcher
        self.clock = clock
    }

    /// True only while the app has control enabled (it maintains the marker file).
    public var isEnabled: Bool {
        FileManager.default.fileExists(atPath: directory.enabledMarker.path)
    }

    public func readState() -> ControlState? {
        guard let data = try? Data(contentsOf: directory.stateFile) else { return nil }
        return try? JSONDecoder().decode(ControlState.self, from: data)
    }

    /// Writes the command, launches the app if needed, and polls the result up to `timeout`.
    public func send(_ command: ControlCommand, timeout: Double) async -> ControlResult {
        guard isEnabled else {
            return ControlResult(id: command.id, accepted: false,
                message: "Recording control is disabled. Turn on \"Allow AI agents to control recording\" in ScreenToStream → Settings.")
        }

        do {
            try FileManager.default.createDirectory(at: directory.commands, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory.results, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(command)
            try data.write(to: directory.commands.appendingPathComponent("\(command.id).json"))
        } catch {
            return ControlResult(id: command.id, accepted: false,
                                 message: "could not write command: \(error.localizedDescription)")
        }

        launcher()

        let resultURL = directory.results.appendingPathComponent("\(command.id).json")
        let deadline = clock() + timeout
        while clock() < deadline {
            if let data = try? Data(contentsOf: resultURL),
               let result = try? JSONDecoder().decode(ControlResult.self, from: data) {
                try? FileManager.default.removeItem(at: resultURL)
                return result
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return ControlResult(id: command.id, accepted: false,
                             message: "timed out waiting for ScreenToStream to respond")
    }

    /// `open -b` activates the app if running, launches it otherwise — harmless either way.
    public static func openApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", "com.fastpix.screen-to-stream"]
        try? process.run()
    }
}
