import Foundation

enum LogScrubber {
    private static let rules: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"(?i)(authorization:\s*)\S+(\s+\S+)?"#), "$1<redacted>"),
        (try! NSRegularExpression(pattern: #"(?i)\b(token(?:id)?|secret|password|apikey|authorization)(\s*[=:]\s*)\S+"#), "$1$2<redacted>"),
        // Long opaque base64/hex runs; hyphenated filenames and UUIDs stay readable.
        (try! NSRegularExpression(pattern: #"\b[A-Za-z0-9]{24,}\b"#), "<redacted>"),
    ]

    static func scrub(_ line: String) -> String {
        var result = line

        for (regex, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }

        return result
    }
}

final class AppLogger {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "com.fastpix.screen-to-stream.logger")
    private let formatter = ISO8601DateFormatter()
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ScreenToStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("app.log")
    }

    func log(_ subsystem: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(subsystem)] \(LogScrubber.scrub(message))\n"

        queue.async { [fileURL] in
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
