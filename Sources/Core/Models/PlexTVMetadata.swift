import Foundation

public struct PlexEpisodeIdentity: Equatable, Codable, Sendable {
    public let showTitle: String
    public let monthYear: MonthYear

    public init(showTitle: String, monthYear: MonthYear) {
        self.showTitle = showTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.monthYear = monthYear
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
        monthYear.displayLabel
    }

    public var filenameBase: String {
        "\(showTitle) - \(episodeID) - \(episodeTitle)"
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
        genre: String
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
        creationTime: Date?,
        timeZone: TimeZone = .current
    ) -> PlexTVMetadata {
        let identity = PlexEpisodeIdentity(showTitle: showTitle, monthYear: monthYear)
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
                genre: "Family"
            )
        )
    }
}
