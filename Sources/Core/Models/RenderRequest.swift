import Foundation

public enum PhotosScope: Equatable, Codable, Sendable, CustomStringConvertible {
    case entireLibrary(monthYear: MonthYear)
    case album(localIdentifier: String, title: String?)

    public var description: String {
        switch self {
        case let .entireLibrary(monthYear):
            return "Entire library (\(monthYear.displayLabel))"
        case let .album(localIdentifier, title):
            let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolvedTitle, !resolvedTitle.isEmpty {
                return "Album: \(resolvedTitle)"
            }
            return "Album (id: \(localIdentifier))"
        }
    }
}

public enum MediaSource: Equatable, Sendable {
    case folder(path: URL, recursive: Bool)
    case photosLibrary(scope: PhotosScope)
}

public enum OrderingRule: Equatable, Codable, Sendable {
    case captureDateAscendingStable
}

public struct OutputTarget: Equatable, Sendable {
    public let directory: URL
    public let baseFilename: String

    public init(directory: URL, baseFilename: String) {
        self.directory = directory
        self.baseFilename = baseFilename
    }
}

public struct RenderRequest: Equatable, Sendable {
    public let source: MediaSource
    public let monthYear: MonthYear?
    public let ordering: OrderingRule
    public let style: StyleProfile
    public let export: ExportProfile
    public let output: OutputTarget
    public let plexTVMetadata: PlexTVMetadata?

    public init(
        source: MediaSource,
        monthYear: MonthYear?,
        ordering: OrderingRule,
        style: StyleProfile,
        export: ExportProfile,
        output: OutputTarget,
        plexTVMetadata: PlexTVMetadata? = nil
    ) {
        self.source = source
        self.monthYear = monthYear
        self.ordering = ordering
        self.style = style
        self.export = export
        self.output = output
        self.plexTVMetadata = plexTVMetadata
    }
}
