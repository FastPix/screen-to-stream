import Foundation

/// AI/subtitle features to request; each opt-in. Unsupported flags 400 the upload, so only enabled
/// ones are ever sent.
struct AIFeatures: Equatable {
    var generateSubtitles: Bool = true    // create-body flag
    var generateChapters: Bool = false    // post-Ready PATCH; needs an AI-enabled account
}

extension FastPixAPI {
    /// Fire-and-forget AI enrichment: never throws, never blocks the link. A "not enabled" 400 is
    /// swallowed and logged.
    func triggerEnrichment(mediaId: String, features: AIFeatures) async {
        guard features.generateChapters else { return }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/on-demand/\(mediaId)/chapters"))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["chapters": true])

        do {
            _ = try await send(request, decode: EmptyAIResponse.self)
            AppLogger.shared.log("AI", "chapters requested for \(mediaId)")
        } catch {
            AppLogger.shared.log("AI", "chapters trigger skipped (\(error.localizedDescription))")
        }
    }

    /// Irreversible remote delete. Throws on non-2xx.
    func deleteMedia(id: String) async throws {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/on-demand/\(id)"))
        request.httpMethod = "DELETE"
        _ = try await send(request, decode: EmptyAIResponse.self)
        AppLogger.shared.log("FastPix", "deleted media \(id)")
    }
}

private struct EmptyAIResponse: Decodable {}
