import SwiftUI

struct UploadingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var coordinator: UploadCoordinator

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            switch coordinator.phase {
            case .idle, .preparing:
                ProgressView()
                Text("Preparing…").foregroundStyle(.secondary)

            case .transferring(let fraction):
                // Real byte-count progress.
                ProgressView(value: fraction)
                    .frame(maxWidth: 260)
                Text("Uploading \(Int(fraction * 100))%")
                    .font(.headline.monospacedDigit())
                Button("Cancel", role: .cancel) { appState.cancelUpload() }

            case .processing:
                // No honest percentage for processing — indeterminate bar plus the live stage FastPix reports.
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text(processingLabel)
                    .font(.headline)
                Text("FastPix is working on it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { appState.cancelUpload() }

            case .ready:
                ProgressView()   // AppState transitions to .done immediately

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Retry") { appState.retryUpload() }
                        .keyboardShortcut(.defaultAction)
                    Button("Settings") { appState.showSettings() }
                    Button("Cancel", role: .cancel) { appState.cancelUpload() }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    /// The live FastPix stage (Downloading, Validating, Processing, …), title-cased.
    private var processingLabel: String {
        guard let status = coordinator.liveStatus, !status.isEmpty else { return "Processing" }
        return status
    }
}
