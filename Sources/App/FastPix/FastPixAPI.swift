import Foundation

struct FastPixAPIError: Error, Equatable, LocalizedError {
    let statusCode: Int
    let body: String

    /// FastPix returns 422 (not just 404) for an id that no longer resolves.
    var isNotFound: Bool {
        statusCode == 404 || statusCode == 422
            || body.localizedCaseInsensitiveContains("not found")
    }

    var errorDescription: String? {
        if let message = Self.message(from: body) { return message }
        return "FastPix returned HTTP \(statusCode)."
    }

    private static func message(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return json["message"] as? String
    }
}

enum FastPixAPIClientError: Error {
    case unauthenticated
}

/// URLSession core for all FastPix calls. Basic auth, `{data:…}`-envelope decoding, and a single
/// retry for GETs on 5xx/timeout — never for POSTs, which aren't idempotent.
final class FastPixAPI {
    static let baseURL = URL(string: "https://api.fastpix.com")!

    private let session: URLSession
    private let authProvider: () -> String?

    init(session: URLSession = .shared,
         authProvider: @escaping () -> String? = { CredentialStore.basicAuthHeader }) {
        self.session = session
        self.authProvider = authProvider
    }

    func authorized(_ request: inout URLRequest) throws {
        guard let header = authProvider() else { throw FastPixAPIClientError.unauthenticated }
        request.setValue(header, forHTTPHeaderField: "Authorization")
    }

    func send<T: Decodable>(_ request: URLRequest, decode: T.Type) async throws -> T {
        var request = request
        try authorized(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let isRetryableMethod = (request.httpMethod ?? "GET") == "GET"
        let data = try await bytes(for: request, retryOn5xx: isRetryableMethod)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func bytes(for request: URLRequest, retryOn5xx: Bool) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if (200...299).contains(status) { return data }

            if retryOn5xx, (500...599).contains(status) {
                return try await single(request)
            }
            throw FastPixAPIError(statusCode: status, body: String(decoding: data, as: UTF8.self))
        } catch let error as FastPixAPIError {
            throw error
        } catch {
            if retryOn5xx { return try await single(request) }
            throw error
        }
    }

    private func single(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw FastPixAPIError(statusCode: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
