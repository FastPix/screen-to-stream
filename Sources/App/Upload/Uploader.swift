import Foundation

/// Swap seam for a future FastPix Upload SDK. No pause/resume, so DirectUploader can satisfy it.
protocol Uploader: AnyObject {
    func upload(file: URL, to signedURL: URL, progress: @escaping (Double) -> Void) async throws
    func cancel()
}
