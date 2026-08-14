import Foundation

/// UserDefaults-backed prefs. No credentials here — those live only in the Keychain.
@MainActor
final class PreferencesStore: ObservableObject {
    private enum Key {
        static let keepLocal = "keepLocalRecordings"
        static let maxResolution = "maxResolution"
        static let generateSubtitles = "ai.generateSubtitles"
        static let generateChapters = "ai.generateChapters"
        static let allowMCPControl = "allowMCPControl"
        static let showDockIcon = "showDockIcon"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.maxResolution) == nil {
            defaults.set("1080p", forKey: Key.maxResolution)
        }
        if defaults.object(forKey: Key.generateSubtitles) == nil {
            defaults.set(true, forKey: Key.generateSubtitles)
        }
    }

    var aiFeatures: AIFeatures {
        get {
            AIFeatures(generateSubtitles: defaults.bool(forKey: Key.generateSubtitles),
                       generateChapters: defaults.bool(forKey: Key.generateChapters))
        }
        set {
            defaults.set(newValue.generateSubtitles, forKey: Key.generateSubtitles)
            defaults.set(newValue.generateChapters, forKey: Key.generateChapters)
            objectWillChange.send()
        }
    }

    @Published var keepLocalRecordings: Bool = UserDefaults.standard.bool(forKey: Key.keepLocal) {
        didSet { defaults.set(keepLocalRecordings, forKey: Key.keepLocal) }
    }

    /// Opt-in Dock icon and Cmd-Tab entry for the otherwise menu-bar-only app. Default off.
    @Published var showDockIcon: Bool = UserDefaults.standard.bool(forKey: Key.showDockIcon) {
        didSet { defaults.set(showDockIcon, forKey: Key.showDockIcon) }
    }

    var maxResolution: String {
        get { defaults.string(forKey: Key.maxResolution) ?? "1080p" }
        set { defaults.set(newValue, forKey: Key.maxResolution); objectWillChange.send() }
    }

    /// Opt-in: lets any MCP client start/stop recordings via the control channel. Default off.
    var allowMCPControl: Bool {
        get { defaults.bool(forKey: Key.allowMCPControl) }
        set { defaults.set(newValue, forKey: Key.allowMCPControl); objectWillChange.send() }
    }
}
