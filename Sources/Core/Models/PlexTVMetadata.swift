import CoreGraphics
import Foundation

public struct PlexEpisodeIdentity: Equatable, Codable, Sendable {
    public let showTitle: String
    public let monthYear: MonthYear
    public let customEpisodeTitle: String?

    public init(showTitle: String, monthYear: MonthYear, customEpisodeTitle: String? = nil) {
        self.showTitle = showTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.monthYear = monthYear
        self.customEpisodeTitle = Self.normalizedCustomEpisodeTitle(customEpisodeTitle)
    }

    public var seasonNumber: Int {
        monthYear.year
    }

    public var episodeSort: Int {
        monthYear.month * 100 + 99
    }

    public var episodeID: String {
        "S\(seasonNumber)E\(String(format: "%04d", episodeSort))"
    }

    public var episodeTitle: String {
        customEpisodeTitle ?? monthYear.displayLabel
    }

    public var filenameBase: String {
        "\(showTitle) - \(episodeID) - \(episodeTitle)"
    }

    private static func normalizedCustomEpisodeTitle(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct OutputProvenanceAppIdentity: Equatable, Codable, Sendable {
    public let appName: String
    public let appVersion: String
    public let buildNumber: String

    public init(appName: String, appVersion: String, buildNumber: String) {
        self.appName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appVersion = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.buildNumber = buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var versionString: String {
        "\(appVersion) (\(buildNumber))"
    }
}

public struct EmbeddedOutputProvenance: Equatable, Codable, Sendable {
    public let software: String
    public let version: String
    public let information: String
    public let customEntries: [String: String]

    public init(
        software: String,
        version: String,
        information: String,
        customEntries: [String: String]
    ) {
        self.software = software
        self.version = version
        self.information = information
        self.customEntries = customEntries
    }
}

public struct EmbeddedOutputMetadata: Equatable, Codable, Sendable {
    public let title: String
    public let description: String
    public let synopsis: String
    public let comment: String
    public let show: String
    public let seasonNumber: Int
    public let episodeSort: Int
    public let episodeID: String
    public let date: String
    public let creationTime: Date?
    public let genre: String
    public let provenance: EmbeddedOutputProvenance?

    public init(
        title: String,
        description: String,
        synopsis: String,
        comment: String,
        show: String,
        seasonNumber: Int,
        episodeSort: Int,
        episodeID: String,
        date: String,
        creationTime: Date?,
        genre: String,
        provenance: EmbeddedOutputProvenance? = nil
    ) {
        self.title = title
        self.description = description
        self.synopsis = synopsis
        self.comment = comment
        self.show = show
        self.seasonNumber = seasonNumber
        self.episodeSort = episodeSort
        self.episodeID = episodeID
        self.date = date
        self.creationTime = creationTime
        self.genre = genre
        self.provenance = provenance
    }
}

public struct PlexTVMetadata: Equatable, Codable, Sendable {
    public let identity: PlexEpisodeIdentity
    public let embedded: EmbeddedOutputMetadata

    public init(identity: PlexEpisodeIdentity, embedded: EmbeddedOutputMetadata) {
        self.identity = identity
        self.embedded = embedded
    }
}

public struct ResolvedMonthYearContext: Equatable, Sendable {
    public let monthYear: MonthYear
    public let latestCaptureDate: Date?

    public init(monthYear: MonthYear, latestCaptureDate: Date?) {
        self.monthYear = monthYear
        self.latestCaptureDate = latestCaptureDate
    }
}

public enum MonthYearResolutionError: LocalizedError, Equatable {
    case noCaptureDates
    case multipleMonthYears([MonthYear])

    public var errorDescription: String? {
        switch self {
        case .noCaptureDates:
            return "Unable to derive a single month/year because one or more selected items are missing capture dates."
        case let .multipleMonthYears(values):
            let labels = values.map(\.displayLabel).joined(separator: ", ")
            return "Unable to derive a single month/year because the selected items span multiple months: \(labels)."
        }
    }
}

public enum PlexTVMetadataResolver {
    public static func defaultDescription(for monthYear: MonthYear) -> String {
        "Fisher Family Monthly Video for \(monthYear.displayLabel)"
    }

    public static func resolveMonthYear(
        from items: [MediaItem],
        timeZone: TimeZone = .current
    ) throws -> ResolvedMonthYearContext {
        guard !items.isEmpty else {
            throw MonthYearResolutionError.noCaptureDates
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var resolvedMonthYears: Set<MonthYear> = []
        var latestCaptureDate: Date?

        for item in items {
            guard let captureDate = item.captureDate else {
                throw MonthYearResolutionError.noCaptureDates
            }
            let components = calendar.dateComponents([.year, .month], from: captureDate)
            guard let month = components.month, let year = components.year else {
                throw MonthYearResolutionError.noCaptureDates
            }
            resolvedMonthYears.insert(MonthYear(month: month, year: year))
            latestCaptureDate = max(latestCaptureDate ?? captureDate, captureDate)
        }

        guard resolvedMonthYears.count == 1, let monthYear = resolvedMonthYears.first else {
            let sorted = resolvedMonthYears.sorted { lhs, rhs in
                if lhs.year != rhs.year {
                    return lhs.year < rhs.year
                }
                return lhs.month < rhs.month
            }
            throw MonthYearResolutionError.multipleMonthYears(sorted)
        }

        return ResolvedMonthYearContext(monthYear: monthYear, latestCaptureDate: latestCaptureDate)
    }

    public static func fallbackCreationTime(
        for monthYear: MonthYear,
        timeZone: TimeZone = .current
    ) -> Date {
        monthYear.dateInterval(in: timeZone).end.addingTimeInterval(-1)
    }

    public static func resolveMetadata(
        showTitle: String,
        monthYear: MonthYear,
        descriptionText: String,
        episodeTitleOverride: String? = nil,
        creationTime: Date?,
        provenance: EmbeddedOutputProvenance? = nil,
        timeZone: TimeZone = .current
    ) -> PlexTVMetadata {
        let identity = PlexEpisodeIdentity(
            showTitle: showTitle,
            monthYear: monthYear,
            customEpisodeTitle: episodeTitleOverride
        )
        let resolvedCreationTime = creationTime ?? fallbackCreationTime(for: monthYear, timeZone: timeZone)

        return PlexTVMetadata(
            identity: identity,
            embedded: EmbeddedOutputMetadata(
                title: identity.episodeTitle,
                description: descriptionText,
                synopsis: descriptionText,
                comment: descriptionText,
                show: identity.showTitle,
                seasonNumber: identity.seasonNumber,
                episodeSort: identity.episodeSort,
                episodeID: identity.episodeID,
                date: String(identity.seasonNumber),
                creationTime: resolvedCreationTime,
                genre: "Family",
                provenance: provenance
            )
        )
    }
}

public enum EmbeddedOutputProvenanceResolver {
    private static let customKeyPrefix = "com.jkfisher.monthlyvideogenerator"

    public static func resolve(
        exportProfile: ExportProfile,
        timeline: Timeline,
        appIdentity: OutputProvenanceAppIdentity
    ) -> EmbeddedOutputProvenance {
        let renderSize = normalizedRenderSize(RenderSizing.renderSize(for: timeline, policy: exportProfile.resolution))
        let frameRate = RenderSizing.frameRate(for: timeline, policy: exportProfile.frameRate)
        let information = humanReadableInformation(
            exportProfile: exportProfile,
            renderSize: renderSize,
            frameRate: frameRate
        )

        let payload = ExportProvenancePayload(
            appName: appIdentity.appName,
            appVersion: appIdentity.appVersion,
            buildNumber: appIdentity.buildNumber,
            container: exportProfile.container.rawValue,
            videoCodec: exportProfile.videoCodec.rawValue,
            audioCodec: exportProfile.audioCodec.rawValue,
            dynamicRange: exportProfile.dynamicRange.rawValue,
            resolutionPolicy: exportProfile.resolution.rawValue,
            resolvedWidth: Int(renderSize.width.rounded()),
            resolvedHeight: Int(renderSize.height.rounded()),
            frameRatePolicy: exportProfile.frameRate.rawValue,
            resolvedFrameRate: frameRate,
            audioLayout: exportProfile.audioLayout.rawValue,
            bitrateMode: exportProfile.bitrateMode.rawValue
        )

        return EmbeddedOutputProvenance(
            software: appIdentity.appName,
            version: appIdentity.versionString,
            information: information,
            customEntries: [
                "\(customKeyPrefix).app_name": appIdentity.appName,
                "\(customKeyPrefix).app_version": appIdentity.appVersion,
                "\(customKeyPrefix).build_number": appIdentity.buildNumber,
                "\(customKeyPrefix).export_profile": exportProfileSummary(payload),
                "\(customKeyPrefix).export_json": encodedJSON(payload)
            ]
        )
    }

    private static func humanReadableInformation(
        exportProfile: ExportProfile,
        renderSize: CGSize,
        frameRate: Int
    ) -> String {
        let width = Int(renderSize.width.rounded())
        let height = Int(renderSize.height.rounded())
        return [
            "\(width)x\(height)",
            "\(frameRate) fps",
            dynamicRangeDescription(exportProfile.dynamicRange),
            videoCodecDescription(exportProfile.videoCodec),
            audioDescription(codec: exportProfile.audioCodec, layout: exportProfile.audioLayout),
            exportProfile.container.rawValue.uppercased(),
            bitrateModeDescription(exportProfile.bitrateMode)
        ].joined(separator: ", ")
    }

    private static func dynamicRangeDescription(_ dynamicRange: DynamicRange) -> String {
        switch dynamicRange {
        case .hdr:
            return "HDR (HLG)"
        case .sdr:
            return "SDR"
        }
    }

    private static func videoCodecDescription(_ codec: VideoCodec) -> String {
        switch codec {
        case .hevc:
            return "HEVC"
        case .h264:
            return "H.264"
        }
    }

    private static func audioDescription(codec: AudioCodec, layout: AudioLayout) -> String {
        "\(codec.rawValue.uppercased()) \(layout.displayLabel)"
    }

    private static func bitrateModeDescription(_ mode: BitrateMode) -> String {
        switch mode {
        case .balanced:
            return "Balanced bitrate"
        case .qualityFirst:
            return "Quality-first bitrate"
        case .sizeFirst:
            return "Size-first bitrate"
        }
    }

    private static func exportProfileSummary(_ payload: ExportProvenancePayload) -> String {
        [
            "container=\(payload.container)",
            "videoCodec=\(payload.videoCodec)",
            "audioCodec=\(payload.audioCodec)",
            "dynamicRange=\(payload.dynamicRange)",
            "resolutionPolicy=\(payload.resolutionPolicy)",
            "resolvedSize=\(payload.resolvedWidth)x\(payload.resolvedHeight)",
            "frameRatePolicy=\(payload.frameRatePolicy)",
            "resolvedFrameRate=\(payload.resolvedFrameRate)",
            "audioLayout=\(payload.audioLayout)",
            "bitrateMode=\(payload.bitrateMode)"
        ].joined(separator: ",")
    }

    private static func encodedJSON(_ payload: ExportProvenancePayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if
            let data = try? encoder.encode(payload),
            let value = String(data: data, encoding: .utf8)
        {
            return value
        }

        return "{}"
    }

    private static func normalizedRenderSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: CGFloat(evenDimension(max(2, Int(size.width.rounded())))),
            height: CGFloat(evenDimension(max(2, Int(size.height.rounded()))))
        )
    }

    private static func evenDimension(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value + 1
    }

    private struct ExportProvenancePayload: Codable {
        let appName: String
        let appVersion: String
        let buildNumber: String
        let container: String
        let videoCodec: String
        let audioCodec: String
        let dynamicRange: String
        let resolutionPolicy: String
        let resolvedWidth: Int
        let resolvedHeight: Int
        let frameRatePolicy: String
        let resolvedFrameRate: Int
        let audioLayout: String
        let bitrateMode: String
    }
}
