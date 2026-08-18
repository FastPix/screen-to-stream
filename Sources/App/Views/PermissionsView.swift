import SwiftUI

struct PermissionsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var permissions: PermissionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2.bold())
            Text("Screen recording is required. Camera and microphone are optional.")
                .font(.callout)
                .foregroundStyle(.secondary)

            permissionRow(
                name: "Screen Recording",
                status: permissions.screen,
                grant: { await permissions.requestScreen() },
                pane: .screenRecording
            )
            permissionRow(
                name: "Camera",
                status: permissions.camera,
                grant: { await permissions.requestCamera() },
                pane: .camera
            )
            permissionRow(
                name: "Microphone",
                status: permissions.microphone,
                grant: { await permissions.requestMicrophone() },
                pane: .microphone
            )

            Spacer()

            Button("Continue") {
                appState.permissionsSatisfied()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(permissions.screen != .granted)
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .task {
            await permissions.refresh()
        }
    }

    private func permissionRow(
        name: String,
        status: PermissionStatus,
        grant: @escaping () async -> Void,
        pane: PermissionManager.Pane
    ) -> some View {
        HStack {
            Circle()
                .fill(color(for: status))
                .frame(width: 10, height: 10)
            Text(name)
            Spacer()

            switch status {
            case .granted:
                Text("Granted")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .undetermined:
                Button("Grant") {
                    Task { await grant() }
                }
            case .denied:
                Button("Open Settings") {
                    permissions.openSystemSettings(pane)
                }
            }
        }
    }

    private func color(for status: PermissionStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .undetermined: return .secondary.opacity(0.4)
        }
    }
}
