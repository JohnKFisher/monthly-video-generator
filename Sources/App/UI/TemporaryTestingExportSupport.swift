import Core
import Foundation

struct PlexTVFilenameGenerator: Sendable {
    func makeOutputName(showTitle: String, monthYear: MonthYear) -> String {
        PlexEpisodeIdentity(showTitle: showTitle, monthYear: monthYear).filenameBase
    }

    func makeMegaTestOutputName(
        baseName: String,
        resolution: ResolutionPolicy,
        frameRate: FrameRatePolicy,
        dynamicRange: DynamicRange,
        audioLayout: AudioLayout
    ) -> String {
        "\(baseName) - \(Self.resolutionToken(for: resolution)) - \(Self.frameRateToken(for: frameRate))fps - \(Self.dynamicRangeToken(for: dynamicRange)) - \(Self.audioToken(for: audioLayout))"
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

    static func audioToken(for audioLayout: AudioLayout) -> String {
        audioLayout.testingToken
    }
}

struct MegaTestSelection: Equatable, Sendable {
    var varyResolution: Bool = false
    var varyFrameRate: Bool = false
    var varyDynamicRange: Bool = false
    var varyAudioLayout: Bool = false

    func expandedCombinations(
        currentResolution: ResolutionPolicy,
        currentFrameRate: FrameRatePolicy,
        currentDynamicRange: DynamicRange,
        currentAudioLayout: AudioLayout
    ) -> [MegaTestCombination] {
        let resolutions = varyResolution ? ResolutionPolicy.allCases : [currentResolution.normalized]
        let frameRates = varyFrameRate ? FrameRatePolicy.allCases : [currentFrameRate]
        let dynamicRanges = varyDynamicRange ? DynamicRange.allCases : [currentDynamicRange]
        let audioLayouts = varyAudioLayout ? AudioLayout.allCases : [currentAudioLayout]

        return resolutions.flatMap { resolution in
            frameRates.flatMap { frameRate in
                dynamicRanges.flatMap { dynamicRange in
                    audioLayouts.map { audioLayout in
                        MegaTestCombination(
                            resolution: resolution.normalized,
                            frameRate: frameRate,
                            dynamicRange: dynamicRange,
                            audioLayout: audioLayout
                        )
                    }
                }
            }
        }
    }
}

struct MegaTestCombination: Identifiable, Equatable, Sendable {
    let resolution: ResolutionPolicy
    let frameRate: FrameRatePolicy
    let dynamicRange: DynamicRange
    let audioLayout: AudioLayout

    var id: String {
        "\(resolution.normalized.rawValue)::\(frameRate.rawValue)::\(dynamicRange.rawValue)::\(audioLayout.rawValue)"
    }

    var displayLabel: String {
        "\(PlexTVFilenameGenerator.resolutionToken(for: resolution)) / \(frameRateDisplayLabel) / \(PlexTVFilenameGenerator.dynamicRangeToken(for: dynamicRange)) / \(audioLayout.displayLabel)"
    }

    var frameRateDisplayLabel: String {
        "\(PlexTVFilenameGenerator.frameRateToken(for: frameRate)) fps"
    }
}
