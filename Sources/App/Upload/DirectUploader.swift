import Foundation

/// Single `uploadTask(fromFile:)` PUT of the prepared file to the signed URL, with progress from
/// the task delegate. No resume: a network drop restarts from byte zero.
final class DirectUploader: NSObject, Uploader {
    private let sessionConfig: URLSessionConfiguration
    private let providedSession: URLSession?

    private var task: URLSessionUploadTask?
    private var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?

    init(session: URLSession? = nil) {
        self.providedSession = session
        self.sessionConfig = .default
        super.init()
    }

    func upload(file: URL, to signedURL: URL, progress: @escaping (Double) -> Void) async throws {
        progressHandler = progress

        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"

        let session = providedSession
            ?? URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation

            let task = session.uploadTask(with: request, fromFile: file) { [weak self] data, response, error in
                // Runs only for a delegate-less (stub) session.
                self?.finish(data: data, response: response, error: error, fallbackProgress: progress)
            }
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func finish(data: Data?, response: URLResponse?, error: Error?,
                        fallbackProgress: (Double) -> Void) {
        guard let continuation else { return }
        self.continuation = nil

        if let error {
            continuation.resume(throwing: error)
            return
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            continuation.resume(throwing: FastPixAPIError(
                statusCode: status, body: String(decoding: data ?? Data(), as: UTF8.self)))
            return
        }

        fallbackProgress(1.0)
        continuation.resume()
    }
}

extension DirectUploader: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progressHandler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(data: nil, response: task.response, error: error,
               fallbackProgress: progressHandler ?? { _ in })
    }
}
