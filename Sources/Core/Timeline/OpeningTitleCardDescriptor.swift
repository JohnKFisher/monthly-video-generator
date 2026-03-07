import Foundation

public struct OpeningTitleCardDescriptor: Equatable, Sendable {
    public let title: String
    public let contextLine: String?
    public let previewItems: [MediaItem]
    public let dateSpanText: String?
    public let variationSeed: UInt64
    public let contextLineMode: OpeningTitleCaptionMode

    public init(
        title: String,
        contextLine: String?,
        previewItems: [MediaItem],
        dateSpanText: String?,
        variationSeed: UInt64,
        contextLineMode: OpeningTitleCaptionMode = .automatic
    ) {
        self.title = title
        self.contextLine = contextLine
        self.previewItems = previewItems
        self.dateSpanText = dateSpanText
        self.variationSeed = variationSeed
        self.contextLineMode = contextLineMode
    }

    public var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Monthly Video" : trimmed
    }

    public var resolvedContextLine: String? {
        trimmed(contextLine)
    }

    public var displayContextLine: String? {
        guard let resolvedContextLine else {
            return nil
        }
        switch contextLineMode {
        case .automatic:
            return resolvedContextLine.uppercased()
        case .custom:
            return resolvedContextLine
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
