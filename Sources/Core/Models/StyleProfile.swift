import Foundation

public struct StyleProfile: Equatable, Codable, Sendable {
    public let openingTitle: String?
    public let titleDurationSeconds: Double
    public let crossfadeDurationSeconds: Double
    public let stillImageDurationSeconds: Double
    public let showCaptureDateOverlay: Bool

    public init(
        openingTitle: String?,
        titleDurationSeconds: Double,
        crossfadeDurationSeconds: Double,
        stillImageDurationSeconds: Double,
        showCaptureDateOverlay: Bool = true
    ) {
        self.openingTitle = openingTitle
        self.titleDurationSeconds = max(titleDurationSeconds, 0)
        self.crossfadeDurationSeconds = max(crossfadeDurationSeconds, 0)
        self.stillImageDurationSeconds = max(stillImageDurationSeconds, 0.1)
        self.showCaptureDateOverlay = showCaptureDateOverlay
    }

    public static let stageOneDefault = StyleProfile(
        openingTitle: nil,
        titleDurationSeconds: 0,
        crossfadeDurationSeconds: 0,
        stillImageDurationSeconds: 3.0,
        showCaptureDateOverlay: true
    )

    public static let stageTwoDefault = StyleProfile(
        openingTitle: nil,
        titleDurationSeconds: 2.5,
        crossfadeDurationSeconds: 0.75,
        stillImageDurationSeconds: 3.0,
        showCaptureDateOverlay: true
    )
}
