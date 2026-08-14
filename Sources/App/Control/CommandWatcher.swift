import Foundation

/// Watches the control `commands/` directory, runs each dropped command through a handler, and
/// writes a result file the MCP client polls for. Created/torn down with the Settings control toggle.
@MainActor
final class CommandWatcher {
    private let directory: URL
    private let resultsDirectory: URL
    private let handler: (ControlCommand) async -> ControlResult

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var inFlight: Set<String> = []

    init(directory: URL = ControlDirectory().commands,
         resultsDirectory: URL = ControlDirectory().results,
         handler: @escaping (ControlCommand) async -> ControlResult) {
        self.directory = directory
        self.resultsDirectory = resultsDirectory
        self.handler = handler
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)

        descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write], queue: .main)
            source.setEventHandler { [weak self] in self?.sweep() }
            source.setCancelHandler { [weak self] in
                guard let self, self.descriptor >= 0 else { return }
                close(self.descriptor)
                self.descriptor = -1
            }
            source.resume()
            self.source = source
        } else {
            AppLogger.shared.log("MCP", "command watcher could not open \(directory.path)")
        }

        sweep()   // catch anything already present
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func sweep() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else { continue }

            guard let command = try? JSONDecoder().decode(ControlCommand.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            guard !inFlight.contains(command.id) else { continue }
            inFlight.insert(command.id)
            try? FileManager.default.removeItem(at: file)       // consume before running

            if command.isExpired() {
                write(ControlResult(id: command.id, accepted: false, message: "command expired"))
                inFlight.remove(command.id)
                continue
            }

            Task { [handler] in
                let result = await handler(command)
                self.write(result)
                self.inFlight.remove(command.id)
            }
        }
    }

    private func write(_ result: ControlResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        let url = resultsDirectory.appendingPathComponent("\(result.id).json")
        try? data.write(to: url, options: .atomic)
    }
}
