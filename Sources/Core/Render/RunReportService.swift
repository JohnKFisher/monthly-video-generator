import Foundation

public struct RunReport: Equatable {
    public let generatedAt: Date
    public let sourceDescription: String
    public let mediaCount: Int
    public let estimatedDurationSeconds: Double
    public let warnings: [String]
    public let outputPath: String
    public let diagnosticsLogPath: String?
    public let renderBackendSummary: String?
    public let exportProfile: ExportProfile
    public let plexTVMetadata: PlexTVMetadata?
    public let chapters: [RenderChapter]
    public let openingTitleTreatment: String?
    public let openingTitleVariationSeed: UInt64?
    public let openingTitlePreviewCount: Int?

    public init(
        generatedAt: Date,
        sourceDescription: String,
        mediaCount: Int,
        estimatedDurationSeconds: Double,
        warnings: [String],
        outputPath: String,
        diagnosticsLogPath: String?,
        renderBackendSummary: String?,
        exportProfile: ExportProfile,
        plexTVMetadata: PlexTVMetadata?,
        chapters: [RenderChapter],
        openingTitleTreatment: String? = nil,
        openingTitleVariationSeed: UInt64? = nil,
        openingTitlePreviewCount: Int? = nil
    ) {
        self.generatedAt = generatedAt
        self.sourceDescription = sourceDescription
        self.mediaCount = mediaCount
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.warnings = warnings
        self.outputPath = outputPath
        self.diagnosticsLogPath = diagnosticsLogPath
        self.renderBackendSummary = renderBackendSummary
        self.exportProfile = exportProfile
        self.plexTVMetadata = plexTVMetadata
        self.chapters = chapters
        self.openingTitleTreatment = openingTitleTreatment
        self.openingTitleVariationSeed = openingTitleVariationSeed
        self.openingTitlePreviewCount = openingTitlePreviewCount
    }
}

public final class RunReportService {
    public init() {}

    public func makeReport(
        request: RenderRequest,
        preparation: RenderPreparation,
        outputURL: URL,
        diagnosticsLogURL: URL?,
        renderBackendSummary: String?,
        generatedAt: Date = Date()
    ) -> RunReport {
        let sourceDescription: String
        switch request.source {
        case let .folder(path, recursive):
            sourceDescription = "Folder: \(path.path) (recursive: \(recursive))"
        case let .photosLibrary(scope):
            sourceDescription = "Photos source: \(scope)"
        }

        let openingTitleDescriptor: OpeningTitleCardDescriptor?
        if case let .titleCard(descriptor) = preparation.timeline.segments.first?.asset {
            openingTitleDescriptor = descriptor
        } else {
            openingTitleDescriptor = nil
        }

        return RunReport(
            generatedAt: generatedAt,
            sourceDescription: sourceDescription,
            mediaCount: preparation.items.count,
            estimatedDurationSeconds: preparation.timeline.estimatedDuration.seconds,
            warnings: preparation.warnings,
            outputPath: outputURL.path,
            diagnosticsLogPath: diagnosticsLogURL?.path,
            renderBackendSummary: renderBackendSummary,
            exportProfile: request.export,
            plexTVMetadata: request.plexTVMetadata,
            chapters: request.chapters,
            openingTitleTreatment: openingTitleDescriptor?.treatment.rawValue,
            openingTitleVariationSeed: openingTitleDescriptor?.variationSeed,
            openingTitlePreviewCount: openingTitleDescriptor?.previewItems.count
        )
    }

    public func write(_ report: RunReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ReportDTO(report: report))
        try data.write(to: url)
    }

    private struct ReportDTO: Codable {
        let generatedAt: Date
        let sourceDescription: String
        let mediaCount: Int
        let estimatedDurationSeconds: Double
        let warnings: [String]
        let outputPath: String
        let diagnosticsLogPath: String?
        let renderBackendSummary: String?
        let exportProfile: ExportProfile
        let plexTVMetadata: PlexTVMetadata?
        let chapters: [RenderChapter]
        let openingTitleTreatment: String?
        let openingTitleVariationSeed: UInt64?
        let openingTitlePreviewCount: Int?

        init(report: RunReport) {
            generatedAt = report.generatedAt
            sourceDescription = report.sourceDescription
            mediaCount = report.mediaCount
            estimatedDurationSeconds = report.estimatedDurationSeconds
            warnings = report.warnings
            outputPath = report.outputPath
            diagnosticsLogPath = report.diagnosticsLogPath
            renderBackendSummary = report.renderBackendSummary
            exportProfile = report.exportProfile
            plexTVMetadata = report.plexTVMetadata
            chapters = report.chapters
            openingTitleTreatment = report.openingTitleTreatment
            openingTitleVariationSeed = report.openingTitleVariationSeed
            openingTitlePreviewCount = report.openingTitlePreviewCount
        }
    }
}
