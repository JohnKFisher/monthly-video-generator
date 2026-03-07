@testable import Core
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class CaptureDateOverlayBenchmarkTests: XCTestCase {
    func testCaptureDateOverlayBenchmarkOnMixedDataset() async throws {
        guard ProcessInfo.processInfo.environment["RUN_CAPTURE_DATE_BENCH"] == "1" else {
            throw XCTSkip("Set RUN_CAPTURE_DATE_BENCH=1 to run the manual capture-date benchmark.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureDateOverlayBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let photo1 = try makeFixtureImage(
            outputURL: root.appendingPathComponent("photo-1.jpg"),
            backgroundColor: CGColor(red: 0.09, green: 0.12, blue: 0.22, alpha: 1),
            accentColor: CGColor(red: 0.95, green: 0.82, blue: 0.25, alpha: 1),
            accentRect: CGRect(x: 80, y: 120, width: 420, height: 220)
        )
        let photo2 = try makeFixtureImage(
            outputURL: root.appendingPathComponent("photo-2.jpg"),
            backgroundColor: CGColor(red: 0.16, green: 0.30, blue: 0.25, alpha: 1),
            accentColor: CGColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1),
            accentRect: CGRect(x: 860, y: 180, width: 360, height: 320)
        )
        let videoURL = root.appendingPathComponent("clip-1.mp4")
        try makeFixtureVideo(outputURL: videoURL)

        let items = try makeItems(photo1: photo1, photo2: photo2, video: videoURL)
        let outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let export = ExportProfile(
            container: .mp4,
            videoCodec: .h264,
            audioCodec: .aac,
            frameRate: .fps30,
            resolution: .fixed1080p,
            dynamicRange: .sdr,
            hdrFFmpegBinaryMode: .systemOnly,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        let sequence: [(String, Bool)] = [
            ("overlay_off_1", false),
            ("overlay_on_1", true),
            ("overlay_off_2", false),
            ("overlay_on_2", true)
        ]
        let coordinator = RenderCoordinator()
        var groupedTimings: [Bool: [TimeInterval]] = [:]

        for (label, overlayEnabled) in sequence {
            let elapsed = try await measureRender(
                label: label,
                overlayEnabled: overlayEnabled,
                items: items,
                sourceFolder: root,
                outputDirectory: outputDirectory,
                export: export,
                coordinator: coordinator
            )
            groupedTimings[overlayEnabled, default: []].append(elapsed)
        }

        let offAverage = average(groupedTimings[false] ?? [])
        let onAverage = average(groupedTimings[true] ?? [])
        let delta = onAverage - offAverage
        let deltaPercent = offAverage > 0 ? (delta / offAverage) * 100 : 0

        print("capture_date_benchmark_average_overlay_off_seconds=\(format(offAverage))")
        print("capture_date_benchmark_average_overlay_on_seconds=\(format(onAverage))")
        print("capture_date_benchmark_delta_seconds=\(format(delta))")
        print("capture_date_benchmark_delta_percent=\(format(deltaPercent))")

        XCTAssertGreaterThan(offAverage, 0)
        XCTAssertGreaterThan(onAverage, 0)
    }

    private func measureRender(
        label: String,
        overlayEnabled: Bool,
        items: [MediaItem],
        sourceFolder: URL,
        outputDirectory: URL,
        export: ExportProfile,
        coordinator: RenderCoordinator
    ) async throws -> TimeInterval {
        let request = RenderRequest(
            source: .folder(path: sourceFolder, recursive: false),
            monthYear: nil,
            ordering: .captureDateAscendingStable,
            style: StyleProfile(
                openingTitle: nil,
                titleDurationSeconds: 0,
                crossfadeDurationSeconds: 0.5,
                stillImageDurationSeconds: 1.5,
                showCaptureDateOverlay: overlayEnabled
            ),
            export: export,
            output: OutputTarget(
                directory: outputDirectory,
                baseFilename: "capture-date-\(label)"
            )
        )

        let preparation = coordinator.prepareFromItems(items, request: request)
        let startedAt = Date()
        let result = try await coordinator.render(
            preparation: preparation,
            request: request,
            photoMaterializer: nil,
            writeDiagnosticsLog: false,
            progressHandler: nil
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: result.outputURL.path)
        let outputBytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let resolved = result.resolvedVideoInfo
        print(
            "capture_date_benchmark_run=\(label) overlay=\(overlayEnabled) seconds=\(format(elapsed)) output=\(result.outputURL.lastPathComponent) " +
            "bytes=\(outputBytes) resolved=\(resolved?.width ?? 0)x\(resolved?.height ?? 0)@\(resolved?.frameRate ?? 0)"
        )
        return elapsed
    }

    private func makeItems(photo1: URL, photo2: URL, video: URL) throws -> [MediaItem] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let captureDates = [
            calendar.date(from: DateComponents(year: 2023, month: 6, day: 14, hour: 14, minute: 33)),
            calendar.date(from: DateComponents(year: 2023, month: 6, day: 15, hour: 9, minute: 12)),
            calendar.date(from: DateComponents(year: 2023, month: 6, day: 16, hour: 18, minute: 5))
        ]
        guard let firstDate = captureDates[0], let secondDate = captureDates[1], let thirdDate = captureDates[2] else {
            throw NSError(domain: "CaptureDateOverlayBenchmarkTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to build fixture capture dates"])
        }

        return [
            try MediaItem(
                id: "photo-1",
                type: .image,
                captureDate: firstDate,
                duration: nil,
                pixelSize: CGSize(width: 1600, height: 900),
                colorInfo: .unknown,
                locator: .file(photo1),
                fileSizeBytes: fileSize(at: photo1),
                filename: photo1.lastPathComponent
            ),
            try MediaItem(
                id: "photo-2",
                type: .image,
                captureDate: secondDate,
                duration: nil,
                pixelSize: CGSize(width: 1600, height: 900),
                colorInfo: .unknown,
                locator: .file(photo2),
                fileSizeBytes: fileSize(at: photo2),
                filename: photo2.lastPathComponent
            ),
            try MediaItem(
                id: "video-1",
                type: .video,
                captureDate: thirdDate,
                duration: CMTime(seconds: 2.0, preferredTimescale: 600),
                sourceFrameRate: 30,
                sourceAudioChannelCount: 1,
                pixelSize: CGSize(width: 1280, height: 720),
                colorInfo: .unknown,
                locator: .file(video),
                fileSizeBytes: fileSize(at: video),
                filename: video.lastPathComponent
            )
        ]
    }

    private func makeFixtureImage(
        outputURL: URL,
        backgroundColor: CGColor,
        accentColor: CGColor,
        accentRect: CGRect
    ) throws -> URL {
        let width = 1600
        let height = 900
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw NSError(domain: "CaptureDateOverlayBenchmarkTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate fixture image context"])
        }

        context.setFillColor(backgroundColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(accentColor)
        context.fill(accentRect)

        guard let image = context.makeImage() else {
            throw NSError(domain: "CaptureDateOverlayBenchmarkTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create fixture image"])
        }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "CaptureDateOverlayBenchmarkTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "CaptureDateOverlayBenchmarkTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize fixture image"])
        }

        return outputURL
    }

    private func makeFixtureVideo(outputURL: URL) throws {
        let candidates = [
            "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("FFmpeg binary not found for capture-date benchmark fixture generation.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-y",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
            "-t", "2",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-shortest",
            outputURL.path
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(decoding: stderrData, as: UTF8.self)
            throw NSError(
                domain: "CaptureDateOverlayBenchmarkTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "FFmpeg fixture generation failed: \(stderrText)"]
            )
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func average(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private func format(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }
}
