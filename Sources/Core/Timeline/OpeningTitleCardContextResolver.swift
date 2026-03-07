import Foundation

public enum OpeningTitleCardContextResolver {
    public static func resolveAutomaticContextLine(
        title: String,
        source: MediaSource?,
        monthYear: MonthYear?,
        dateSpanText: String?
    ) -> String? {
        if case let .photosLibrary(scope)? = source {
            switch scope {
            case let .album(_, title: albumTitle):
                if let albumTitle = trimmed(albumTitle), !matches(albumTitle, title) {
                    return albumTitle
                }
            case let .entireLibrary(sourceMonthYear):
                let label = sourceMonthYear.displayLabel
                if !matches(label, title) {
                    return label
                }
            }
        }

        if let monthYear {
            let label = monthYear.displayLabel
            if !matches(label, title) {
                return label
            }
        }

        if let dateSpanText = trimmed(dateSpanText), !matches(dateSpanText, title) {
            return dateSpanText
        }

        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ==
            rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
