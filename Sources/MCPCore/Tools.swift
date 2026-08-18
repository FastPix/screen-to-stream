import Foundation

enum Tools {
    /// `tools/list` payload.
    static var definitions: JSONValue {
        .object(["tools": .array([
            .object([
                "name": .string("list_recordings"),
                "description": .string("List the user's screen recordings, newest first. Optional filters: query (matches title/tags), tag, from/to (ISO-8601 dates), limit."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "tag": .object(["type": .string("string")]),
                        "from": .object(["type": .string("string")]),
                        "to": .object(["type": .string("string")]),
                        "limit": .object(["type": .string("number")]),
                    ]),
                ]),
            ]),
            .object([
                "name": .string("get_recording"),
                "description": .string("Get one recording's full details by id: playback URL, HLS URL, summary, chapters, tags, status, thumbnail."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object(["id": .object(["type": .string("string")])]),
                    "required": .array([.string("id")]),
                ]),
            ]),
            .object([
                "name": .string("start_recording"),
                "description": .string("Start a screen recording. Requires the user to have enabled AI-agent control in ScreenToStream Settings. Shows a countdown and stop pill like a manual recording."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object(["type": .string("string"), "description": .string("\"display\" (default) or \"window\"")]),
                        "window": .object(["type": .string("string"), "description": .string("window title/app to match when source is \"window\"")]),
                        "display": .object(["type": .string("number"), "description": .string("which display to record, 1-based (1 = main, default)")]),
                        "resolution": .object(["type": .string("string"), "description": .string("\"1080p\" (default) or \"2160p\"/\"4k\"")]),
                        "camera": .object(["type": .string("boolean"), "description": .string("camera PiP, default false")]),
                        "camera_position": .object(["type": .string("string"), "description": .string("bottom-right (default) | bottom-left | top-right | top-left | center | left | right | top | bottom")]),
                        "camera_size": .object(["type": .string("string"), "description": .string("small | medium (default) | large")]),
                        "microphone": .object(["type": .string("boolean"), "description": .string("default true")]),
                        "system_audio": .object(["type": .string("boolean"), "description": .string("default true")]),
                    ]),
                ]),
            ]),
            .object([
                "name": .string("stop_recording"),
                "description": .string("Stop the current recording. upload=false (default) saves it to the library; upload=true uploads and returns the play.fastpix.com link."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object(["upload": .object(["type": .string("boolean")])]),
                ]),
            ]),
            .object([
                "name": .string("get_recording_status"),
                "description": .string("Current recorder state: idle, countdown, recording, uploading, or disabled."),
                "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
            ]),
        ])])
    }

    // MARK: - Action tools (control channel)

    static func startRecording(_ args: JSONValue?, control: ControlClient) async -> JSONValue {
        var display: Int?
        if case .number(let n)? = args?["display"] { display = Int(n) }

        let command = ControlCommand(
            id: UUID().uuidString, issuedAt: Date().timeIntervalSince1970, kind: "start_recording",
            source: args?["source"]?.stringValue, window: args?["window"]?.stringValue,
            display: display,
            resolution: args?["resolution"]?.stringValue, camera: args?["camera"]?.boolValue,
            cameraPosition: args?["camera_position"]?.stringValue,
            cameraSize: args?["camera_size"]?.stringValue,
            microphone: args?["microphone"]?.boolValue, systemAudio: args?["system_audio"]?.boolValue)
        let result = await control.send(command, timeout: 60)
        return resultContent(result)
    }

    static func stopRecording(_ args: JSONValue?, control: ControlClient) async -> JSONValue {
        let upload = args?["upload"]?.boolValue ?? false
        let command = ControlCommand(id: UUID().uuidString, issuedAt: Date().timeIntervalSince1970,
                                     kind: "stop_recording", upload: upload)
        let result = await control.send(command, timeout: upload ? 900 : 60)
        return resultContent(result)
    }

    static func recordingStatus(control: ControlClient) -> JSONValue {
        let state = control.isEnabled ? (control.readState()?.state ?? "idle") : "disabled"
        return textContent(#"{"state":"\#(state)"}"#)
    }

    private static func resultContent(_ result: ControlResult) -> JSONValue {
        var fields: [String: JSONValue] = [
            "accepted": .bool(result.accepted),
            "message": .string(result.message),
        ]
        if let entryId = result.entryId { fields["entryId"] = .string(entryId) }
        if let url = result.playbackURL { fields["playbackURL"] = .string(url) }
        return textContent(encode(.object(fields)), isError: !result.accepted)
    }

    static func listRecordings(_ args: JSONValue?, from recordings: [Recording]) -> JSONValue {
        var results = recordings

        if let query = args?["query"]?.stringValue?.lowercased(), !query.isEmpty {
            results = results.filter { recording in
                (recording.title?.lowercased().contains(query) ?? false)
                    || recording.tags.contains { $0.lowercased().contains(query) }
            }
        }
        if let tag = args?["tag"]?.stringValue?.lowercased(), !tag.isEmpty {
            results = results.filter { $0.tags.contains { $0.lowercased() == tag } }
        }
        if let from = args?["from"]?.stringValue.flatMap(Self.date) {
            results = results.filter { $0.createdAt >= from }
        }
        if let to = args?["to"]?.stringValue.flatMap(Self.date) {
            results = results.filter { $0.createdAt <= to }
        }
        if case .number(let limit)? = args?["limit"] {
            results = Array(results.prefix(Int(limit)))
        }

        let summaries = results.map { recording in
            JSONValue.object([
                "id": .string(recording.id),
                "title": .string(recording.title ?? recording.createdAt.ISO8601Format()),
                "created": .string(recording.createdAt.ISO8601Format()),
                "durationSec": recording.durationSec.map(JSONValue.number) ?? .null,
                "tags": .array(recording.tags.map(JSONValue.string)),
                "status": .string(recording.status),
            ])
        }
        return textContent(encode(.array(summaries)))
    }

    static func getRecording(_ args: JSONValue?, from recordings: [Recording]) -> JSONValue {
        guard let id = args?["id"]?.stringValue else {
            return textContent("{\"error\":\"missing 'id'\"}", isError: true)
        }
        guard let recording = recordings.first(where: { $0.id == id }) else {
            return textContent("{\"error\":\"no recording with id \(id)\"}", isError: true)
        }

        let chapters = recording.chapters.map { chapter in
            JSONValue.object(["start": .number(chapter.start), "end": .number(chapter.end),
                              "title": .string(chapter.title)])
        }
        let detail = JSONValue.object([
            "id": .string(recording.id),
            "title": .string(recording.title ?? recording.createdAt.ISO8601Format()),
            "created": .string(recording.createdAt.ISO8601Format()),
            "durationSec": recording.durationSec.map(JSONValue.number) ?? .null,
            "status": .string(recording.status),
            "tags": .array(recording.tags.map(JSONValue.string)),
            "playbackURL": .string(recording.playbackURL),
            "hlsURL": .string(recording.hlsURL),
            "summary": .string(recording.summary),
            "chapters": .array(chapters),
            "transcriptAvailable": .bool(false),
            "thumbnailPath": .string(recording.thumbnailPath),
        ])
        return textContent(encode(detail))
    }

    // MARK: - Helpers

    /// MCP tool result: `{content: [{type:"text", text}], isError?}`.
    private static func textContent(_ text: String, isError: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = [
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]
        if isError { object["isError"] = .bool(true) }
        return .object(object)
    }

    private static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    private static func date(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
            ?? ISO8601DateFormatter().date(from: string + "T00:00:00Z")
    }
}
