import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Core

final class StillImageClipFactoryTests: XCTestCase {
    func testLargeStillClipCanBeInsertedIntoCompositionTrack() async throws {
        let renderSize = CGSize(width: 5712, height: 4284)
        let duration = CMTime(value: 1, timescale: 30)
        let factory = StillImageClipFactory()
        let imageURL = try makeFixtureImage()
        let clipURL = try await factory.makeVideoClip(fromImageURL: imageURL, duration: duration, renderSize: renderSize)

        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: clipURL)
        }

        let asset = AVURLAsset(url: clipURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            XCTFail("Expected generated clip to contain a video track")
            return
        }
        let trackRange = try await videoTrack.load(.timeRange)
        XCTAssertTrue(trackRange.duration > .zero)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            XCTFail("Expected composition video track")
            return
        }

        XCTAssertNoThrow(try compositionTrack.insertTimeRange(trackRange, of: videoTrack, at: .zero))
    }

    func testLargeStillClipHDRModeCanBeInsertedIntoCompositionTrack() async throws {
        let renderSize = CGSize(width: 5712, height: 4284)
        let duration = CMTime(value: 1, timescale: 30)
        let factory = StillImageClipFactory()
        let imageURL = try makeFixtureImage()
        let clipURL = try await factory.makeVideoClip(
            fromImageURL: imageURL,
            duration: duration,
            renderSize: renderSize,
            dynamicRange: .hdr
        )

        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: clipURL)
        }

        let asset = AVURLAsset(url: clipURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            XCTFail("Expected generated HDR-mode clip to contain a video track")
            return
        }
        let trackRange = try await videoTrack.load(.timeRange)
        XCTAssertTrue(trackRange.duration > .zero)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            XCTFail("Expected composition video track")
            return
        }

        XCTAssertNoThrow(try compositionTrack.insertTimeRange(trackRange, of: videoTrack, at: .zero))
    }

    func testTitleCardClipMatchesFixedTierRenderSize() async throws {
        let renderSize = CGSize(width: 1280, height: 720)
        let duration = CMTime(value: 1, timescale: 30)
        let factory = StillImageClipFactory()
        let clipURL = try await factory.makeTitleCardClip(title: "Fixed", duration: duration, renderSize: renderSize)

        defer {
            try? FileManager.default.removeItem(at: clipURL)
        }

        let videoSize = try await loadedVideoSize(url: clipURL)
        XCTAssertEqual(videoSize.width, renderSize.width, accuracy: 0.001)
        XCTAssertEqual(videoSize.height, renderSize.height, accuracy: 0.001)
    }

    func testTitleCardClipMatchesSmartResolvedRenderSize() async throws {
        let renderSize = RenderSizing.renderSize(
            for: [MediaItem(
                id: "portrait",
                type: .image,
                captureDate: Date(),
                duration: nil,
                pixelSize: CGSize(width: 3024, height: 4032),
                colorInfo: .unknown,
                locator: .file(URL(fileURLWithPath: "/tmp/portrait.jpg")),
                fileSizeBytes: 1_000,
                filename: "portrait.jpg"
            )],
            policy: .smart
        )
        let duration = CMTime(value: 1, timescale: 30)
        let factory = StillImageClipFactory()
        let clipURL = try await factory.makeTitleCardClip(title: "Smart", duration: duration, renderSize: renderSize)

        defer {
            try? FileManager.default.removeItem(at: clipURL)
        }

        let videoSize = try await loadedVideoSize(url: clipURL)
        XCTAssertEqual(videoSize.width, renderSize.width, accuracy: 0.001)
        XCTAssertEqual(videoSize.height, renderSize.height, accuracy: 0.001)
    }

    private func loadedVideoSize(url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(
                domain: "StillImageClipFactoryTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Expected generated clip to contain a video track"]
            )
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformed = naturalSize.applying(preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private func makeFixtureImage() throws -> URL {
        let width = 1200
        let height = 800
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw NSError(domain: "StillImageClipFactoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate fixture image context"])
        }

        context.setFillColor(CGColor(red: 0.09, green: 0.12, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.82, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 80, y: 120, width: 420, height: 220))

        guard let image = context.makeImage() else {
            throw NSError(domain: "StillImageClipFactoryTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create fixture CGImage"])
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillImageClipFactoryTests-\(UUID().uuidString)")
            .appendingPathExtension("jpg")

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "StillImageClipFactoryTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "StillImageClipFactoryTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize fixture image"])
        }

        return outputURL
    }
}
