import Foundation

public struct OpeningTitleCardDescriptor: Equatable, Sendable {
    public let title: String
    public let contextLine: String?
    public let previewItems: [MediaItem]
    public let dateSpanText: String?
    public let variationSeed: UInt64

    public init(
        title: String,
        contextLine: String?,
        previewItems: [MediaItem],
        dateSpanText: String?,
        variationSeed: UInt64
    ) {
        self.title = title
        self.contextLine = contextLine
        self.previewItems = previewItems
        self.dateSpanText = dateSpanText
        self.variationSeed = variationSeed
    }

    public var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Monthly Video" : trimmed
    }

    public var resolvedContextLine: String? {
        let trimmedContext = trimmed(contextLine)
        if let trimmedContext, !matches(trimmedContext, resolvedTitle) {
            return trimmedContext
        }

        let trimmedDateSpan = trimmed(dateSpanText)
        if let trimmedDateSpan, !matches(trimmedDateSpan, resolvedTitle) {
            return trimmedDateSpan
        }

        return nil
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ==
            rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
