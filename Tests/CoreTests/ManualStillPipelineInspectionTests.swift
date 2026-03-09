import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Core

final class ManualStillPipelineInspectionTests: XCTestCase {
    func testInspectVideoTest4StillPipeline() async throws {
        guard ProcessInfo.processInfo.environment["RUN_MANUAL_STILL_PIPELINE_INSPECTION"] == "1" else {
            throw XCTSkip("Set RUN_MANUAL_STILL_PIPELINE_INSPECTION=1 to run manual still pipeline inspection.")
        }

        let sourceURL = URL(fileURLWithPath: "/Users/jkfisher/Desktop/VideoTestFolder/VideoTest - 4 of 21.jpeg")
        let finalExportURL = URL(fileURLWithPath: "/Users/jkfisher/Movies/Monthly Video Generator/Family Videos - S2026E0399 - March 2026-v4.mp4")
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonthlyVideoGeneratorStillInspection", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let factory = StillImageClipFactory()
        let colorInfo = try factory.sourceColorInfo(forImageURL: sourceURL, dynamicRange: .hdr)
        let materializedClipURL = try await factory.makeVideoClip(
            fromImageURL: sourceURL,
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720),
            frameRate: 60,
            dynamicRange: .hdr
        )

        let preservedMaterializedClipURL = outputDirectory.appendingPathComponent("sample4-materialized.mov")
        if FileManager.default.fileExists(atPath: preservedMaterializedClipURL.path) {
            try FileManager.default.removeItem(at: preservedMaterializedClipURL)
        }
        try FileManager.default.copyItem(at: materializedClipURL, to: preservedMaterializedClipURL)

        let sourceCopyURL = outputDirectory.appendingPathComponent("sample4-source.jpeg")
        if FileManager.default.fileExists(atPath: sourceCopyURL.path) {
            try FileManager.default.removeItem(at: sourceCopyURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: sourceCopyURL)

        let materializedFrame = try await renderedFrame(from: materializedClipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let finalFrame = try await renderedFrame(from: finalExportURL, at: CMTime(seconds: 20.5, preferredTimescale: 600))

        try writePNG(materializedFrame, to: outputDirectory.appendingPathComponent("sample4-materialized-frame.png"))
        try writePNG(finalFrame, to: outputDirectory.appendingPathComponent("sample4-final-export-frame.png"))

        let summary = """
        source=\(sourceURL.path)
        sourceColorPrimaries=\(colorInfo.colorPrimaries ?? "nil")
        sourceTransferFunction=\(colorInfo.transferFunction ?? "nil")
        sourceTransferFlavor=\(colorInfo.transferFlavor.rawValue)
        sourceHDRMetadata=\(colorInfo.hdrMetadataFlavor.rawValue)
        materializedClip=\(preservedMaterializedClipURL.path)
        materializedFrame=\(outputDirectory.appendingPathComponent("sample4-materialized-frame.png").path)
        finalExport=\(finalExportURL.path)
        finalFrameTimeSeconds=20.5
        finalExportFrame=\(outputDirectory.appendingPathComponent("sample4-final-export-frame.png").path)
        """
        try summary.write(
            to: outputDirectory.appendingPathComponent("sample4-summary.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func renderedFrame(from url: URL, at time: CMTime) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        return try await generator.image(at: time).image
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "ManualStillPipelineInspectionTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination at \(url.path)"]
            )
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "ManualStillPipelineInspectionTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG at \(url.path)"]
            )
        }
    }
}
