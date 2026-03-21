import Foundation

public enum OpeningTitleCaptionMode: String, CaseIterable, Codable, Sendable {
    case automatic
    case custom

    public var displayLabel: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .custom:
            return "Custom"
        }
    }
}

public struct StyleProfile: Equatable, Codable, Sendable {
    public let openingTitle: String?
    public let titleDurationSeconds: Double
    public let crossfadeDurationSeconds: Double
    public let stillImageDurationSeconds: Double
    public let showCaptureDateOverlay: Bool
    public let openingTitleCaptionMode: OpeningTitleCaptionMode
    public let openingTitleCaptionText: String

    public init(
        openingTitle: String?,
        titleDurationSeconds: Double,
        crossfadeDurationSeconds: Double,
        stillImageDurationSeconds: Double,
        showCaptureDateOverlay: Bool = true,
        openingTitleCaptionMode: OpeningTitleCaptionMode = .automatic,
        openingTitleCaptionText: String = ""
    ) {
        self.openingTitle = openingTitle
        self.titleDurationSeconds = max(titleDurationSeconds, 0)
        self.crossfadeDurationSeconds = max(crossfadeDurationSeconds, 0)
        self.stillImageDurationSeconds = max(stillImageDurationSeconds, 0.1)
        self.showCaptureDateOverlay = showCaptureDateOverlay
        self.openingTitleCaptionMode = openingTitleCaptionMode
        self.openingTitleCaptionText = openingTitleCaptionText
    }

    public static let stageOneDefault = StyleProfile(
        openingTitle: nil,
        titleDurationSeconds: 0,
        crossfadeDurationSeconds: 0,
        stillImageDurationSeconds: 3.0,
        showCaptureDateOverlay: true,
        openingTitleCaptionMode: .automatic,
        openingTitleCaptionText: ""
    )

    public static let stageTwoDefault = StyleProfile(
        openingTitle: nil,
        titleDurationSeconds: 10.0,
        crossfadeDurationSeconds: 0.75,
        stillImageDurationSeconds: 3.0,
        showCaptureDateOverlay: true,
        openingTitleCaptionMode: .automatic,
        openingTitleCaptionText: ""
    )
}
