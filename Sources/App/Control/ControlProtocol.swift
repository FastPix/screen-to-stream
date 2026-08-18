import Foundation

/// Command written by an MCP client into the control directory. Key names ARE the cross-codebase
/// contract — MCPCore has a byte-identical mirror; keep property names in sync. `issuedAt` is a
/// plain Double (epoch seconds) so the two codebases can't drift on a Codable date strategy.
struct ControlCommand: Codable, Equatable {
    var v: Int = 1
    var id: String
    var issuedAt: Double            // Unix epoch seconds
    var kind: String                // "start_recording" | "stop_recording"
    var source: String?             // "display" | "window"
    var window: String?
    var display: Int?               // 1-based display index (1 = main)
    var resolution: String?         // "1080p" | "2160p"
    var camera: Bool?
    var cameraPosition: String?     // bottom-right | bottom-left | top-right | top-left | center | left | right | top | bottom
    var cameraSize: String?         // small | medium | large
    var microphone: Bool?
    var systemAudio: Bool?
    var upload: Bool?

    /// Guards against a stale command file firing on launch.
    func isExpired(now: Double = Date().timeIntervalSince1970, ttl: Double = 10) -> Bool {
        now - issuedAt > ttl
    }
}

struct ControlResult: Codable, Equatable {
    var id: String
    var accepted: Bool
    var message: String
    var entryId: String?
    var playbackURL: String?
}

struct ControlState: Codable, Equatable {
    var state: String               // idle | countdown | recording | uploading
    var elapsedSec: Double?
    var entryId: String?
}

struct ControlDirectory {
    let root: URL

    init(root: URL = ControlDirectory.defaultRoot) {
        self.root = root
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fastpix.screen-to-stream/control", isDirectory: true)
    }

    var commands: URL { root.appendingPathComponent("commands", isDirectory: true) }
    var results: URL { root.appendingPathComponent("results", isDirectory: true) }
    var enabledMarker: URL { root.appendingPathComponent("enabled") }
    var stateFile: URL { root.appendingPathComponent("state.json") }

    /// Locks `control/` to the owner (0700) — filesystem permissions are the channel's only access control.
    func ensureLayout() throws {
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}
