import Foundation
import Core
#if canImport(AppKit)
import AppKit
#endif

enum AppMetadata {
    private struct AppLinks: Decodable {
        let repositoryURL: String?
    }

    static let appName = "Monthly Video Generator"
    static let headerIconResourceName = "AppHeaderIcon"
    static let easterEggImageResourceName = "JohnKennethEasterEgg"
    static let appLinksResourceName = "AppLinks"
    private static let appResourceBundleName = "MonthlyVideoGenerator_MonthlyVideoGeneratorApp.bundle"

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

    static var repositoryURL: URL? {
        guard
            let bundle = appResourceBundle,
            let url = bundle.url(forResource: appLinksResourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let links = try? JSONDecoder().decode(AppLinks.self, from: data),
            let repositoryURL = links.repositoryURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !repositoryURL.isEmpty
        else {
            return nil
        }

        return URL(string: repositoryURL)
    }

    #if canImport(AppKit)
    private static var appResourceBundle: Bundle? {
        let candidateURLs = [
            Bundle.main.resourceURL?.appendingPathComponent(appResourceBundleName, isDirectory: true),
            Bundle.main.bundleURL.appendingPathComponent(appResourceBundleName, isDirectory: true),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(appResourceBundleName, isDirectory: true)
        ].compactMap { $0 }

        for url in candidateURLs {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        return nil
    }

    private static func bundledImage(
        named resourceName: String,
        extension fileExtension: String
    ) -> NSImage? {
        guard
            let bundle = appResourceBundle,
            let url = bundle.url(forResource: resourceName, withExtension: fileExtension)
        else {
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
