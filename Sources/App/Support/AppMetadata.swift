import Foundation

enum AppMetadata {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
    }

    static var versionBuildLabel: String {
        "Version \(shortVersion) (\(buildNumber))"
    }
}
