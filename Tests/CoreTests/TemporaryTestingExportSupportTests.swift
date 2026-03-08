import Core
import Foundation
@testable import MonthlyVideoGeneratorApp
import XCTest

final class TemporaryTestingExportSupportTests: XCTestCase {
    func testFilenameGeneratorUsesPlexTVEpisodeFormat() {
        let generator = PlexTVFilenameGenerator()

        let outputName = generator.makeOutputName(
            showTitle: "Family Videos",
            monthYear: MonthYear(month: 6, year: 2025)
        )

        XCTAssertEqual(outputName, "Family Videos - S2025E0699 - June 2025")
    }

    func testMegaTestFilenameAppendsCombinationSuffixes() {
        let generator = PlexTVFilenameGenerator()

        let outputName = generator.makeMegaTestOutputName(
            baseName: "Family Videos - S2025E0699 - June 2025",
            resolution: .fixed1080p,
            frameRate: .fps60,
            dynamicRange: .sdr,
            audioLayout: .surround51
        )

        XCTAssertEqual(outputName, "Family Videos - S2025E0699 - June 2025 - 1080 - 60fps - SDR - 5.1")
    }

    func testMegaTestSelectionWithoutVaryFlagsReturnsCurrentSelectionOnly() {
        let selection = MegaTestSelection()

        let combinations = selection.expandedCombinations(
            currentResolution: .fixed4K,
            currentFrameRate: .fps30,
            currentDynamicRange: .hdr,
            currentAudioLayout: .smart
        )

        XCTAssertEqual(
            combinations,
            [MegaTestCombination(resolution: .fixed4K, frameRate: .fps30, dynamicRange: .hdr, audioLayout: .smart)]
        )
    }

    func testMegaTestSelectionExpandsOnlyResolutionWhenRequested() {
        let selection = MegaTestSelection(varyResolution: true, varyFrameRate: false, varyDynamicRange: false)

        let combinations = selection.expandedCombinations(
            currentResolution: .fixed1080p,
            currentFrameRate: .fps60,
            currentDynamicRange: .sdr,
            currentAudioLayout: .smart
        )

        XCTAssertEqual(
            combinations,
            [
                MegaTestCombination(resolution: .fixed720p, frameRate: .fps60, dynamicRange: .sdr, audioLayout: .smart),
                MegaTestCombination(resolution: .fixed1080p, frameRate: .fps60, dynamicRange: .sdr, audioLayout: .smart),
                MegaTestCombination(resolution: .fixed4K, frameRate: .fps60, dynamicRange: .sdr, audioLayout: .smart),
                MegaTestCombination(resolution: .smart, frameRate: .fps60, dynamicRange: .sdr, audioLayout: .smart)
            ]
        )
    }

    func testMegaTestSelectionExpandsAllAxesInDeterministicUIOrder() {
        let selection = MegaTestSelection(varyResolution: true, varyFrameRate: true, varyDynamicRange: true, varyAudioLayout: true)

        let combinations = selection.expandedCombinations(
            currentResolution: .fixed1080p,
            currentFrameRate: .fps30,
            currentDynamicRange: .sdr,
            currentAudioLayout: .smart
        )

        XCTAssertEqual(combinations.count, 96)
        XCTAssertEqual(combinations.first, MegaTestCombination(resolution: .fixed720p, frameRate: .fps30, dynamicRange: .sdr, audioLayout: .mono))
        XCTAssertEqual(combinations[1], MegaTestCombination(resolution: .fixed720p, frameRate: .fps30, dynamicRange: .sdr, audioLayout: .stereo))
        XCTAssertEqual(combinations[2], MegaTestCombination(resolution: .fixed720p, frameRate: .fps30, dynamicRange: .sdr, audioLayout: .surround51))
        XCTAssertEqual(combinations[3], MegaTestCombination(resolution: .fixed720p, frameRate: .fps30, dynamicRange: .sdr, audioLayout: .smart))
        XCTAssertEqual(combinations.last, MegaTestCombination(resolution: .smart, frameRate: .smart, dynamicRange: .hdr, audioLayout: .smart))
    }
}
