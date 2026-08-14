import Foundation

/// Routes JSON-RPC methods to the tools. Read-only tools read history fresh per call; action
/// tools go through the control channel.
public struct Server {
    public static let protocolVersion = "2024-11-05"

    let loadRecordings: () -> [Recording]
    let control: ControlClient

    public init(loadRecordings: @escaping () -> [Recording] = { HistoryReader.load() },
                control: ControlClient = ControlClient()) {
        self.loadRecordings = loadRecordings
        self.control = control
    }

    /// Convenience for tests that want a fixed snapshot.
    public init(recordings: [Recording], control: ControlClient = ControlClient()) {
        self.loadRecordings = { recordings }
        self.control = control
    }

    public func handle(_ request: RPCRequest) async -> RPCResponse? {
        switch request.method {
        case "initialize":
            return .success(id: request.id, .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("screen-to-stream"),
                    "version": .string("0.1.0"),
                ]),
            ]))

        case "notifications/initialized", "initialized":
            return nil   // notification: no response

        case "tools/list":
            return .success(id: request.id, Tools.definitions)

        case "tools/call":
            return await handleToolCall(request)

        case "ping":
            return .success(id: request.id, .object([:]))

        default:
            guard request.id != nil else { return nil }   // unknown notification → ignore
            return .failure(id: request.id, code: -32601, "Method not found: \(request.method)")
        }
    }

    private func handleToolCall(_ request: RPCRequest) async -> RPCResponse {
        let name = request.params?["name"]?.stringValue
        let arguments = request.params?["arguments"]

        switch name {
        case "list_recordings":
            return .success(id: request.id, Tools.listRecordings(arguments, from: loadRecordings()))
        case "get_recording":
            return .success(id: request.id, Tools.getRecording(arguments, from: loadRecordings()))
        case "start_recording":
            return .success(id: request.id, await Tools.startRecording(arguments, control: control))
        case "stop_recording":
            return .success(id: request.id, await Tools.stopRecording(arguments, control: control))
        case "get_recording_status":
            return .success(id: request.id, Tools.recordingStatus(control: control))
        default:
            return .failure(id: request.id, code: -32602, "Unknown tool: \(name ?? "nil")")
        }
    }
}
