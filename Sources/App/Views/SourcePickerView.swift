import SwiftUI

struct SourcePickerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var catalog: SourceCatalog

    @State private var selectedSourceID: String?
    @State private var selectedCameraID: String?
    @State private var windowSearch = ""
    @State private var systemAudio = true
    @State private var microphone = true

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if let notice = appState.endedEarlyNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    displaysSection
                    windowsSection
                    camerasSection
                    audioSection
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button { appState.showSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")

                Button { appState.showLibrary() } label: {
                    Image(systemName: "rectangle.stack")
                }
                .help("Library")

                if !appState.hasCredentials {
                    Text("Add FastPix credentials to upload")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Start Recording", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedSource == nil)
            }
            .padding(12)
        }
        .task { await catalog.refresh() }
        .onReceive(refreshTimer) { _ in
            guard AppState.shouldAutoRefreshPicker(panelVisible: appState.panelIsVisible, screen: appState.screen) else { return }
            Task { await catalog.refresh() }
        }
        .onChange(of: appState.panelIsVisible) { _, visible in
            if visible { Task { await catalog.refresh() } }   // fresh thumbnails the moment it opens
        }
        .onChange(of: selectedSourceID) {
            appState.selectedSource = selectedSource   // so the camera overlay can follow the display
        }
    }

    private var displaysSection: some View {
        section("Displays") {
            ForEach(catalog.displays) { source in
                row(source)
            }
        }
    }

    private var windowsSection: some View {
        section("Windows") {
            TextField("Search windows", text: $windowSearch)
                .textFieldStyle(.roundedBorder)

            ForEach(filteredWindows) { source in
                row(source)
            }
        }
    }

    private var camerasSection: some View {
        section("Camera") {
            Toggle("No camera", isOn: Binding(
                get: { selectedCameraID == nil },
                set: {
                    if $0 {
                        selectedCameraID = nil
                        appState.previewCameraID = nil
                    }
                }
            ))
            .toggleStyle(.checkbox)

            ForEach(catalog.cameras) { device in
                HStack {
                    Toggle(device.name, isOn: Binding(
                        get: { selectedCameraID == device.id },
                        set: {
                            selectedCameraID = $0 ? device.id : nil
                            appState.previewCameraID = selectedCameraID
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(!device.isAvailable)

                    if let reason = device.unavailableReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var audioSection: some View {
        section("Audio") {
            Toggle("System audio", isOn: $systemAudio)
            Toggle("Microphone", isOn: $microphone)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func row(_ source: CaptureSource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selectedSourceID == source.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selectedSourceID == source.id ? Color.accentColor : .secondary)

            thumbnail(for: source)

            VStack(alignment: .leading) {
                Text(source.title).lineLimit(1)

                HStack(spacing: 4) {
                    if let icon = source.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    Text(source.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedSourceID = source.id }
    }

    @ViewBuilder
    private func thumbnail(for source: CaptureSource) -> some View {
        if let image = catalog.thumbnails[source.id] {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selectedSourceID == source.id ? Color.accentColor : Color.secondary.opacity(0.3),
                                      lineWidth: selectedSourceID == source.id ? 2 : 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 96, height: 54)
                .overlay(Image(systemName: "display").foregroundStyle(.secondary))
        }
    }

    private var filteredWindows: [CaptureSource] {
        guard !windowSearch.isEmpty else { return catalog.windows }

        return catalog.windows.filter {
            $0.title.localizedCaseInsensitiveContains(windowSearch)
                || $0.subtitle.localizedCaseInsensitiveContains(windowSearch)
        }
    }

    private var selectedSource: CaptureSource? {
        (catalog.displays + catalog.windows).first { $0.id == selectedSourceID }
    }

    private func start() {
        guard let source = selectedSource else { return }

        appState.startRecording(options: CaptureOptions(
            source: source,
            cameraDeviceID: selectedCameraID,
            systemAudio: systemAudio,
            microphone: microphone
        ))
    }
}
