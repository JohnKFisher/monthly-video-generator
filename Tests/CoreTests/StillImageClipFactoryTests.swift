import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Core

final class StillImageClipFactoryTests: XCTestCase {
    private struct PixelSample: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        var brightnessSum: Int {
            Int(red) + Int(green) + Int(blue)
        }
    }

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

    func testTitleCardClipUsesRequestedFrameRate() async throws {
        let factory = StillImageClipFactory()
        let clipURL = try await factory.makeTitleCardClip(
            title: "60 fps",
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720),
            frameRate: 60
        )

        defer {
            try? FileManager.default.removeItem(at: clipURL)
        }

        let asset = AVURLAsset(url: clipURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            XCTFail("Expected generated clip to contain a video track")
            return
        }

        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        XCTAssertGreaterThanOrEqual(Double(nominalFrameRate), 50)
    }

    func testPortraitStillUsesMediaDerivedBackgroundInsteadOfBlackBars() async throws {
        let factory = StillImageClipFactory()
        let imageURL = try makePortraitFixtureImage()
        let clipURL = try await factory.makeVideoClip(
            fromImageURL: imageURL,
            duration: CMTime(seconds: 0.75, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720)
        )

        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: clipURL)
        }

        let frame = try await renderedFrame(from: clipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let leftBarSample = samplePixel(in: frame, x: 40, y: frame.height / 2)
        let centerSample = samplePixel(in: frame, x: frame.width / 2, y: frame.height / 2)

        XCTAssertGreaterThan(leftBarSample.brightnessSum, 20)
        XCTAssertGreaterThan(centerSample.red, 180)
        XCTAssertGreaterThan(centerSample.green, 150)
        XCTAssertLessThan(centerSample.blue, 120)
        XCTAssertGreaterThan(centerSample.brightnessSum, leftBarSample.brightnessSum + 150)
    }

    func testCustomTitleCardCaptionPreservesTypedCase() async throws {
        let factory = StillImageClipFactory()
        let automaticDescriptor = OpeningTitleCardDescriptor(
            title: "Summer 2026",
            contextLine: "Cape Cod",
            previewItems: [],
            dateSpanText: nil,
            variationSeed: 1,
            contextLineMode: .automatic
        )
        let customDescriptor = OpeningTitleCardDescriptor(
            title: "Summer 2026",
            contextLine: "Cape Cod",
            previewItems: [],
            dateSpanText: nil,
            variationSeed: 1,
            contextLineMode: .custom
        )

        let automaticClipURL = try await factory.makeTitleCardClip(
            descriptor: automaticDescriptor,
            previewAssets: [],
            duration: CMTime(seconds: 0.75, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720)
        )
        let customClipURL = try await factory.makeTitleCardClip(
            descriptor: customDescriptor,
            previewAssets: [],
            duration: CMTime(seconds: 0.75, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720)
        )

        defer {
            try? FileManager.default.removeItem(at: automaticClipURL)
            try? FileManager.default.removeItem(at: customClipURL)
        }

        let automaticFrame = try await renderedFrame(from: automaticClipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let customFrame = try await renderedFrame(from: customClipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))

        XCTAssertNotEqual(pixelChecksum(automaticFrame), pixelChecksum(customFrame))
    }

    func testAutomaticTitleCardCaptionStillUsesUppercaseTreatment() async throws {
        let factory = StillImageClipFactory()
        let automaticDescriptor = OpeningTitleCardDescriptor(
            title: "Summer 2026",
            contextLine: "Cape Cod",
            previewItems: [],
            dateSpanText: nil,
            variationSeed: 2,
            contextLineMode: .automatic
        )
        let uppercaseCustomDescriptor = OpeningTitleCardDescriptor(
            title: "Summer 2026",
            contextLine: "CAPE COD",
            previewItems: [],
            dateSpanText: nil,
            variationSeed: 2,
            contextLineMode: .custom
        )

        let automaticClipURL = try await factory.makeTitleCardClip(
            descriptor: automaticDescriptor,
            previewAssets: [],
            duration: CMTime(seconds: 0.75, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720)
        )
        let customClipURL = try await factory.makeTitleCardClip(
            descriptor: uppercaseCustomDescriptor,
            previewAssets: [],
            duration: CMTime(seconds: 0.75, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720)
        )

        defer {
            try? FileManager.default.removeItem(at: automaticClipURL)
            try? FileManager.default.removeItem(at: customClipURL)
        }

        let automaticFrame = try await renderedFrame(from: automaticClipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let customFrame = try await renderedFrame(from: customClipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))

        XCTAssertEqual(pixelChecksum(automaticFrame), pixelChecksum(customFrame))
    }

    func testBlankCustomTitleCardCaptionProducesNoSmallCaption() async throws {
        let factory = StillImageClipFactory()
        let blankCustomDescriptor = OpeningTitleCardDescriptor(
            title: "Summer 2026",
            contextLine: "   ",
            previewItems: [],
            dateSpanText: nil,
            variationSeed: 3,
            contextLineMode: .custom
        )
        let noCaptionDescriptor = OpeningTitleCardDescriptor(
            title: "Summer 2026",
            contextLine: nil,
            previewItems: [],
            dateSpanText: nil,
            variationSeed: 3,
            contextLineMode: .custom
        )

        let blankClipURL = try await factory.makeTitleCardClip(
            descriptor: blankCustomDescriptor,
            previewAssets: [],
            duration: CMTime(seconds: 0.75, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720)
        )
        let noCaptionClipURL = try await factory.makeTitleCardClip(
            descriptor: noCaptionDescriptor,
            previewAssets: [],
            duration: CMTime(seconds: 0.75, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720)
        )

        defer {
            try? FileManager.default.removeItem(at: blankClipURL)
            try? FileManager.default.removeItem(at: noCaptionClipURL)
        }

        let blankFrame = try await renderedFrame(from: blankClipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let noCaptionFrame = try await renderedFrame(from: noCaptionClipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))

        XCTAssertEqual(pixelChecksum(blankFrame), pixelChecksum(noCaptionFrame))
    }

    func testAnimatedTitleCardClipMatchesRequestedRenderSize() async throws {
        let factory = StillImageClipFactory()
        let previewURL = try makeFixtureImage()
        let descriptor = OpeningTitleCardDescriptor(
            title: "Animated",
            contextLine: "Cape Cod",
            previewItems: [],
            dateSpanText: "June 2026",
            variationSeed: 123
        )
        let previewAssets = [
            StillImageClipFactory.TitleCardPreviewAsset(url: previewURL, mediaType: .image, filename: "preview-a.jpg"),
            StillImageClipFactory.TitleCardPreviewAsset(url: previewURL, mediaType: .image, filename: "preview-b.jpg"),
            StillImageClipFactory.TitleCardPreviewAsset(url: previewURL, mediaType: .image, filename: "preview-c.jpg")
        ]

        let clipURL = try await factory.makeTitleCardClip(
            descriptor: descriptor,
            previewAssets: previewAssets,
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720)
        )

        defer {
            try? FileManager.default.removeItem(at: previewURL)
            try? FileManager.default.removeItem(at: clipURL)
        }

        let videoSize = try await loadedVideoSize(url: clipURL)
        XCTAssertEqual(videoSize.width, 1280, accuracy: 0.001)
        XCTAssertEqual(videoSize.height, 720, accuracy: 0.001)
    }

    func testAnimatedTitleCardClipIsNotStaticAcrossFrames() async throws {
        let factory = StillImageClipFactory()
        let previewURL = try makeFixtureImage()
        let descriptor = OpeningTitleCardDescriptor(
            title: "Animated",
            contextLine: "Cape Cod",
            previewItems: [],
            dateSpanText: "June 2026",
            variationSeed: 456
        )
        let previewAssets = [
            StillImageClipFactory.TitleCardPreviewAsset(url: previewURL, mediaType: .image, filename: "preview-a.jpg"),
            StillImageClipFactory.TitleCardPreviewAsset(url: previewURL, mediaType: .image, filename: "preview-b.jpg"),
            StillImageClipFactory.TitleCardPreviewAsset(url: previewURL, mediaType: .image, filename: "preview-c.jpg"),
            StillImageClipFactory.TitleCardPreviewAsset(url: previewURL, mediaType: .image, filename: "preview-d.jpg")
        ]

        let clipURL = try await factory.makeTitleCardClip(
            descriptor: descriptor,
            previewAssets: previewAssets,
            duration: CMTime(seconds: 1.5, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720),
            frameRate: 30
        )

        defer {
            try? FileManager.default.removeItem(at: previewURL)
            try? FileManager.default.removeItem(at: clipURL)
        }

        let firstFrame = try await renderedFrame(from: clipURL, at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let laterFrame = try await renderedFrame(from: clipURL, at: CMTime(seconds: 1.1, preferredTimescale: 600))

        XCTAssertNotEqual(pixelChecksum(firstFrame), pixelChecksum(laterFrame))
    }

    func testAnimatedTitleCardFallsBackWhenPreviewCannotBeLoaded() async throws {
        let factory = StillImageClipFactory()
        let descriptor = OpeningTitleCardDescriptor(
            title: "Fallback",
            contextLine: "Cape Cod",
            previewItems: [],
            dateSpanText: "June 2026",
            variationSeed: 789
        )
        let missingPreviewURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-preview-\(UUID().uuidString)")
            .appendingPathExtension("jpg")

        let clipURL = try await factory.makeTitleCardClip(
            descriptor: descriptor,
            previewAssets: [StillImageClipFactory.TitleCardPreviewAsset(url: missingPreviewURL, mediaType: .image, filename: "missing.jpg")],
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720)
        )

        defer {
            try? FileManager.default.removeItem(at: clipURL)
        }

        let videoSize = try await loadedVideoSize(url: clipURL)
        XCTAssertEqual(videoSize.width, 1280, accuracy: 0.001)
        XCTAssertEqual(videoSize.height, 720, accuracy: 0.001)
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

    private func renderedFrame(from url: URL, at time: CMTime) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        return try await generator.image(at: time).image
    }

    private func pixelChecksum(_ image: CGImage) -> UInt64 {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return 0
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else {
            return 0
        }

        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var checksum = UInt64(1469598103934665603)
        let sampleStride = max(((width * height) / 256) * 4, 4)
        var index = 0
        while index < width * height * 4 {
            checksum ^= UInt64(bytes[index])
            checksum &*= 1099511628211
            index += sampleStride
        }
        return checksum
    }

    private func samplePixel(in image: CGImage, x: Int, y: Int) -> PixelSample {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return PixelSample(red: 0, green: 0, blue: 0, alpha: 0)
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else {
            return PixelSample(red: 0, green: 0, blue: 0, alpha: 0)
        }

        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let index = (clampedY * width + clampedX) * 4
        return PixelSample(
            red: bytes[index + 2],
            green: bytes[index + 1],
            blue: bytes[index],
            alpha: bytes[index + 3]
        )
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

    private func makePortraitFixtureImage() throws -> URL {
        let width = 720
        let height = 1280
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw NSError(domain: "StillImageClipFactoryTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate portrait fixture image context"])
        }

        context.setFillColor(CGColor(red: 0.10, green: 0.14, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.94, green: 0.79, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 160, y: 420, width: 400, height: 440))

        guard let image = context.makeImage() else {
            throw NSError(domain: "StillImageClipFactoryTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to create portrait fixture CGImage"])
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillImageClipFactoryTests-Portrait-\(UUID().uuidString)")
            .appendingPathExtension("png")

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "StillImageClipFactoryTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to create portrait image destination"])
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "StillImageClipFactoryTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize portrait fixture image"])
        }

        return outputURL
    }
}
