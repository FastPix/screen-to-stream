import Foundation

/// MCP-side mirror of the app's HistoryEntry JSON, kept separate so this binary never links
/// AppKit/AVFoundation. Decodes the app's entries, ignoring unused fields.
public struct Recording: Codable {
    let id: String
    let kind: String
    let createdAt: Date
    let title: String?
    let durationSec: Double?
    let tags: [String]
    let status: String
    let playbackURL: String?
    let hlsURL: String?
    let summary: String?
    let chapters: [Chapter]
    let thumbnailPath: String?

    struct Chapter: Codable, Equatable {
        let start: Double
        let end: Double
        let title: String
    }

    // Defaults make the decode tolerant of older/newer entries.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "recording"
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        durationSec = try? c.decodeIfPresent(Double.self, forKey: .durationSec)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        status = (try? c.decode(String.self, forKey: .status)) ?? "local"
        playbackURL = try? c.decodeIfPresent(String.self, forKey: .playbackURL)
        hlsURL = try? c.decodeIfPresent(String.self, forKey: .hlsURL)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        chapters = (try? c.decodeIfPresent([Chapter].self, forKey: .chapters)) ?? []
        thumbnailPath = try? c.decodeIfPresent(String.self, forKey: .thumbnailPath)
    }
}

public enum HistoryReader {
    /// Must match the path the app writes to.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fastpix.screen-to-stream/history.json")
    }

    private struct Envelope: Decodable { let schemaVersion: Int; let entries: [Recording] }

    /// Returns [] on a missing/unreadable file. Never throws — the server must always answer.
    public static func load(_ url: URL = HistoryReader.defaultURL) -> [Recording] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(Envelope.self, from: data))?.entries ?? []
    }
}
