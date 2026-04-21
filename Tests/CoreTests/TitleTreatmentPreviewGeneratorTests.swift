import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Core

final class TitleTreatmentPreviewGeneratorTests: XCTestCase {
    func testClassicAndFamilyCollectionsResolveExpectedEntries() {
        let classicEntries = TitleTreatmentPreviewCollection.classicExplorer.entries
        XCTAssertEqual(classicEntries.count, 17)
        XCTAssertEqual(classicEntries.filter { $0.section == .standard }.count, 12)
        XCTAssertEqual(classicEntries.filter { $0.section == .wild }.count, 5)

        let familyEntries = TitleTreatmentPreviewCollection.currentCollageFamily.entries
        XCTAssertEqual(familyEntries.count, 21)
        XCTAssertEqual(familyEntries.first?.treatment, .currentCollage)
        XCTAssertEqual(familyEntries.first?.badge, "Control")
        XCTAssertEqual(familyEntries.filter { $0.section == .close }.count, 11)
        XCTAssertEqual(familyEntries.filter { $0.section == .wide }.count, 10)
    }

    func testAllTitleTreatmentsRenderValidClipAtRequestedSizeAndDuration() async throws {
        let factory = StillImageClipFactory()
        let previewAssets = try makePreviewAssets(count: 4)
        let descriptor = OpeningTitleCardDescriptor(
            title: "March 2026",
            contextLine: "Fisher Family Videos",
            previewItems: [],
            dateSpanText: "March 19, 2026",
            variationSeed: 42,
            contextLineMode: .custom
        )

        var clipURLs: [URL] = []
        defer {
            previewAssets.forEach { try? FileManager.default.removeItem(at: $0.url) }
            clipURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        }

        for treatment in OpeningTitleTreatment.allCases {
            let clipURL = try await factory.makeTitleCardClip(
                descriptor: descriptor,
                previewAssets: previewAssets,
                duration: CMTime(seconds: 0.2, preferredTimescale: 600),
                renderSize: CGSize(width: 640, height: 360),
                frameRate: 10,
                treatment: treatment
            )
            clipURLs.append(clipURL)

            let size = try await loadedVideoSize(url: clipURL)
            XCTAssertEqual(size.width, 640, accuracy: 0.001, "Unexpected width for \(treatment.rawValue)")
            XCTAssertEqual(size.height, 360, accuracy: 0.001, "Unexpected height for \(treatment.rawValue)")

            let asset = AVURLAsset(url: clipURL)
            let duration = try await asset.load(.duration)
            XCTAssertGreaterThan(duration.seconds, 0.15, "Expected non-trivial duration for \(treatment.rawValue)")
        }
    }

    func testDefaultTitleCardPathMatchesCurrentCollageTreatment() async throws {
        let factory = StillImageClipFactory()
        let previewAssets = try makePreviewAssets(count: 4)
        let descriptor = OpeningTitleCardDescriptor(
            title: "March 2026",
            contextLine: "Fisher Family Videos",
            previewItems: [],
            dateSpanText: "March 19, 2026",
            variationSeed: 99,
            contextLineMode: .custom
        )

        let defaultClipURL = try await factory.makeTitleCardClip(
            descriptor: descriptor,
            previewAssets: previewAssets,
            duration: CMTime(seconds: 0.3, preferredTimescale: 600),
            renderSize: CGSize(width: 640, height: 360),
            frameRate: 10
        )
        let explicitClipURL = try await factory.makeTitleCardClip(
            descriptor: descriptor,
            previewAssets: previewAssets,
            duration: CMTime(seconds: 0.3, preferredTimescale: 600),
            renderSize: CGSize(width: 640, height: 360),
            frameRate: 10,
            treatment: .currentCollage
        )

        defer {
            previewAssets.forEach { try? FileManager.default.removeItem(at: $0.url) }
            try? FileManager.default.removeItem(at: defaultClipURL)
            try? FileManager.default.removeItem(at: explicitClipURL)
        }

        let defaultFrame = try await renderedFrame(from: defaultClipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let explicitFrame = try await renderedFrame(from: explicitClipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))

        XCTAssertEqual(pixelChecksum(defaultFrame), pixelChecksum(explicitFrame))
    }

