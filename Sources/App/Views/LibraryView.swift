import SwiftUI

struct LibraryView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var history: HistoryStore

    @State private var search = ""

    init(appState: AppState) {
        self.appState = appState
        self.history = appState.history
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { appState.showSourcePicker() } label: { Image(systemName: "chevron.left") }
                Text("Library").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            TextField("Search recordings", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            if let error = appState.libraryError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }

            if filtered.isEmpty {
                Spacer()
                Text(history.entries.isEmpty ? "No recordings yet" : "No matches")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { entry in
                            LibraryRow(entry: entry, appState: appState)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    private var filtered: [HistoryEntry] {
        guard !search.isEmpty else { return history.entries }
        return history.entries.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(search)
                || $0.createdAt.formatted().localizedCaseInsensitiveContains(search)
        }
    }
}
