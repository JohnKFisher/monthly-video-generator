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

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonthlyVideoGeneratorSmoke", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let discovery = FolderMediaDiscoveryService()
        let allItems = try await discovery.discover(folderURL: sourceFolder, recursive: false)
        let selectedItems = pickSmokeSubset(from: allItems)
        XCTAssertGreaterThanOrEqual(selectedItems.count, 2, "Need enough media items to exercise HDR pipeline.")

        let style = StyleProfile(
            openingTitle: "HDR Smoke Test",
            titleDurationSeconds: 1.0,
            crossfadeDurationSeconds: 0.25,
            stillImageDurationSeconds: 1.0
        )
        let export = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            resolution: .fixed1080p,
            dynamicRange: .hdr,
            hdrFFmpegBinaryMode: .autoSystemThenBundled,
            audioLayout: .stereo,
            bitrateMode: .sizeFirst
        )
        let request = RenderRequest(
            source: .folder(path: sourceFolder, recursive: false),
            monthYear: nil,
            ordering: .captureDateAscendingStable,
            style: style,
            export: export,
            output: OutputTarget(
                directory: outputDirectory,
                baseFilename: "HDR Smoke Test \(timestamp())"
            )
        )

        let coordinator = RenderCoordinator()
        let preparation = coordinator.prepareFromItems(selectedItems, request: request)
        let result = try await coordinator.render(
            preparation: preparation,
            request: request,
            photoMaterializer: nil,
            writeDiagnosticsLog: true,
            progressHandler: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path), "Expected output file was not created.")
        XCTAssertTrue(result.backendSummary?.contains("FFmpeg HDR backend") == true, "Expected FFmpeg HDR backend summary.")
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

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
