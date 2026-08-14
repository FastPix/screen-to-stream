import Foundation

/// Versioned JSON library in Application Support. The JSON doubles as the MCP data source.
@MainActor
final class HistoryStore: ObservableObject {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var entries: [HistoryEntry]
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fastpix.screen-to-stream", isDirectory: true)
    }

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL

    init(directory: URL = HistoryStore.defaultDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.json")
        load()
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    func update(_ entry: HistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            add(entry)
            return
        }
        entries[index] = entry
        save()
    }

    func entry(id: String) -> HistoryEntry? {
        entries.first { $0.id == id }
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// No-op if the id is unknown.
    func patch(id: String, _ mutate: (inout HistoryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[index])
        save()
    }

    func pendingProcessing() -> [HistoryEntry] {
        entries.filter { $0.status == "processing" }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            entries = envelope.entries
        } else {
            AppLogger.shared.log("Upload", "history.json unreadable — starting empty")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(Envelope(schemaVersion: 1, entries: entries))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.shared.log("Upload", "history save failed: \(error.localizedDescription)")
        }
    }
}
