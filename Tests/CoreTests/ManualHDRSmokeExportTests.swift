@testable import Core
import Foundation
import XCTest

final class ManualHDRSmokeExportTests: XCTestCase {
    func testHDRExportSmokeFromVideoTestFolder() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HDR_SMOKE"] == "1" else {
            throw XCTSkip("Set RUN_HDR_SMOKE=1 to run manual HDR smoke export.")
        }

        let sourceFolder = URL(fileURLWithPath: "/Users/jkfisher/Desktop/VideoTestFolder", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceFolder.path) else {
            throw XCTSkip("VideoTestFolder not found at \(sourceFolder.path)")
        }

        let discovery = FolderMediaDiscoveryService()
        let allItems = try await discovery.discover(folderURL: sourceFolder, recursive: false)
        let selectedItems = pickSmokeSubset(from: allItems)
        XCTAssertGreaterThanOrEqual(selectedItems.count, 2, "Need enough media items to exercise HDR pipeline.")

        let request = RenderRequest(
            source: .folder(path: sourceFolder, recursive: false),
            monthYear: nil,
            ordering: .captureDateAscendingStable,
            style: StyleProfile(
                openingTitle: "HDR Smoke Test",
                titleDurationSeconds: 1.0,
                crossfadeDurationSeconds: 0.25,
                stillImageDurationSeconds: 1.0
            ),
            export: ExportProfile(
                container: .mov,
                videoCodec: .hevc,
                audioCodec: .aac,
                resolution: .fixed1080p,
                dynamicRange: .hdr,
                hdrFFmpegBinaryMode: .autoSystemThenBundled,
                audioLayout: .stereo,
                bitrateMode: .sizeFirst
            ),
            output: OutputTarget(
                directory: try makeOutputDirectory(named: "MonthlyVideoGeneratorSmoke"),
                baseFilename: "HDR Smoke Test \(timestamp())"
            )
        )

        let result = try await render(items: selectedItems, request: request, writeDiagnosticsLog: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path), "Expected output file was not created.")
        XCTAssertTrue(result.backendSummary?.contains("FFmpeg HDR backend") == true, "Expected FFmpeg HDR backend summary.")
    }

    func testHDRAcceptanceFromVideoTestFolder() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HDR_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set RUN_HDR_ACCEPTANCE=1 to run the full HDR acceptance render.")
        }

        let sourceFolder = URL(fileURLWithPath: "/Users/jkfisher/Desktop/VideoTestFolder", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceFolder.path) else {
            throw XCTSkip("VideoTestFolder not found at \(sourceFolder.path)")
        }

        let discovery = FolderMediaDiscoveryService()
        let items = try await discovery.discover(folderURL: sourceFolder, recursive: true)
        XCTAssertEqual(items.count, 21, "Expected the full VideoTestFolder dataset.")

        let outputDirectory = try makeOutputDirectory(named: "MonthlyVideoGeneratorAcceptance")
        let request = RenderRequest(
            source: .folder(path: sourceFolder, recursive: true),
            monthYear: MonthYear(month: 3, year: 2026),
            ordering: .captureDateAscendingStable,
            style: StyleProfile(
                openingTitle: "HDR TEST",
                titleDurationSeconds: 7.5,
                crossfadeDurationSeconds: 1.0,
                stillImageDurationSeconds: 5.0,
                showCaptureDateOverlay: true
            ),
            export: ExportProfile(
                container: .mp4,
                videoCodec: .hevc,
                audioCodec: .aac,
                resolution: .smart,
                dynamicRange: .hdr,
                hdrFFmpegBinaryMode: .bundledOnly,
                audioLayout: .stereo,
                bitrateMode: .balanced
            ),
            output: OutputTarget(
                directory: outputDirectory,
                baseFilename: "HDR Acceptance \(timestamp())"
            )
        )

        let result = try await render(items: items, request: request, writeDiagnosticsLog: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path), "Expected acceptance output file was not created.")
        XCTAssertTrue(result.backendSummary?.contains("FFmpeg HDR backend") == true, "Expected FFmpeg HDR backend summary.")
        print("hdr_acceptance_output=\(result.outputURL.path)")
        if let diagnosticsLogURL = result.diagnosticsLogURL {
            print("hdr_acceptance_diagnostics=\(diagnosticsLogURL.path)")
        }
        let reportURL = result.outputURL.deletingPathExtension().appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: reportURL.path) {
            print("hdr_acceptance_report=\(reportURL.path)")
        }
    }

    private func pickSmokeSubset(from items: [MediaItem]) -> [MediaItem] {
        let sorted = items.sorted { lhs, rhs in
            let lhsDate = lhs.captureDate ?? .distantPast
            let rhsDate = rhs.captureDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.stableTieBreaker < rhs.stableTieBreaker
        }

        let videos = sorted.filter { $0.type == .video }
        let images = sorted.filter { $0.type == .image }

        var selected: [MediaItem] = []
        selected.append(contentsOf: images.prefix(1))
        selected.append(contentsOf: videos.prefix(1))
        return selected
    }

    private func makeOutputDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func render(
        items: [MediaItem],
        request: RenderRequest,
        writeDiagnosticsLog: Bool
    ) async throws -> RenderResult {
        let coordinator = RenderCoordinator()
        let preparation = coordinator.prepareFromItems(items, request: request)
        return try await coordinator.render(
            preparation: preparation,
            request: request,
            photoMaterializer: nil,
            writeDiagnosticsLog: writeDiagnosticsLog,
            progressHandler: nil
        )
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
