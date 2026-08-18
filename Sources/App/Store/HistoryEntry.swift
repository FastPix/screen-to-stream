import Foundation

struct HistoryEntry: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var createdAt: Date
    var mediaId: String?
    var playbackId: String?
    var playbackURL: String?
    var hlsURL: String?
    var durationSec: Double?
    var localFileURL: String?
    var status: String            // see Status
    var title: String?
    var summary: String?
    var tags: [String]
    var chapters: [Chapter]
    var ai: AIStatus
    var thumbnailPath: String? = nil

    struct Chapter: Codable, Equatable {
        var start: Double
        var end: Double
        var title: String
    }

    struct AIStatus: Codable, Equatable {
        var summary: String       // pending | ready | unavailable | failed
        var chapters: String
        var transcript: String
    }
}

extension HistoryEntry {
    enum Status: String {
        case local        // recorded, not uploaded
        case uploading
        case processing
        case ready
        case failed
    }

    var statusValue: Status { Status(rawValue: status) ?? .local }
    var isUploaded: Bool { statusValue == .ready }

    var localFileExists: Bool {
        guard let path = localFileURL else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// `id` stays constant through upload.
    static func local(id: String, fileURL: URL, durationSec: Double?, thumbnailPath: String?) -> HistoryEntry {
        HistoryEntry(
            id: id, kind: "recording", createdAt: Date(),
            mediaId: nil, playbackId: nil, playbackURL: nil, hlsURL: nil,
            durationSec: durationSec, localFileURL: fileURL.path,
            status: Status.local.rawValue, title: nil, summary: nil, tags: [],
            chapters: [], ai: .init(summary: "pending", chapters: "pending", transcript: "pending"),
            thumbnailPath: thumbnailPath)
    }
}
