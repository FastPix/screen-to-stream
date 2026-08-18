import AppKit
import SwiftUI

struct LibraryRow: View {
    let entry: HistoryEntry
    @ObservedObject var appState: AppState

    @State private var confirmingRemoteDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title ?? entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    badge
                    if let seconds = entry.durationSec {
                        Text(duration(seconds)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                actions
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .confirmationDialog("Delete this recording from FastPix? This is permanent and breaks the shared link.",
                            isPresented: $confirmingRemoteDelete, titleVisibility: .visible) {
            Button("Delete from FastPix", role: .destructive) { appState.deleteFromFastPix(entry) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var thumbnail: some View {
        if let path = entry.thumbnailPath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let remote = remoteThumbnailURL {
            AsyncImage(url: remote) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                placeholderThumb
            }
            .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            placeholderThumb
        }
    }

    private var placeholderThumb: some View {
        RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.15))
            .frame(width: 96, height: 54)
            .overlay(Image(systemName: "film").foregroundStyle(.secondary))
    }

    @ViewBuilder
    private var badge: some View {
        switch entry.statusValue {
        case .local:      label("Local only", .secondary)
        case .uploading:  label("Uploading", .blue)
        case .processing: label("Processing", .blue)
        case .ready:      label("Uploaded", .green)
        case .failed:     label("Failed", .orange)
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private var actions: some View {
        let isActive = appState.currentUploadId == entry.id

        if isActive, let coordinator = appState.uploadCoordinator {
            InlineUploadProgress(coordinator: coordinator, onCancel: { appState.cancelUpload() })
        } else {
            switch entry.statusValue {
            case .local:
                row {
                    Button("Upload") { appState.uploadEntry(entry) }
                    overflow { Button("Remove", role: .destructive) { appState.removeFromLibrary(entry) } }
                }
            case .uploading, .processing:
                Text("Interrupted — reopen to resume").font(.caption).foregroundStyle(.secondary)
            case .ready:
                row {
                    Button("Copy Link") { appState.copyLink(entry) }
                    Button("Open") {
                        if let url = entry.playbackURL.flatMap(URL.init) { NSWorkspace.shared.open(url) }
                    }
                    overflow {
                        Button("Remove") { appState.removeFromLibrary(entry) }
                        Button("Delete from FastPix", role: .destructive) { confirmingRemoteDelete = true }
                    }
                }
            case .failed:
                row {
                    Button("Retry") { appState.uploadEntry(entry) }
                    overflow { Button("Remove", role: .destructive) { appState.removeFromLibrary(entry) } }
                }
            }
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }.buttonStyle(.link).font(.caption).padding(.top, 2)
    }

    /// Secondary/destructive actions live behind a "⋯" menu so rows never overflow.
    private func overflow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private var remoteThumbnailURL: URL? {
        entry.playbackId.flatMap { URL(string: "https://images.fastpix.com/\($0)/thumbnail.png") }
    }

    private func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Live progress for the in-flight row; observes the coordinator directly.
private struct InlineUploadProgress: View {
    @ObservedObject var coordinator: UploadCoordinator
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch coordinator.phase {
            case .transferring(let fraction):
                ProgressView(value: fraction).frame(width: 120)
                Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit())
            case .processing:
                ProgressView().controlSize(.small)
                Text(coordinator.liveStatus ?? "Processing").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1)
            default:
                ProgressView().controlSize(.small)
                Text("Preparing…").font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel, action: onCancel).buttonStyle(.link).font(.caption)
        }
        .padding(.top, 2)
    }
}
