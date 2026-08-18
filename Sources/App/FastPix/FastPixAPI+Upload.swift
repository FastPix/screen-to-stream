import Foundation

extension FastPixAPI {
    /// Creates a direct upload. The returned uploadId IS the mediaId — poll `media(id:)` with it.
    func createUpload(appVersion: String, maxResolution: String,
                      features: AIFeatures = AIFeatures()) async throws -> CreateUploadResponse {
        var pushMediaSettings: [String: Any] = [
            "accessPolicy": "public",
            "maxResolution": maxResolution,
            "normalizeAudio": true,
            "metadata": ["source": "screen-to-stream", "app_version": appVersion],
        ]
        // Unsupported AI flags 400 the upload; send only when enabled.
        if features.generateSubtitles {
            pushMediaSettings["generateSubtitles"] = true
        }

        let body: [String: Any] = ["corsOrigin": "*", "pushMediaSettings": pushMediaSettings]

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/on-demand/upload"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await send(request, decode: CreateUploadResponse.self)
    }

    func media(id: String) async throws -> MediaResponse {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/on-demand/\(id)"))
        request.httpMethod = "GET"
        return try await send(request, decode: MediaResponse.self)
    }

    /// Authenticated GET for Settings "Test connection"; throws on 401.
    func testConnection() async throws {
        var request = URLRequest(url: URL(string: "https://api.fastpix.com/v1/on-demand?limit=1")!)
        request.httpMethod = "GET"
        _ = try await send(request, decode: EmptyResponse.self)
    }
}

private struct EmptyResponse: Decodable {}
