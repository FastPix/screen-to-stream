import Foundation

/// Registers the bundled read-only MCP server with Claude Code. Shells out to the `claude` CLI;
/// degrades to a copyable command when the CLI isn't on PATH.
enum MCPSetup {
    static let serverName = "screen-to-stream"

    static var bundledBinaryURL: URL? {
        let candidate = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mcp-server")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    static func installCommand() -> String {
        let path = bundledBinaryURL?.path ?? "<path-to>/mcp-server"
        return "claude mcp add --transport stdio \(serverName) \"\(path)\""
    }

    static func isInstalled() -> Bool {
        guard let output = try? run(["mcp", "list"]) else { return false }
        return output.contains(serverName)
    }

    static func install() throws {
        guard let path = bundledBinaryURL?.path else { throw MCPError.binaryMissing }
        _ = try run(["mcp", "add", "--transport", "stdio", serverName, path])
    }

    static func remove() throws {
        _ = try run(["mcp", "remove", serverName])
    }

    // MARK: - CLI

    enum MCPError: Error, LocalizedError {
        case binaryMissing
        case cliNotFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing: return "Bundled mcp-server not found — rebuild with ./run.sh."
            case .cliNotFound: return "The `claude` CLI isn't on PATH. Copy the setup command and run it in your terminal."
            case .failed(let message): return message
            }
        }
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        guard let claude = claudePath() else { throw MCPError.cliNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw MCPError.failed(stderr.isEmpty ? stdout : stderr)
        }
        return stdout
    }

    /// GUI apps don't inherit the shell PATH; probe the usual install locations.
    private static func claudePath() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
