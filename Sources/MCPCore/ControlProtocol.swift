import Foundation

/// Server-side mirror of the app's control-channel types (the two modules don't link each other).
/// Property names must stay IDENTICAL to the app's `ControlProtocol` — the JSON is a wire contract.
public struct ControlCommand: Codable, Equatable {
    public var v: Int = 1
    public var id: String
    public var issuedAt: Double            // Unix epoch seconds
    public var kind: String
    public var source: String?
    public var window: String?
    public var display: Int?
    public var resolution: String?
    public var camera: Bool?
    public var cameraPosition: String?
    public var cameraSize: String?
    public var microphone: Bool?
    public var systemAudio: Bool?
    public var upload: Bool?

    public init(id: String, issuedAt: Double, kind: String, source: String? = nil,
                window: String? = nil, display: Int? = nil, resolution: String? = nil,
                camera: Bool? = nil, cameraPosition: String? = nil, cameraSize: String? = nil,
                microphone: Bool? = nil, systemAudio: Bool? = nil, upload: Bool? = nil) {
        self.id = id; self.issuedAt = issuedAt; self.kind = kind; self.source = source
        self.window = window; self.display = display; self.resolution = resolution
        self.camera = camera; self.cameraPosition = cameraPosition; self.cameraSize = cameraSize
        self.microphone = microphone; self.systemAudio = systemAudio; self.upload = upload
    }
}

public struct ControlResult: Codable, Equatable {
    public var id: String
    public var accepted: Bool
    public var message: String
    public var entryId: String?
    public var playbackURL: String?

    public init(id: String, accepted: Bool, message: String,
                entryId: String? = nil, playbackURL: String? = nil) {
        self.id = id; self.accepted = accepted; self.message = message
        self.entryId = entryId; self.playbackURL = playbackURL
    }
}

public struct ControlState: Codable, Equatable {
    public var state: String
    public var elapsedSec: Double?
    public var entryId: String?

    public init(state: String, elapsedSec: Double? = nil, entryId: String? = nil) {
        self.state = state; self.elapsedSec = elapsedSec; self.entryId = entryId
    }
}

public struct ControlDirectory {
    public let root: URL

    public init(root: URL = ControlDirectory.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fastpix.screen-to-stream/control", isDirectory: true)
    }

    public var commands: URL { root.appendingPathComponent("commands", isDirectory: true) }
    public var results: URL { root.appendingPathComponent("results", isDirectory: true) }
    public var enabledMarker: URL { root.appendingPathComponent("enabled") }
    public var stateFile: URL { root.appendingPathComponent("state.json") }
}
