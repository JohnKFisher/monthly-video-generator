import Foundation

@MainActor
final class AppShellPreferencesStore: ObservableObject {
    @Published private(set) var defaultOutputDirectoryURL: URL
    @Published private(set) var lastInputDirectoryURL: URL?
    @Published private(set) var lastOutputDirectoryURL: URL?

    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager

        defaultOutputDirectoryURL = Self.defaultMoviesDirectory(fileManager: fileManager)
        lastInputDirectoryURL = nil
        lastOutputDirectoryURL = nil

        restoreBookmarks()
    }

    func setDefaultOutputDirectory(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        defaultOutputDirectoryURL = normalizedURL
        lastOutputDirectoryURL = normalizedURL
        persistBookmark(for: normalizedURL, key: AppShellPreferenceKeys.defaultOutputFolderBookmark)
        persistBookmark(for: normalizedURL, key: AppShellPreferenceKeys.lastOutputFolderBookmark)
    }

    func resetDefaultOutputDirectory() {
        let fallback = Self.defaultMoviesDirectory(fileManager: fileManager)
        defaultOutputDirectoryURL = fallback
        lastOutputDirectoryURL = fallback
        clearBookmark(for: AppShellPreferenceKeys.defaultOutputFolderBookmark)
        persistBookmark(for: fallback, key: AppShellPreferenceKeys.lastOutputFolderBookmark)
    }

    func rememberInputDirectory(_ url: URL?) {
        let normalizedURL = url?.standardizedFileURL
        lastInputDirectoryURL = normalizedURL
        persistOptionalBookmark(for: normalizedURL, key: AppShellPreferenceKeys.lastInputFolderBookmark)
    }

    func rememberOutputDirectory(_ url: URL?) {
        let normalizedURL = url?.standardizedFileURL
        lastOutputDirectoryURL = normalizedURL
        persistOptionalBookmark(for: normalizedURL, key: AppShellPreferenceKeys.lastOutputFolderBookmark)
    }

    static func defaultMoviesDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Monthly Video Generator", isDirectory: true)
    }

    private func restoreBookmarks() {
        defaultOutputDirectoryURL = resolveDirectory(
            for: AppShellPreferenceKeys.defaultOutputFolderBookmark,
            fallback: Self.defaultMoviesDirectory(fileManager: fileManager)
        ) ?? Self.defaultMoviesDirectory(fileManager: fileManager)

        lastInputDirectoryURL = resolveDirectory(
            for: AppShellPreferenceKeys.lastInputFolderBookmark,
            fallback: nil
        )

        lastOutputDirectoryURL = resolveDirectory(
            for: AppShellPreferenceKeys.lastOutputFolderBookmark,
            fallback: defaultOutputDirectoryURL
        )
    }

    private func resolveDirectory(for key: String, fallback: URL?) -> URL? {
        guard let data = userDefaults.data(forKey: key) else {
            return fallback
        }

        var isStale = false
        guard
            let resolvedURL = try? URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        else {
            userDefaults.removeObject(forKey: key)
            return fallback
        }

        guard directoryExists(at: resolvedURL) else {
            userDefaults.removeObject(forKey: key)
            return fallback
        }

        if isStale {
            persistBookmark(for: resolvedURL, key: key)
        }

        return resolvedURL.standardizedFileURL
    }

    private func persistOptionalBookmark(for url: URL?, key: String) {
        guard let url else {
            clearBookmark(for: key)
            return
        }
        persistBookmark(for: url, key: key)
    }

    private func persistBookmark(for url: URL, key: String) {
        guard let data = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }

    private func clearBookmark(for key: String) {
        userDefaults.removeObject(forKey: key)
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