    func testPreviewGeneratorWritesFullArtifactSetForClassicExplorer() async throws {
        try requireFFmpegProbeBinary()
        let sourceFolderURL = try makeFixtureSourceFolder(imageCount: 6)
        let outputRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TitleTreatmentPreviewGeneratorTests-output-root-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = outputRootURL.appendingPathComponent("preview-set", isDirectory: true)
        let service = TitleTreatmentPreviewGeneratorService()

        defer {
            try? FileManager.default.removeItem(at: sourceFolderURL)
            try? FileManager.default.removeItem(at: outputRootURL)
        }

        let result = try await service.generate(
            config: TitleTreatmentPreviewConfiguration(
                inputFolderURL: sourceFolderURL,
                title: "March 2026",
                caption: "Fisher Family Videos",
                outputRootDirectory: outputRootURL,
                outputDirectoryOverride: outputDirectory,
                durationSeconds: 0.2,
                renderSize: CGSize(width: 640, height: 360),
                frameRate: 10
            )
        )

        XCTAssertEqual(result.artifacts.count, TitleTreatmentPreviewCollection.classicExplorer.entries.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.indexURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.standardContactSheetURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.wildContactSheetURL).path))

        let manifestData = try Data(contentsOf: result.manifestURL)
        let manifest = try JSONDecoder().decode(TitleTreatmentPreviewManifest.self, from: manifestData)
        XCTAssertEqual(manifest.collection, TitleTreatmentPreviewCollection.classicExplorer.rawValue)
        XCTAssertEqual(manifest.treatmentCount, 17)
        XCTAssertEqual(manifest.sections, [OpeningTitleTreatmentCategory.standard.rawValue, OpeningTitleTreatmentCategory.wild.rawValue])
        XCTAssertEqual(manifest.artifacts.filter { $0.section == OpeningTitleTreatmentCategory.standard.rawValue }.count, 12)
        XCTAssertEqual(manifest.artifacts.filter { $0.section == OpeningTitleTreatmentCategory.wild.rawValue }.count, 5)

        for artifact in manifest.artifacts {
            XCTAssertNotNil(artifact.clipFilename)
            if let clipFilename = artifact.clipFilename {
                XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputDirectory.appendingPathComponent(clipFilename).path))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputDirectory.appendingPathComponent(artifact.earlyStillFilename).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputDirectory.appendingPathComponent(artifact.lateStillFilename).path))
        }
    }

    func testPreviewGeneratorWritesFullArtifactSetForCurrentCollageFamily() async throws {
        try requireFFmpegProbeBinary()
        let sourceFolderURL = try makeFixtureSourceFolder(imageCount: 10)
        let outputRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TitleTreatmentPreviewGeneratorTests-family-output-root-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = outputRootURL.appendingPathComponent("preview-set", isDirectory: true)
        let service = TitleTreatmentPreviewGeneratorService()

        defer {
            try? FileManager.default.removeItem(at: sourceFolderURL)
            try? FileManager.default.removeItem(at: outputRootURL)
        }

        let result = try await service.generate(
            config: TitleTreatmentPreviewConfiguration(
                inputFolderURL: sourceFolderURL,
                title: "March 2026",
                caption: "Fisher Family Videos",
                outputRootDirectory: outputRootURL,
                outputDirectoryOverride: outputDirectory,
                durationSeconds: 0.16,
                renderSize: CGSize(width: 480, height: 270),
                frameRate: 8,
                collection: .currentCollageFamily
            )
        )

        XCTAssertEqual(result.artifacts.count, 21)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.indexURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.closeContactSheetURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.wideContactSheetURL).path))

        let manifestData = try Data(contentsOf: result.manifestURL)
        let manifest = try JSONDecoder().decode(TitleTreatmentPreviewManifest.self, from: manifestData)
        XCTAssertEqual(manifest.collection, TitleTreatmentPreviewCollection.currentCollageFamily.rawValue)
        XCTAssertEqual(manifest.treatmentCount, 21)
        XCTAssertEqual(manifest.sections, [OpeningTitleTreatmentCategory.close.rawValue, OpeningTitleTreatmentCategory.wide.rawValue])
        XCTAssertEqual(manifest.artifacts.filter { $0.section == OpeningTitleTreatmentCategory.close.rawValue }.count, 11)
        XCTAssertEqual(manifest.artifacts.filter { $0.section == OpeningTitleTreatmentCategory.wide.rawValue }.count, 10)
        XCTAssertEqual(manifest.artifacts.first?.treatment, OpeningTitleTreatment.currentCollage.rawValue)
        XCTAssertEqual(manifest.artifacts.first?.badge, "Control")

        for artifact in manifest.artifacts {
            XCTAssertNotNil(artifact.clipFilename)
            if let clipFilename = artifact.clipFilename {
                XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputDirectory.appendingPathComponent(clipFilename).path))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputDirectory.appendingPathComponent(artifact.earlyStillFilename).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputDirectory.appendingPathComponent(artifact.lateStillFilename).path))
        }
    }

    func testPreviewGeneratorSupportsFullHDCurrentCollageFixture() async throws {
        try requireFFmpegProbeBinary()
        let sourceFolderURL = try makeFixtureSourceFolder(imageCount: 6)
        let outputRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TitleTreatmentPreviewGeneratorTests-fullhd-output-root-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = outputRootURL.appendingPathComponent("preview-set", isDirectory: true)
        let service = TitleTreatmentPreviewGeneratorService()

        defer {
            try? FileManager.default.removeItem(at: sourceFolderURL)
            try? FileManager.default.removeItem(at: outputRootURL)
        }

        let result = try await service.generate(
            config: TitleTreatmentPreviewConfiguration(
                inputFolderURL: sourceFolderURL,
                title: "March 2026",
                caption: "Fisher Family Videos",
                outputRootDirectory: outputRootURL,
                outputDirectoryOverride: outputDirectory,
                durationSeconds: 0.25,
                renderSize: CGSize(width: 1920, height: 1080),
                frameRate: 12,
                treatments: [.currentCollage]
            )
        )

        XCTAssertEqual(result.artifacts.count, 1)
        XCTAssertNotNil(result.artifacts[0].clipFilename)
        if let clipFilename = result.artifacts[0].clipFilename {
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputDirectory.appendingPathComponent(clipFilename).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.standardContactSheetURL).path))
    }

    func testManualGenerateMarch2026PreviewArtifacts() async throws {
        guard ProcessInfo.processInfo.environment["RUN_TITLE_TREATMENT_PREVIEW"] == "1" else {
            throw XCTSkip("Set RUN_TITLE_TREATMENT_PREVIEW=1 to generate the full review artifact set.")
        }

        let workspaceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let outputRootURL = workspaceURL.appendingPathComponent("tmp/title-treatment-previews", isDirectory: true)
        let service = TitleTreatmentPreviewGeneratorService()
        let result = try await service.generate(
            config: TitleTreatmentPreviewConfiguration(
                inputFolderURL: URL(fileURLWithPath: "/Users/jkfisher/Desktop/VideoTestFolder", isDirectory: true),
                title: "March 2026",
                caption: "Fisher Family Videos",
                outputRootDirectory: outputRootURL,
                collection: .currentCollageFamily
            )
        )

        print("manual_title_treatment_preview_output=\(result.outputDirectory.path)")
        XCTAssertEqual(result.artifacts.count, TitleTreatmentPreviewCollection.currentCollageFamily.entries.count)
    }

    private func makePreviewAssets(count: Int) throws -> [StillImageClipFactory.TitleCardPreviewAsset] {
        try (0..<count).map { index in
            let url = try makeFixtureImage(index: index)
            return StillImageClipFactory.TitleCardPreviewAsset(
                url: url,
                mediaType: .image,
                filename: "fixture-\(index).png"
            )
        }
    }

    private func makeFixtureSourceFolder(imageCount: Int) throws -> URL {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TitleTreatmentPreviewGeneratorTests-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for index in 0..<imageCount {
            let imageURL = try makeFixtureImage(index: index)
            let targetURL = folderURL.appendingPathComponent("fixture-\(index)").appendingPathExtension("png")
            try FileManager.default.copyItem(at: imageURL, to: targetURL)
            try FileManager.default.removeItem(at: imageURL)
        }
        return folderURL
    }

    private func requireFFmpegProbeBinary() throws {
        do {
            _ = try FFmpegBinaryResolver().resolveProbeBinary(mode: .autoSystemThenBundled)
        } catch {
            throw XCTSkip("Skipping FFmpeg-dependent preview test because no ffmpeg/ffprobe binary pair is available: \(error)")
        }
    }

    private func makeFixtureImage(index: Int) throws -> URL {
        let width = 960
        let height = 640
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw NSError(domain: "TitleTreatmentPreviewGeneratorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create fixture context"])
        }

        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.10, 0.18, 0.32),
            (0.16, 0.28, 0.18),
            (0.32, 0.16, 0.12),
            (0.18, 0.14, 0.30),
            (0.14, 0.30, 0.30),
            (0.28, 0.22, 0.10)
        ]
        let color = palette[index % palette.count]
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.96, green: 0.84, blue: 0.32, alpha: 1))
        context.fill(CGRect(x: 80 + (index * 18), y: 120 + (index * 12), width: 360, height: 200))
        context.setFillColor(CGColor(red: 0.26, green: 0.76, blue: 0.88, alpha: 1))
        context.fill(CGRect(x: 520 - (index * 10), y: 260 - (index * 8), width: 220, height: 180))

        guard let image = context.makeImage() else {
            throw NSError(domain: "TitleTreatmentPreviewGeneratorTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create fixture image"])
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TitleTreatmentPreviewGeneratorTests-\(UUID().uuidString)")
            .appendingPathExtension("png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "TitleTreatmentPreviewGeneratorTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create fixture destination"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "TitleTreatmentPreviewGeneratorTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize fixture image"])
        }
        return url
    }

    private func loadedVideoSize(url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "TitleTreatmentPreviewGeneratorTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Expected video track"])
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformed = naturalSize.applying(preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private func renderedFrame(from url: URL, at time: CMTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: time).image
    }

    private func pixelChecksum(_ image: CGImage) -> UInt64 {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hash: UInt64 = 1469598103934665603
        for byte in buffer {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }
}
