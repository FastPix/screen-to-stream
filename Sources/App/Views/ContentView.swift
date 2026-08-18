import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var permissions: PermissionManager

    var body: some View {
        switch appState.screen {
        case .permissions:
            PermissionsView(appState: appState, permissions: permissions)
        case .sourcePicker:
            SourcePickerView(appState: appState, catalog: appState.catalog)
        case .countdown(let count):
            CountdownView(count: count, onCancel: appState.cancelCountdown)
        case .recording:
            RecordingView(elapsed: appState.elapsed, onStop: appState.stopRecording)
        case .review(let url):
            ReviewView(fileURL: url, appState: appState)
        case .library:
            LibraryView(appState: appState)
        case .settings:
            SettingsView(appState: appState, preferences: appState.preferences)
        case .uploading:
            if let coordinator = appState.uploadCoordinator {
                UploadingView(appState: appState, coordinator: coordinator)
            }
        case .done(let playbackURL):
            DoneView(appState: appState, playbackURL: playbackURL)
        case .error(let message):
            RecordingErrorView(message: message, onDismiss: appState.showSourcePicker)
        }
    }
}
