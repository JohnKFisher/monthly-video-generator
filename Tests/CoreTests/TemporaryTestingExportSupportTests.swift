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

    func testFilenameGeneratorUsesCustomEpisodeTitleWhenProvided() {
        let generator = PlexTVFilenameGenerator()

        let outputName = generator.makeOutputName(
            showTitle: "Family Videos",
            monthYear: MonthYear(month: 6, year: 2025),
            episodeTitleOverride: "Summer Highlights"
        )

        XCTAssertEqual(outputName, "Family Videos - S2025E0699 - Summer Highlights")
    }
}
