import Foundation
import Core
#if canImport(AppKit)
import AppKit
#endif

enum AppMetadata {
    static let appName = "Monthly Video Generator"
    static let headerIconResourceName = "AppHeaderIcon"
    static let easterEggImageResourceName = "JohnKennethEasterEgg"

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

    #if canImport(AppKit)
    private static func bundledImage(
        named resourceName: String,
        extension fileExtension: String
    ) -> NSImage? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: fileExtension) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    static let headerIconImage: NSImage? = {
        bundledImage(named: headerIconResourceName, extension: "png")
    }()

    static let easterEggImage: NSImage? = {
        bundledImage(named: easterEggImageResourceName, extension: "jpeg")
    }()
    #endif
}
