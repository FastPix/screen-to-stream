import AppKit
import SwiftUI

struct DoneView: View {
    @ObservedObject var appState: AppState
    let playbackURL: String

    @State private var copied = true   // coordinator already put it on the clipboard

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Your link is ready")
                .font(.headline)

            if let thumbnail = thumbnailURL {
                AsyncImage(url: thumbnail) { image in
                    image.resizable().aspectRatio(16 / 9, contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.15))
                        .aspectRatio(16 / 9, contentMode: .fit)
                }
                .frame(maxWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text(playbackURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(playbackURL, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        if let url = URL(string: playbackURL) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label("Open", systemImage: "safari").frame(maxWidth: .infinity)
                    }
                }
                HStack(spacing: 8) {
                    Button { appState.showLibrary() } label: {
                        Label("Library", systemImage: "rectangle.stack").frame(maxWidth: .infinity)
                    }
                    Button { appState.showSourcePicker() } label: {
                        Label("New Recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: 320)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    /// Thumbnail is served per playbackId.
    private var thumbnailURL: URL? {
        guard let id = URLComponents(string: playbackURL)?
            .queryItems?.first(where: { $0.name == "playbackId" })?.value else { return nil }
        return URL(string: "https://images.fastpix.com/\(id)/thumbnail.png")
    }
}
