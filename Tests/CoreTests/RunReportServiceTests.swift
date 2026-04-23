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

    func testRunReportIncludesBakeoffMetricsWhenProvided() throws {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let items = makeItems(count: 4)
        let style = StyleProfile(
            openingTitle: "Test Export",
            titleDurationSeconds: 10.0,
            crossfadeDurationSeconds: 1.0,
            stillImageDurationSeconds: 5.0
        )
        let request = RenderRequest(
            source: .photosLibrary(scope: .album(localIdentifier: "album-123", title: "Test Export")),
            monthYear: nil,
            ordering: .captureDateAscendingStable,
            style: style,
            export: ExportProfileManager().defaultProfile(),
            output: OutputTarget(directory: outputDirectory, baseFilename: "out")
        )
        let preparation = RenderPreparation(
            items: items,
            timeline: TimelineBuilder().buildTimeline(items: items, request: request),
            warnings: ["Smart audio resolved to Stereo."]
        )

        let report = RunReportService().makeReport(
            request: request,
            preparation: preparation,
            outputURL: outputDirectory.appendingPathComponent("out.mp4"),
            diagnosticsLogURL: outputDirectory.appendingPathComponent("diagnostics.log"),
            renderBackendSummary: "FFmpeg HDR backend: bundled ffmpeg + libx265",
            outputFileSizeBytes: 987_654_321,
            renderElapsedSeconds: 123.45,
            renderBackendInfo: RenderBackendInfo(binarySource: .bundled, encoder: "libx265"),
            resolvedVideoInfo: ResolvedRenderVideoInfo(width: 3840, height: 2160, frameRate: 60),
            finalHEVCTuningPreset: "slow",
            finalHEVCTuningCRF: 18,
            presentationTimingAudits: [
                ProgressivePresentationTimingAudit(
                    clipKind: .still,
                    hasCaptureDateOverlay: false,
                    commandCount: 3,
                    clipCount: 3,
                    totalElapsedSeconds: 18.75
                )
            ]
        )

        XCTAssertEqual(report.outputFileSizeBytes, 987_654_321)
        XCTAssertEqual(try XCTUnwrap(report.renderElapsedSeconds), 123.45, accuracy: 0.0001)
        XCTAssertEqual(report.renderBackendInfo, RenderBackendInfo(binarySource: .bundled, encoder: "libx265"))
        XCTAssertEqual(report.resolvedVideoInfo, ResolvedRenderVideoInfo(width: 3840, height: 2160, frameRate: 60))
        XCTAssertEqual(report.finalHEVCTuningPreset, "slow")
        XCTAssertEqual(report.finalHEVCTuningCRF, 18)
        XCTAssertEqual(
            report.presentationTimingAudits,
            [
                ProgressivePresentationTimingAudit(
                    clipKind: .still,
                    hasCaptureDateOverlay: false,
                    commandCount: 3,
                    clipCount: 3,
                    totalElapsedSeconds: 18.75
                )
            ]
        )

        let reportURL = outputDirectory.appendingPathComponent("bakeoff-report.json")
        try RunReportService().write(report, to: reportURL)
        let data = try Data(contentsOf: reportURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual((json["outputFileSizeBytes"] as? NSNumber)?.int64Value, 987_654_321)
        XCTAssertEqual(try XCTUnwrap((json["renderElapsedSeconds"] as? NSNumber)?.doubleValue), 123.45, accuracy: 0.0001)
        let backendInfo = try XCTUnwrap(json["renderBackendInfo"] as? [String: Any])
        XCTAssertEqual(backendInfo["binarySource"] as? String, "bundled")
        XCTAssertEqual(backendInfo["encoder"] as? String, "libx265")
        let resolvedVideoInfo = try XCTUnwrap(json["resolvedVideoInfo"] as? [String: Any])
        XCTAssertEqual(resolvedVideoInfo["width"] as? Int, 3840)
        XCTAssertEqual(resolvedVideoInfo["height"] as? Int, 2160)
        XCTAssertEqual(resolvedVideoInfo["frameRate"] as? Int, 60)
        XCTAssertEqual(json["finalHEVCTuningPreset"] as? String, "slow")
        XCTAssertEqual(json["finalHEVCTuningCRF"] as? Int, 18)
        let presentationTimingAudits = try XCTUnwrap(json["presentationTimingAudits"] as? [[String: Any]])
        XCTAssertEqual(presentationTimingAudits.count, 1)
        XCTAssertEqual(presentationTimingAudits.first?["clipKind"] as? String, "still")
        XCTAssertEqual(presentationTimingAudits.first?["hasCaptureDateOverlay"] as? Bool, false)
        XCTAssertEqual(presentationTimingAudits.first?["commandCount"] as? Int, 3)
        XCTAssertEqual(presentationTimingAudits.first?["clipCount"] as? Int, 3)
        XCTAssertEqual(
            try XCTUnwrap((presentationTimingAudits.first?["totalElapsedSeconds"] as? NSNumber)?.doubleValue),
            18.75,
            accuracy: 0.0001
        )
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
