import Foundation

/// Create-upload response. `data.uploadId` IS the mediaId — no separate resolution step.
struct CreateUploadResponse: Decodable {
    let signedURL: URL
    let uploadId: String

    private enum Root: String, CodingKey { case data }
    private enum Keys: String, CodingKey { case url, uploadId }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Root.self)
        let data = try root.nestedContainer(keyedBy: Keys.self, forKey: .data)
        signedURL = try data.decode(URL.self, forKey: .url)
        uploadId = try data.decode(String.self, forKey: .uploadId)
    }
}

struct MediaResponse: Decodable {
    let status: String
    let playbackIds: [PlaybackID]
    let duration: String?
    let thumbnail: String?

    struct PlaybackID: Decodable { let id: String }

    private enum Root: String, CodingKey { case data }
    private enum Keys: String, CodingKey { case status, playbackIds, duration, thumbnail }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Root.self)
        let data = try root.nestedContainer(keyedBy: Keys.self, forKey: .data)
        status = try data.decode(String.self, forKey: .status)
        playbackIds = try data.decodeIfPresent([PlaybackID].self, forKey: .playbackIds) ?? []
        duration = try data.decodeIfPresent(String.self, forKey: .duration)
        thumbnail = try data.decodeIfPresent(String.self, forKey: .thumbnail)
    }
}
