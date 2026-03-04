import Foundation

public enum PhotosScope: Equatable, Codable, Sendable {
    case entireLibrary(monthYear: MonthYear)
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

    public init(
        source: MediaSource,
        monthYear: MonthYear?,
        ordering: OrderingRule,
        style: StyleProfile,
        export: ExportProfile,
        output: OutputTarget
    ) {
        self.source = source
        self.monthYear = monthYear
        self.ordering = ordering
        self.style = style
        self.export = export
        self.output = output
    }
}
