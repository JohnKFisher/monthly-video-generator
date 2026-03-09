import Foundation
import Core

enum AppMetadata {
    static let appName = "Monthly Video Generator"
    static let headerIconResourceName = "AppHeaderIcon"

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
    }

    static var versionBuildValue: String {
        "\(shortVersion) (\(buildNumber))"
    }

    static var exportProvenanceIdentity: OutputProvenanceAppIdentity {
        OutputProvenanceAppIdentity(
            appName: appName,
            appVersion: shortVersion,
            buildNumber: buildNumber
        )
    }

    static var versionBuildLabel: String {
        "Version \(versionBuildValue)"
    }
}
