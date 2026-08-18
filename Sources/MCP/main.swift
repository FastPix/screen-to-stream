import Foundation
import MCPCore

// MCP server over history.json + the recording control channel. Newline-delimited JSON-RPC 2.0
// on stdin/stdout. History is read fresh per call so new recordings appear immediately.
let server = Server(loadRecordings: { HistoryReader.load() }, control: ControlClient())

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
var buffer = Data()

while true {
    while let request = Framing.decode(from: &buffer) {
        guard let response = await server.handle(request) else { continue }   // notifications: no reply
        output.write(Framing.encode(response))
    }

    let chunk = input.availableData
    if chunk.isEmpty { break }   // stdin closed
    buffer.append(chunk)
}
