import Foundation

/// Canned HTTP responses for a URLSession, plus a record of every request sent.
/// Supports a per-URL queue so a test can script "500 then 200".
final class StubURLProtocol: URLProtocol {
    struct Response { let status: Int; let body: Data }

    private static let lock = NSLock()
    private static var queues: [String: [Response]] = [:]
    private static var requests: [URLRequest] = []
    private static var bodies: [String: Data] = [:]

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queues = [:]; requests = []; bodies = [:]
    }

    /// Enqueue one response for a URL path (matched by absolute string prefix).
    static func enqueue(_ url: String, status: Int, json: String) {
        lock.lock(); defer { lock.unlock() }
        queues[url, default: []].append(Response(status: status, body: Data(json.utf8)))
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    /// Captured HTTP body for a request (URLProtocol strips httpBodyStream otherwise).
    static func recordedBody(for url: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return bodies[url]
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""

        Self.lock.lock()
        Self.requests.append(request)
        if let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.drain) {
            Self.bodies[key] = body
        }
        let matchKey = Self.queues.keys.first { key.hasPrefix($0) } ?? key
        let response = Self.queues[matchKey]?.isEmpty == false ? Self.queues[matchKey]!.removeFirst() : nil
        Self.lock.unlock()

        let resolved = response ?? Response(status: 404, body: Data("{}".utf8))
        let http = HTTPURLResponse(url: request.url!, statusCode: resolved.status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resolved.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
