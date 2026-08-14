import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var preferences: PreferencesStore

    @State private var tokenId = ""
    @State private var secret = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var mcpConnected = false
    @State private var mcpResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                credentialsSection
                Divider()
                recordingSection
                Divider()
                aiSection
                Divider()
                mcpSection
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Back") { appState.closeSettings() }
                Spacer()
            }
            .padding(12)
            .background(.bar)
        }
        .onAppear {
            if let creds = CredentialStore.load() {
                tokenId = creds.tokenId
                secret = creds.secret
            }
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FastPix credentials")
                .font(.headline)
            Text("Use a dev/sandbox token; revoke it from the dashboard when done.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Access Token ID", text: $tokenId)
                .textFieldStyle(.roundedBorder)
            SecureField("Secret Key", text: $secret)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save") { save() }
                    .disabled(tokenId.isEmpty || secret.isEmpty)
                Button("Clear", role: .destructive) { clear() }
                    .disabled(!appState.hasCredentials)
                Button(testing ? "Testing…" : "Test connection") { test() }
                    .disabled(tokenId.isEmpty || secret.isEmpty || testing)

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                }
            }
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recording")
                .font(.headline)
            Toggle("Keep local file after upload", isOn: $preferences.keepLocalRecordings)

            Toggle("Show Dock icon", isOn: $preferences.showDockIcon)
            Text("Adds a Dock icon and a Cmd-Tab entry — handy when the menu-bar icon is hidden by a full menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Upload resolution", selection: Binding(
                get: { preferences.maxResolution },
                set: { preferences.maxResolution = $0 }
            )) {
                Text("1080p").tag("1080p")
                Text("4K (2160p)").tag("2160p")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            Button("Reveal recordings folder") {
                let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("ScreenToStream", isDirectory: true)
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI & subtitles")
                .font(.headline)
            Text("Requested at upload; results appear in FastPix, not in this app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Generate subtitles", isOn: Binding(
                get: { preferences.aiFeatures.generateSubtitles },
                set: { preferences.aiFeatures.generateSubtitles = $0 }
            ))
            Toggle(isOn: Binding(
                get: { preferences.aiFeatures.generateChapters },
                set: { preferences.aiFeatures.generateChapters = $0 }
            )) {
                VStack(alignment: .leading) {
                    Text("Generate chapters")
                    Text("Requires an AI-enabled FastPix account")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI agents (MCP)")
                .font(.headline)
            Text("Lets any MCP-compatible agent (Claude Code, Cursor, Zed, …) list and inspect your recordings. Read-only, no credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Circle().fill(mcpConnected ? .green : .secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(mcpConnected ? "Connected" : "Not connected")
                Spacer()
                if mcpConnected {
                    Button("Remove") { runMCP { try MCPSetup.remove() } }
                } else {
                    Button("Connect") { runMCP { try MCPSetup.install() } }
                }
            }

            if let result = mcpResult {
                Text(result).font(.caption).foregroundStyle(result.hasPrefix("✓") ? .green : .red)
            }

            Button("Copy setup command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MCPSetup.installCommand(), forType: .string)
                mcpResult = "✓ Command copied — run it in your terminal (or your agent's MCP config)"
            }
            .font(.caption)

            Divider().padding(.vertical, 2)

            Toggle(isOn: Binding(
                get: { preferences.allowMCPControl },
                set: { appState.setControlEnabled($0) }
            )) {
                VStack(alignment: .leading) {
                    Text("Allow AI agents to start/stop recordings")
                    Text("Any MCP client can control recording; it still shows the countdown and stop pill.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // `claude mcp list` shells out — never on the main thread, or Settings stalls opening.
            Task.detached {
                let installed = MCPSetup.isInstalled()
                await MainActor.run { mcpConnected = installed }
            }
        }
    }

    private func runMCP(_ action: @escaping () throws -> Void) {
        do {
            try action()
            mcpConnected = MCPSetup.isInstalled()
            mcpResult = "✓ Updated"
        } catch {
            mcpResult = "✗ \(error.localizedDescription)"
        }
    }

    private func save() {
        try? CredentialStore.save(FastPixCredentials(tokenId: tokenId, secret: secret))
        appState.refreshCredentials()
        testResult = "✓ Saved"
    }

    private func clear() {
        CredentialStore.clear()
        tokenId = ""; secret = ""
        appState.refreshCredentials()
        testResult = nil
    }

    private func test() {
        testing = true
        testResult = nil
        // Test the freshly-typed values without persisting them yet.
        let header = "Basic " + Data("\(tokenId):\(secret)".utf8).base64EncodedString()
        let api = FastPixAPI(session: appState.apiSession, authProvider: { header })

        Task {
            do {
                try await api.testConnection()
                testResult = "✓ Connected"
            } catch let error as FastPixAPIError {
                testResult = error.statusCode == 401 ? "✗ Invalid credentials" : "✗ HTTP \(error.statusCode)"
            } catch {
                testResult = "✗ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
