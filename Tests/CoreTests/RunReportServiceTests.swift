import Foundation
import XCTest
@testable import Core

final class RunReportServiceTests: XCTestCase {
    func testRunReportIncludesOpeningTitleTreatmentMetadata() throws {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let items = makeItems(count: 12)
        let style = StyleProfile(
            openingTitle: "March 2026",
            titleDurationSeconds: 10.0,
            crossfadeDurationSeconds: 1.0,
            stillImageDurationSeconds: 5.0,
            openingTitleCaptionMode: .custom,
            openingTitleCaptionText: "Fisher Family Videos"
        )
        let timeline = TimelineBuilder(variationSeedGenerator: { 42 }).buildTimeline(
            items: items,
            ordering: .captureDateAscendingStable,
            style: style,
            source: .folder(path: outputDirectory, recursive: true)
        )
        let preparation = RenderPreparation(
            items: items,
            timeline: timeline,
            warnings: []
        )
        let request = RenderRequest(
            source: .folder(path: outputDirectory, recursive: true),
            monthYear: nil,
            ordering: .captureDateAscendingStable,
            style: style,
            export: .balancedDefault,
            output: OutputTarget(directory: outputDirectory, baseFilename: "out")
        )
        let report = RunReportService().makeReport(
            request: request,
            preparation: preparation,
            outputURL: outputDirectory.appendingPathComponent("out.mp4"),
            diagnosticsLogURL: nil,
            renderBackendSummary: "FFmpeg backend"
        )

        XCTAssertEqual(
            report.openingTitleTreatment,
            OpeningTitleTreatment.randomizedShippingFamilyTreatment(for: 42).rawValue
        )
        XCTAssertEqual(report.openingTitleVariationSeed, 42)
        XCTAssertEqual(report.openingTitlePreviewCount, 10)

        let reportURL = outputDirectory.appendingPathComponent("report.json")
        try RunReportService().write(report, to: reportURL)
        let data = try Data(contentsOf: reportURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            json["openingTitleTreatment"] as? String,
            OpeningTitleTreatment.randomizedShippingFamilyTreatment(for: 42).rawValue
        )
        XCTAssertEqual(json["openingTitleVariationSeed"] as? UInt64, 42)
        XCTAssertEqual(json["openingTitlePreviewCount"] as? Int, 10)
    }

    private func makeItems(count: Int) -> [MediaItem] {
        (0..<count).map { index in
            MediaItem(
                id: "item-\(index)",
                type: .image,
                captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 86_400)),
                duration: nil,
                pixelSize: CGSize(width: 1920, height: 1080),
                colorInfo: .unknown,
                locator: .file(URL(fileURLWithPath: "/tmp/item-\(index).jpg")),
                fileSizeBytes: Int64(index + 1),
                filename: "item-\(index).jpg"
            )
        }
    }
}
