import Core
import Foundation

struct TemporaryTestingFilenameGenerator: Sendable {
    static let literalPrefix = "S2026E"

    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func makeOutputName(
        resolution: ResolutionPolicy,
        frameRate: FrameRatePolicy,
        dynamicRange: DynamicRange
    ) -> String {
        makeOutputName(
            resolution: resolution,
            frameRate: frameRate,
            dynamicRange: dynamicRange,
            date: now()
        )
    }

    func makeOutputName(
        resolution: ResolutionPolicy,
        frameRate: FrameRatePolicy,
        dynamicRange: DynamicRange,
        date: Date
    ) -> String {
        let epoch = Int64(floor(date.timeIntervalSince1970))
        return "Testing - \(Self.literalPrefix)\(epoch) - \(Self.resolutionToken(for: resolution)) - \(Self.frameRateToken(for: frameRate))fps - \(Self.dynamicRangeToken(for: dynamicRange))"
    }

    static func resolutionToken(for resolution: ResolutionPolicy) -> String {
        switch resolution.normalized {
        case .fixed720p:
            return "720"
        case .fixed1080p:
            return "1080"
        case .fixed4K:
            return "4K"
        case .smart, .matchSourceMax:
            return "Smart"
        }
    }

    static func frameRateToken(for frameRate: FrameRatePolicy) -> String {
        switch frameRate {
        case .fps30:
            return "30"
        case .fps60:
            return "60"
        case .smart:
            return "Smart"
        }
    }

    static func dynamicRangeToken(for dynamicRange: DynamicRange) -> String {
        dynamicRange.rawValue.uppercased()
    }
}

struct MegaTestSelection: Equatable, Sendable {
    var varyResolution: Bool = false
    var varyFrameRate: Bool = false
    var varyDynamicRange: Bool = false

    func expandedCombinations(
        currentResolution: ResolutionPolicy,
        currentFrameRate: FrameRatePolicy,
        currentDynamicRange: DynamicRange
    ) -> [MegaTestCombination] {
        let resolutions = varyResolution ? ResolutionPolicy.allCases : [currentResolution.normalized]
        let frameRates = varyFrameRate ? FrameRatePolicy.allCases : [currentFrameRate]
        let dynamicRanges = varyDynamicRange ? DynamicRange.allCases : [currentDynamicRange]

        return resolutions.flatMap { resolution in
            frameRates.flatMap { frameRate in
                dynamicRanges.map { dynamicRange in
                    MegaTestCombination(
                        resolution: resolution.normalized,
                        frameRate: frameRate,
                        dynamicRange: dynamicRange
                    )
                }
            }
        }
    }
}

struct MegaTestCombination: Identifiable, Equatable, Sendable {
    let resolution: ResolutionPolicy
    let frameRate: FrameRatePolicy
    let dynamicRange: DynamicRange

    var id: String {
        "\(resolution.normalized.rawValue)::\(frameRate.rawValue)::\(dynamicRange.rawValue)"
    }

    var displayLabel: String {
        "\(TemporaryTestingFilenameGenerator.resolutionToken(for: resolution)) / \(frameRateDisplayLabel) / \(TemporaryTestingFilenameGenerator.dynamicRangeToken(for: dynamicRange))"
    }

    var frameRateDisplayLabel: String {
        "\(TemporaryTestingFilenameGenerator.frameRateToken(for: frameRate)) fps"
    }
}
