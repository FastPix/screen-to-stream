import Foundation

/// App version from the bundle. `scripts/assemble.sh` stamps it from the repo's VERSION file.
enum AppVersion {
    static let current: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
}
