import AVFoundation
import CoreImage
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import VideoToolbox
#if canImport(AppKit)
import AppKit
#endif

enum MediaDerivedBackgroundStyle {
    struct Metrics {
        let zoomedRenderSize: CGSize
        let downsampledSize: CGSize
        let blurRadius: CGFloat
        let saturation: CGFloat
        let dimMultiplier: CGFloat
    }

    private static let zoomScale: CGFloat = 1.08
    private static let downsampleFactor: CGFloat = 0.25
    private static let blurRadiusFactor: CGFloat = 0.015
    private static let saturationAmount: CGFloat = 0.65
    private static let blackOverlayOpacity: CGFloat = 0.4

    static func metrics(for renderSize: CGSize) -> Metrics {
        let zoomedRenderSize = CGSize(
            width: max(1, ceil(renderSize.width * zoomScale)),
            height: max(1, ceil(renderSize.height * zoomScale))
        )
        let downsampledSize = CGSize(
            width: max(1, CGFloat(Int((renderSize.width * downsampleFactor).rounded()))),
            height: max(1, CGFloat(Int((renderSize.height * downsampleFactor).rounded())))
        )
        return Metrics(
            zoomedRenderSize: zoomedRenderSize,
            downsampledSize: downsampledSize,
            blurRadius: max(downsampledSize.width, downsampledSize.height) * blurRadiusFactor,
            saturation: saturationAmount,
            dimMultiplier: 1 - blackOverlayOpacity
        )
    }
}

public final class StillImageClipFactory {
    private struct IntermediateColorConfiguration {
        let avColorPrimaries: String
        let avTransferFunction: String
        let avYCbCrMatrix: String
        let cvColorPrimaries: CFString
        let cvTransferFunction: CFString
        let cvYCbCrMatrix: CFString
        let cgColorSpace: CGColorSpace
        let pixelFormat: OSType
        let requiresMain10Profile: Bool

        static func bt709() -> IntermediateColorConfiguration {
            IntermediateColorConfiguration(
                avColorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
                avTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
                avYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
                cvColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                cvTransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
                cvYCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                cgColorSpace: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
                pixelFormat: kCVPixelFormatType_32BGRA,
                requiresMain10Profile: false
            )
        }

        static func displayP3() -> IntermediateColorConfiguration {
            IntermediateColorConfiguration(
                avColorPrimaries: AVVideoColorPrimaries_P3_D65,
                avTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
                avYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
                cvColorPrimaries: kCVImageBufferColorPrimaries_P3_D65,
                cvTransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
                cvYCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                cgColorSpace: CGColorSpace(name: CGColorSpace.displayP3)
                    ?? CGColorSpace(name: CGColorSpace.itur_709)
                    ?? CGColorSpaceCreateDeviceRGB(),
                pixelFormat: kCVPixelFormatType_32BGRA,
                requiresMain10Profile: false
            )
        }

        static func hlgBT2020() -> IntermediateColorConfiguration {
            IntermediateColorConfiguration(
                avColorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
                avTransferFunction: AVVideoTransferFunction_ITU_R_2100_HLG,
                avYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020,
                cvColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                cvTransferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                cvYCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                cgColorSpace: CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                    ?? CGColorSpace(name: CGColorSpace.itur_2020)
                    ?? CGColorSpaceCreateDeviceRGB(),
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                requiresMain10Profile: true
            )
        }
    }

    private struct RasterizedImagePayload {
        let image: CIImage
        let colorConfiguration: IntermediateColorConfiguration
    }

    public struct TitleCardPreviewAsset: Equatable, Sendable {
        public let url: URL
        public let mediaType: MediaType
        public let filename: String

        public init(url: URL, mediaType: MediaType, filename: String) {
            self.url = url
            self.mediaType = mediaType
            self.filename = filename
        }
    }

    private struct AnimatedTitleCardPalette {
        let start: CGColor
        let end: CGColor
        let accent: CGColor
    }

    private struct TitleCardPreviewImage {
        let image: CGImage
        let filename: String
    }

    private struct AnimatedTitleCardTile {
        let preview: TitleCardPreviewImage
        let normalizedRect: CGRect
        let baseRotation: CGFloat
        let drift: CGPoint
        let scaleAmplitude: CGFloat
        let opacity: CGFloat
        let delay: CGFloat
        let phase: CGFloat
    }

    private struct AnimatedTitleCardFrameSet {
        let backgroundImage: CGImage?
        let palette: AnimatedTitleCardPalette
        let tiles: [AnimatedTitleCardTile]
        let title: String
        let contextLine: String?
    }

    private struct SeededRandomNumberGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0xA0761D6478BD642F : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }

    public init() {}

    func sourceColorInfo(forImageURL url: URL, dynamicRange: DynamicRange) throws -> ColorInfo {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RenderError.exportFailed("Unable to load image source at \(url.path)")
        }

        let hasHDRGainMap = hasHDRGainMap(imageSource)
        if dynamicRange == .hdr, hasHDRGainMap {
            return ColorInfo(
                isHDR: true,
                colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
                transferFunction: AVVideoTransferFunction_ITU_R_2100_HLG,
                transferFlavor: .hlg,
                hdrMetadataFlavor: .gainMap
            )
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ]
        let decodedImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        let colorConfiguration = intermediateColorConfiguration(
            for: decodedImage?.colorSpace,
            dynamicRange: dynamicRange,
            hasHDRGainMap: hasHDRGainMap
        )
        return colorInfo(
            for: colorConfiguration,
            hdrMetadataFlavor: hasHDRGainMap ? .gainMap : .none
        )
    }

    public func makeVideoClip(
        fromImageURL url: URL,
        duration: CMTime,
        renderSize: CGSize,
        frameRate: Int = 30,
        dynamicRange: DynamicRange = .sdr
    ) async throws -> URL {
        #if canImport(AppKit)
        let payload = try loadRasterizedImage(from: url, renderSize: renderSize, dynamicRange: dynamicRange)
        return try await makeVideoClip(
            fromRasterizedImage: payload.image,
            duration: duration,
            renderSize: renderSize,
            frameRate: frameRate,
            colorConfiguration: payload.colorConfiguration
        )
        #else
        throw RenderError.exportFailed("Image rendering requires AppKit support")
        #endif
    }

    public func makeTitleCardClip(
        title: String,
        duration: CMTime,
        renderSize: CGSize,
        frameRate: Int = 30
    ) async throws -> URL {
        let descriptor = OpeningTitleCardDescriptor(
            title: title,
            contextLine: nil,
            previewItems: [],
            dateSpanText: nil,
            variationSeed: 0,
            contextLineMode: .automatic
        )
        return try await makeTitleCardClip(
            descriptor: descriptor,
            previewAssets: [],
            duration: duration,
            renderSize: renderSize,
            frameRate: frameRate
        )
    }

    public func makeTitleCardClip(
        descriptor: OpeningTitleCardDescriptor,
        previewAssets: [TitleCardPreviewAsset],
        duration: CMTime,
        renderSize: CGSize,
        frameRate: Int = 30
    ) async throws -> URL {
        #if canImport(AppKit)
        let resolvedTitle = descriptor.resolvedTitle
        let displayContextLine = descriptor.displayContextLine

        if !previewAssets.isEmpty {
            do {
                let animatedFrameSet = try await makeAnimatedTitleCardFrameSet(
                    descriptor: descriptor,
                    previewAssets: previewAssets,
                    renderSize: renderSize
                )
                return try await makeVideoClip(
                    duration: duration,
                    renderSize: renderSize,
                    frameRate: frameRate,
                    colorConfiguration: .bt709()
                ) { [animatedFrameSet] frameIndex, totalFrames in
                    let denominator = max(totalFrames - 1, 1)
                    let progress = CGFloat(frameIndex) / CGFloat(denominator)
                    return try self.makeAnimatedTitleCardFrame(
                        frameSet: animatedFrameSet,
                        progress: progress,
                        renderSize: renderSize
                    )
                }
            } catch {
                // Fall back to the static card if previews fail to load or animate.
            }
        }

        let titleImage: CGImage
        do {
            titleImage = try await MainActor.run { [renderSize, resolvedTitle, displayContextLine] in
                try Self.makeStaticTitleCardRasterizedImage(
                    title: resolvedTitle,
                    contextLine: displayContextLine,
                    renderSize: renderSize
                )
            }
        } catch {
            titleImage = try makeFallbackTitleCardImage(
                renderSize: renderSize,
                title: resolvedTitle,
                contextLine: displayContextLine
            )
        }
        return try await makeVideoClip(
            fromRasterizedImage: CIImage(cgImage: titleImage),
            duration: duration,
            renderSize: renderSize,
            frameRate: frameRate,
            colorConfiguration: .bt709()
        )
        #else
        throw RenderError.exportFailed("Title card rendering requires AppKit support")
        #endif
    }

    #if canImport(AppKit)
    private func makeVideoClip(
        fromRasterizedImage image: CIImage,
        duration: CMTime,
        renderSize: CGSize,
        frameRate: Int,
        colorConfiguration: IntermediateColorConfiguration
    ) async throws -> URL {
        try await makeVideoClip(
            duration: duration,
            renderSize: renderSize,
            frameRate: frameRate,
            colorConfiguration: colorConfiguration
        ) { _, _ in
            image
        }
    }

    private func makeVideoClip(
        duration: CMTime,
        renderSize: CGSize,
        frameRate: Int,
        colorConfiguration: IntermediateColorConfiguration,
        imageProvider: (Int, Int) throws -> CIImage
    ) async throws -> URL {
        let totalFrames = max(Int(ceil(duration.seconds * Double(frameRate))), 1)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let outputURL = temporaryClipURL()

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let codec = preferredIntermediateCodec(
            for: renderSize,
            writer: writer,
            colorConfiguration: colorConfiguration
        )
        let settings = writerVideoSettings(
            codec: codec,
            renderSize: renderSize,
            colorConfiguration: colorConfiguration
        )
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        var attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(colorConfiguration.pixelFormat),
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        if colorConfiguration.pixelFormat == kCVPixelFormatType_32BGRA {
            attributes[kCVPixelBufferCGBitmapContextCompatibilityKey as String] = true
            attributes[kCVPixelBufferCGImageCompatibilityKey as String] = true
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else {
            throw RenderError.exportFailed("Failed to add writer input for still image clip")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw RenderError.exportFailed(writer.error?.localizedDescription ?? "Unable to start writing")
        }
        writer.startSession(atSourceTime: .zero)
        let ciContext = CIContext(options: [CIContextOption.cacheIntermediates: false])

        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw RenderError.exportFailed("Still image clip pixel buffer pool unavailable")
            }
            var destinationBuffer: CVPixelBuffer?
            let creationStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationBuffer)
            guard creationStatus == kCVReturnSuccess, let destinationBuffer else {
                throw RenderError.exportFailed("Failed to create pixel buffer")
            }
            let frameImage = try imageProvider(frame, totalFrames)
            render(
                image: frameImage,
                to: destinationBuffer,
                renderSize: renderSize,
                colorConfiguration: colorConfiguration,
                context: ciContext
            )

            let time = CMTimeMultiply(frameDuration, multiplier: Int32(frame))
            guard adaptor.append(destinationBuffer, withPresentationTime: time) else {
                throw RenderError.exportFailed(writer.error?.localizedDescription ?? "Failed to append image frame")
            }
        }

        writer.endSession(atSourceTime: duration)
        input.markAsFinished()
        try await finish(writer: writer)
        return outputURL
    }

    private func preferredIntermediateCodec(
        for renderSize: CGSize,
        writer: AVAssetWriter,
        colorConfiguration: IntermediateColorConfiguration
    ) -> AVVideoCodecType {
        let width = Int(renderSize.width.rounded())
        let height = Int(renderSize.height.rounded())
        let largeFrame = width > 4096 || height > 2304
        let candidates: [AVVideoCodecType]
        if colorConfiguration.requiresMain10Profile {
            candidates = largeFrame ? [.proRes422, .hevc] : [.hevc, .proRes422]
        } else {
            candidates = largeFrame ? [.proRes422, .hevc, .h264] : [.h264, .hevc, .proRes422]
        }

        for candidate in candidates {
            let settings = writerVideoSettings(
                codec: candidate,
                renderSize: CGSize(width: width, height: height),
                colorConfiguration: colorConfiguration
            )
            if writer.canApply(outputSettings: settings, forMediaType: .video) {
                return candidate
            }
        }

        if colorConfiguration.requiresMain10Profile {
            return largeFrame ? .proRes422 : .hevc
        }
        return largeFrame ? .proRes422 : .h264
    }

    private func writerVideoSettings(
        codec: AVVideoCodecType,
        renderSize: CGSize,
        colorConfiguration: IntermediateColorConfiguration
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: colorConfiguration.avColorPrimaries,
                AVVideoTransferFunctionKey: colorConfiguration.avTransferFunction,
                AVVideoYCbCrMatrixKey: colorConfiguration.avYCbCrMatrix
            ]
        ]
        if colorConfiguration.requiresMain10Profile, codec == .hevc {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String
            ]
        }
        return settings
    }

    private func loadRasterizedImage(
        from url: URL,
        renderSize: CGSize,
        dynamicRange: DynamicRange
    ) throws -> RasterizedImagePayload {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RenderError.exportFailed("Unable to load image source at \(url.path)")
        }

        let hasHDRGainMap = hasHDRGainMap(imageSource)
        if dynamicRange == .hdr,
           hasHDRGainMap,
           #available(macOS 15.0, *),
           let hdrImage = makeGainMappedHDRImageIfAvailable(from: imageSource) {
            let outputColorConfiguration = IntermediateColorConfiguration.hlgBT2020()
            let fittedImage = Self.aspectFitImage(
                hdrImage,
                renderSize: renderSize
            )
            return RasterizedImagePayload(image: fittedImage, colorConfiguration: outputColorConfiguration)
        }

        let maxDimension = max(1, Int(max(renderSize.width, renderSize.height).rounded()))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        let decodedImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)

        guard let decodedImage else {
            throw RenderError.exportFailed("Unable to decode image at \(url.path)")
        }

        let colorConfiguration = intermediateColorConfiguration(
            for: decodedImage.colorSpace,
            dynamicRange: dynamicRange,
            hasHDRGainMap: hasHDRGainMap
        )
        let sourceImage = CIImage(cgImage: decodedImage)
        let fittedImage = Self.aspectFitImage(
            sourceImage,
            renderSize: renderSize
        )
        return RasterizedImagePayload(image: fittedImage, colorConfiguration: colorConfiguration)
    }

    private func makeAnimatedTitleCardFrameSet(
        descriptor: OpeningTitleCardDescriptor,
        previewAssets: [TitleCardPreviewAsset],
        renderSize: CGSize
    ) async throws -> AnimatedTitleCardFrameSet {
        let previewImages = try await loadAnimatedPreviewImages(
            from: previewAssets,
            targetDimension: Int(max(renderSize.width, renderSize.height).rounded())
        )
        guard !previewImages.isEmpty else {
            throw RenderError.exportFailed("Animated title card previews unavailable")
        }

        var generator = SeededRandomNumberGenerator(seed: descriptor.variationSeed ^ 0xC6A4A7935BD1E995)
        var shuffledPreviews = previewImages
        shuffledPreviews.shuffle(using: &generator)
        let palette = animatedPalette(using: &generator)

        return AnimatedTitleCardFrameSet(
            backgroundImage: makeBlurredBackgroundImage(from: shuffledPreviews[0].image, renderSize: renderSize),
            palette: palette,
            tiles: makeAnimatedTiles(
                previews: shuffledPreviews,
                renderSize: renderSize,
                generator: &generator
            ),
            title: descriptor.resolvedTitle,
            contextLine: descriptor.displayContextLine
        )
    }

    private func loadAnimatedPreviewImages(
        from previewAssets: [TitleCardPreviewAsset],
        targetDimension: Int
    ) async throws -> [TitleCardPreviewImage] {
        var previews: [TitleCardPreviewImage] = []
        previews.reserveCapacity(previewAssets.count)

        for previewAsset in previewAssets {
            do {
                let image = try await loadPreviewImage(from: previewAsset, targetDimension: targetDimension)
                previews.append(TitleCardPreviewImage(image: image, filename: previewAsset.filename))
            } catch {
                continue
            }
        }

        return previews
    }

    private func loadPreviewImage(
        from previewAsset: TitleCardPreviewAsset,
        targetDimension: Int
    ) async throws -> CGImage {
        switch previewAsset.mediaType {
        case .image:
            return try loadImageThumbnail(from: previewAsset.url, targetDimension: targetDimension)
        case .video:
            return try await loadVideoPosterFrame(from: previewAsset.url, targetDimension: targetDimension)
        }
    }

    private func loadImageThumbnail(from url: URL, targetDimension: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RenderError.exportFailed("Unable to load title preview image at \(url.path)")
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetDimension, 1)
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw RenderError.exportFailed("Unable to decode title preview image at \(url.path)")
        }

        return image
    }

    private func loadVideoPosterFrame(from url: URL, targetDimension: Int) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: targetDimension, height: targetDimension)
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        do {
            return try await imageGenerator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        } catch {
            return try await imageGenerator.image(at: .zero).image
        }
    }

    private func animatedPalette(using generator: inout SeededRandomNumberGenerator) -> AnimatedTitleCardPalette {
        let palettes: [AnimatedTitleCardPalette] = [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.05, green: 0.11, blue: 0.19, alpha: 1.0),
                end: CGColor(red: 0.07, green: 0.05, blue: 0.16, alpha: 1.0),
                accent: CGColor(red: 0.25, green: 0.83, blue: 0.78, alpha: 1.0)
            ),
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.12, green: 0.08, blue: 0.05, alpha: 1.0),
                end: CGColor(red: 0.07, green: 0.06, blue: 0.16, alpha: 1.0),
                accent: CGColor(red: 0.97, green: 0.69, blue: 0.28, alpha: 1.0)
            ),
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.08, green: 0.05, blue: 0.11, alpha: 1.0),
                end: CGColor(red: 0.04, green: 0.10, blue: 0.14, alpha: 1.0),
                accent: CGColor(red: 0.94, green: 0.52, blue: 0.62, alpha: 1.0)
            ),
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.06, green: 0.10, blue: 0.08, alpha: 1.0),
                end: CGColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 1.0),
                accent: CGColor(red: 0.53, green: 0.88, blue: 0.43, alpha: 1.0)
            )
        ]

        return palettes[Int.random(in: 0..<palettes.count, using: &generator)]
    }

    private func makeAnimatedTiles(
        previews: [TitleCardPreviewImage],
        renderSize: CGSize,
        generator: inout SeededRandomNumberGenerator
    ) -> [AnimatedTitleCardTile] {
        let normalizedRects: [CGRect] = [
            CGRect(x: 0.06, y: 0.60, width: 0.24, height: 0.22),
            CGRect(x: 0.30, y: 0.64, width: 0.20, height: 0.18),
            CGRect(x: 0.56, y: 0.58, width: 0.28, height: 0.24),
            CGRect(x: 0.72, y: 0.30, width: 0.18, height: 0.18),
            CGRect(x: 0.50, y: 0.28, width: 0.18, height: 0.16),
            CGRect(x: 0.16, y: 0.26, width: 0.22, height: 0.20)
        ]

        var rects = normalizedRects
        rects.shuffle(using: &generator)
        let maxTiles = min(previews.count, rects.count)

        return Array(previews.prefix(maxTiles).enumerated()).map { index, preview in
            let xDrift = CGFloat.random(in: -(renderSize.width * 0.03)...(renderSize.width * 0.03), using: &generator)
            let yDrift = CGFloat.random(in: -(renderSize.height * 0.025)...(renderSize.height * 0.025), using: &generator)
            let phase = CGFloat.random(in: 0...(CGFloat.pi * 2), using: &generator)

            return AnimatedTitleCardTile(
                preview: preview,
                normalizedRect: rects[index],
                baseRotation: CGFloat.random(in: -7...7, using: &generator),
                drift: CGPoint(x: xDrift, y: yDrift),
                scaleAmplitude: CGFloat.random(in: 0.02...0.05, using: &generator),
                opacity: CGFloat.random(in: 0.78...0.95, using: &generator),
                delay: CGFloat(index) * 0.06,
                phase: phase
            )
        }
    }

    private func makeAnimatedTitleCardFrame(
        frameSet: AnimatedTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize
    ) throws -> CIImage {
        let width = max(1, Int(renderSize.width.rounded()))
        let height = max(1, Int(renderSize.height.rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: IntermediateColorConfiguration.bt709().cgColorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw RenderError.exportFailed("Unable to allocate animated title card frame")
        }

        let fullRect = CGRect(origin: .zero, size: renderSize)
        context.setFillColor(frameSet.palette.start)
        context.fill(fullRect)

        if let backgroundImage = frameSet.backgroundImage {
            let baseRect = Self.aspectFillRect(
                imageSize: CGSize(width: backgroundImage.width, height: backgroundImage.height),
                into: renderSize
            )
            let zoom = 1.04 + 0.03 * sin(progress * .pi * 2)
            let backgroundRect = scaled(rect: baseRect, scale: zoom)

            context.saveGState()
            context.setAlpha(0.36)
            context.draw(backgroundImage, in: backgroundRect)
            context.restoreGState()
        }

        drawFullCanvasGradient(
            colors: [
                frameSet.palette.start.copy(alpha: 0.18) ?? frameSet.palette.start,
                frameSet.palette.end.copy(alpha: 0.82) ?? frameSet.palette.end
            ],
            start: CGPoint(x: 0, y: renderSize.height),
            end: CGPoint(x: renderSize.width, y: 0),
            context: context,
            rect: fullRect
        )

        for tile in frameSet.tiles {
            drawAnimatedTile(tile, progress: progress, renderSize: renderSize, context: context, accentColor: frameSet.palette.accent)
        }

        drawTitleBackdrop(renderSize: renderSize, context: context)
        drawTitleBlock(
            title: frameSet.title,
            contextLine: frameSet.contextLine,
            accentColor: frameSet.palette.accent,
            renderSize: renderSize,
            context: context
        )

        guard let image = context.makeImage() else {
            throw RenderError.exportFailed("Unable to create animated title card frame")
        }

        return CIImage(cgImage: image)
    }

    private func drawAnimatedTile(
        _ tile: AnimatedTitleCardTile,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext,
        accentColor: CGColor
    ) {
        var rect = CGRect(
            x: tile.normalizedRect.minX * renderSize.width,
            y: tile.normalizedRect.minY * renderSize.height,
            width: tile.normalizedRect.width * renderSize.width,
            height: tile.normalizedRect.height * renderSize.height
        )

        let easedProgress = max(0, min(1, (progress - tile.delay) / max(1 - tile.delay, 0.2)))
        let oscillation = sin((progress + tile.phase) * .pi * 2)
        rect.origin.x += tile.drift.x * oscillation
        rect.origin.y += tile.drift.y * cos((progress + tile.phase) * .pi * 2)
        rect = scaled(rect: rect, scale: 1.0 + (tile.scaleAmplitude * easedProgress))

        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: tile.baseRotation * (.pi / 180))
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.setAlpha(tile.opacity * min(max(easedProgress * 1.3, 0.15), 1))
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: max(rect.width * 0.035, 12), color: CGColor(gray: 0, alpha: 0.35))

        let clipPath = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.06, cornerHeight: rect.width * 0.06, transform: nil)
        context.addPath(clipPath)
        context.clip()
        let imageRect = Self.aspectFillRect(
            imageSize: CGSize(width: tile.preview.image.width, height: tile.preview.image.height),
            into: rect.size
        ).offsetBy(dx: rect.minX, dy: rect.minY)
        context.draw(tile.preview.image, in: imageRect)
        context.restoreGState()

        context.saveGState()
        let strokePath = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.06, cornerHeight: rect.width * 0.06, transform: nil)
        context.addPath(strokePath)
        context.setStrokeColor(accentColor.copy(alpha: 0.28) ?? accentColor)
        context.setLineWidth(max(rect.width * 0.006, 2))
        context.strokePath()
        context.restoreGState()
    }

    private func drawTitleBackdrop(renderSize: CGSize, context: CGContext) {
        let rect = CGRect(
            x: renderSize.width * 0.04,
            y: renderSize.height * 0.07,
            width: renderSize.width * 0.54,
            height: renderSize.height * 0.30
        )

        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 0.28))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    private func drawTitleBlock(
        title: String,
        contextLine: String?,
        accentColor: CGColor,
        renderSize: CGSize,
        context: CGContext
    ) {
        let originX = renderSize.width * 0.08
        let lineY = renderSize.height * 0.30
        let titleRect = CGRect(
            x: originX,
            y: renderSize.height * 0.12,
            width: renderSize.width * 0.48,
            height: renderSize.height * 0.18
        )
        let contextRect = CGRect(
            x: originX,
            y: renderSize.height * 0.31,
            width: renderSize.width * 0.44,
            height: renderSize.height * 0.05
        )

        context.saveGState()
        context.setFillColor(accentColor)
        context.fill(CGRect(x: originX, y: lineY, width: max(renderSize.width * 0.11, 96), height: max(renderSize.height * 0.008, 6)))
        context.restoreGState()

        if let contextLine, !contextLine.isEmpty {
            let contextStyle = paragraphStyle(alignment: .left, lineBreakMode: .byTruncatingTail)
            let contextAttributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): CTFontCreateWithName("AvenirNext-DemiBold" as CFString, max(renderSize.width * 0.02, 18), nil),
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.85),
                NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): contextStyle,
                NSAttributedString.Key(rawValue: kCTKernAttributeName as String): 1.6
            ]
            drawAttributedString(
                NSAttributedString(string: contextLine, attributes: contextAttributes),
                in: contextRect,
                context: context
            )
        }

        let titleStyle = paragraphStyle(alignment: .left, lineBreakMode: .byWordWrapping)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): CTFontCreateWithName("AvenirNext-Bold" as CFString, max(renderSize.width * 0.055, 42), nil),
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.98),
            NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): titleStyle
        ]
        drawAttributedString(
            NSAttributedString(string: title, attributes: titleAttributes),
            in: titleRect,
            context: context
        )
    }

    private func drawAttributedString(
        _ attributedString: NSAttributedString,
        in rect: CGRect,
        context: CGContext
    ) {
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString as CFAttributedString)
        let path = CGMutablePath()
        path.addRect(rect)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributedString.length), path, nil)
        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func paragraphStyle(alignment: CTTextAlignment, lineBreakMode: CTLineBreakMode) -> CTParagraphStyle {
        var alignmentValue = alignment
        var lineBreakValue = lineBreakMode
        return withUnsafePointer(to: &alignmentValue) { alignmentPointer in
            withUnsafePointer(to: &lineBreakValue) { lineBreakPointer in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineBreakMode,
                        valueSize: MemoryLayout<CTLineBreakMode>.size,
                        value: lineBreakPointer
                    )
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    private func drawFullCanvasGradient(
        colors: [CGColor],
        start: CGPoint,
        end: CGPoint,
        context: CGContext,
        rect: CGRect
    ) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1]) else {
            return
        }

        context.saveGState()
        context.addRect(rect)
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }

    private func makeBlurredBackgroundImage(from image: CGImage, renderSize: CGSize) -> CGImage? {
        let canvasRect = CGRect(origin: .zero, size: renderSize)
        let baseImage = CIImage(cgImage: image)
        let backgroundImage = Self.aspectFillImage(baseImage, renderSize: renderSize)
        let clamped = backgroundImage.clampedToExtent()
        let blurred = clamped.applyingFilter(
            "CIGaussianBlur",
            parameters: [kCIInputRadiusKey: max(renderSize.width, renderSize.height) * 0.015]
        ).cropped(to: canvasRect)

        let context = CIContext(options: [CIContextOption.cacheIntermediates: false])
        return context.createCGImage(
            blurred,
            from: canvasRect,
            format: .RGBA8,
            colorSpace: IntermediateColorConfiguration.bt709().cgColorSpace
        )
    }

    @MainActor
    private static func makeStaticTitleCardRasterizedImage(
        title: String,
        contextLine: String?,
        renderSize: CGSize
    ) throws -> CGImage {
        let size = NSSize(width: renderSize.width, height: renderSize.height)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        let background = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
        background.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        if let contextLine, !contextLine.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let contextAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(renderSize.width * 0.018, 16), weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.78),
                .paragraphStyle: paragraph
            ]
            let attributedContext = NSAttributedString(string: contextLine, attributes: contextAttributes)
            let contextRect = NSRect(x: renderSize.width * 0.14, y: renderSize.height * 0.56, width: renderSize.width * 0.72, height: renderSize.height * 0.05)
            attributedContext.draw(in: contextRect)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(renderSize.width * 0.05, 42), weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]

        let attributed = NSAttributedString(string: title, attributes: attributes)
        let textRect = NSRect(x: renderSize.width * 0.1, y: renderSize.height * 0.38, width: renderSize.width * 0.8, height: renderSize.height * 0.2)
        attributed.draw(in: textRect)

        var proposedRect = CGRect(origin: .zero, size: size)
        guard let rawImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              let safeImage = Self.rasterizedImage(rawImage, renderSize: renderSize, colorSpace: IntermediateColorConfiguration.bt709().cgColorSpace) else {
            throw RenderError.exportFailed("Unable to create title card image")
        }

        return safeImage
    }

    private func makeFallbackTitleCardImage(
        renderSize: CGSize,
        title: String,
        contextLine: String?
    ) throws -> CGImage {
        let width = max(1, Int(renderSize.width.rounded()))
        let height = max(1, Int(renderSize.height.rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: IntermediateColorConfiguration.bt709().cgColorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw RenderError.exportFailed("Unable to create fallback title card image at \(width)x\(height)")
        }

        context.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        drawFallbackTitle(
            text: resolvedFallbackTitleText(from: title),
            contextLine: contextLine,
            context: context,
            renderSize: CGSize(width: width, height: height)
        )

        guard let image = context.makeImage() else {
            throw RenderError.exportFailed("Unable to finalize fallback title card image at \(width)x\(height)")
        }
        return image
    }

    private func resolvedFallbackTitleText(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Monthly Video" : trimmed
    }

    private func drawFallbackTitle(
        text: String,
        contextLine: String?,
        context: CGContext,
        renderSize: CGSize
    ) {
        if let contextLine = contextLine?.trimmingCharacters(in: .whitespacesAndNewlines), !contextLine.isEmpty {
            let contextFont = CTFontCreateWithName("Helvetica" as CFString, max(renderSize.width * 0.02, 18), nil)
            let contextAttributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): contextFont,
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 0.78)
            ]
            let attributedContext = NSAttributedString(string: contextLine, attributes: contextAttributes)
            let contextLineRef = CTLineCreateWithAttributedString(attributedContext as CFAttributedString)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let contextWidth = CGFloat(CTLineGetTypographicBounds(contextLineRef, &ascent, &descent, &leading))
            let contextPosition = CGPoint(
                x: max((renderSize.width - contextWidth) / 2, renderSize.width * 0.1),
                y: renderSize.height * 0.57
            )
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = contextPosition
            CTLineDraw(contextLineRef, context)
            context.restoreGState()
        }

        let fontSize = max(renderSize.width * 0.05, 42)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]

        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textHeight = ascent + descent + leading
        let textPosition = CGPoint(
            x: max((renderSize.width - textWidth) / 2, renderSize.width * 0.1),
            y: max((renderSize.height - textHeight) / 2, renderSize.height * 0.35)
        )

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = textPosition
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func rasterizedImage(_ sourceImage: CGImage, renderSize: CGSize, colorSpace: CGColorSpace) -> CGImage? {
        let width = max(1, Int(renderSize.width.rounded()))
        let height = max(1, Int(renderSize.height.rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high

        let fittedRect = Self.aspectFitRect(
            imageSize: CGSize(width: sourceImage.width, height: sourceImage.height),
            into: CGSize(width: width, height: height)
        )
        context.draw(sourceImage, in: fittedRect)

        return context.makeImage()
    }

    private static func aspectFitImage(
        _ sourceImage: CIImage,
        renderSize: CGSize
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: renderSize)
        let normalized = normalizedImage(sourceImage)
        guard normalized.extent.width > 0, normalized.extent.height > 0 else {
            return CIImage(color: .black).cropped(to: canvasRect)
        }

        let fittedRect = aspectFitRect(imageSize: normalized.extent.size, into: renderSize)
        let scaleX = fittedRect.width / normalized.extent.width
        let scaleY = fittedRect.height / normalized.extent.height
        let transformed = normalized
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: fittedRect.minX, y: fittedRect.minY))
        let background = mediaDerivedBackgroundImage(fromNormalizedImage: normalized, renderSize: renderSize)
        let composed = transformed.composited(over: background).cropped(to: canvasRect)
        return composed
    }

    private static func aspectFillImage(
        _ sourceImage: CIImage,
        renderSize: CGSize
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: renderSize)
        let normalized = normalizedImage(sourceImage)
        guard normalized.extent.width > 0, normalized.extent.height > 0 else {
            return CIImage(color: .black).cropped(to: canvasRect)
        }

        let filledRect = aspectFillRect(imageSize: normalized.extent.size, into: renderSize)
        let scaleX = filledRect.width / normalized.extent.width
        let scaleY = filledRect.height / normalized.extent.height
        return normalized
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: filledRect.minX, y: filledRect.minY))
            .cropped(to: canvasRect)
    }

    private static func normalizedImage(_ sourceImage: CIImage) -> CIImage {
        sourceImage.transformed(
            by: CGAffineTransform(
                translationX: -sourceImage.extent.minX,
                y: -sourceImage.extent.minY
            )
        )
    }

    private static func mediaDerivedBackgroundImage(
        fromNormalizedImage normalizedImage: CIImage,
        renderSize: CGSize
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: renderSize)
        let metrics = MediaDerivedBackgroundStyle.metrics(for: renderSize)
        let downsampleRect = CGRect(origin: .zero, size: metrics.downsampledSize)
        let zoomedBackground = aspectFillImage(normalizedImage, renderSize: metrics.zoomedRenderSize)
        let downsampleScaleX = metrics.downsampledSize.width / metrics.zoomedRenderSize.width
        let downsampleScaleY = metrics.downsampledSize.height / metrics.zoomedRenderSize.height
        let downsampled = zoomedBackground
            .transformed(by: CGAffineTransform(scaleX: downsampleScaleX, y: downsampleScaleY))
            .cropped(to: downsampleRect)
        let blurred = downsampled.clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: metrics.blurRadius]
            )
            .cropped(to: downsampleRect)
        let desaturated = blurred.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputSaturationKey: metrics.saturation]
        )
        let dimmed = desaturated.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: metrics.dimMultiplier, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: metrics.dimMultiplier, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: metrics.dimMultiplier, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ]
        )
        let upsampleScaleX = renderSize.width / metrics.downsampledSize.width
        let upsampleScaleY = renderSize.height / metrics.downsampledSize.height
        return dimmed
            .transformed(by: CGAffineTransform(scaleX: upsampleScaleX, y: upsampleScaleY))
            .cropped(to: canvasRect)
    }

    private func render(
        image: CIImage,
        to destinationBuffer: CVPixelBuffer,
        renderSize: CGSize,
        colorConfiguration: IntermediateColorConfiguration,
        context: CIContext
    ) {
        CVBufferSetAttachment(destinationBuffer, kCVImageBufferColorPrimariesKey, colorConfiguration.cvColorPrimaries, .shouldPropagate)
        CVBufferSetAttachment(destinationBuffer, kCVImageBufferTransferFunctionKey, colorConfiguration.cvTransferFunction, .shouldPropagate)
        CVBufferSetAttachment(destinationBuffer, kCVImageBufferYCbCrMatrixKey, colorConfiguration.cvYCbCrMatrix, .shouldPropagate)
        CVBufferSetAttachment(destinationBuffer, kCVImageBufferCGColorSpaceKey, colorConfiguration.cgColorSpace, .shouldPropagate)
        context.render(
            image,
            to: destinationBuffer,
            bounds: CGRect(origin: .zero, size: renderSize),
            colorSpace: colorConfiguration.cgColorSpace
        )
    }

    private func intermediateColorConfiguration(
        for colorSpace: CGColorSpace?,
        dynamicRange: DynamicRange,
        hasHDRGainMap: Bool
    ) -> IntermediateColorConfiguration {
        if dynamicRange == .hdr {
            if hasHDRGainMap {
                return .hlgBT2020()
            }
            if let colorSpaceName = colorSpace?.name,
               colorSpaceName == CGColorSpace.itur_2100_HLG ||
               colorSpaceName == CGColorSpace.itur_2100_PQ ||
               colorSpaceName == CGColorSpace.itur_2020 {
                return .hlgBT2020()
            }
        }

        guard let name = colorSpace?.name else {
            return .bt709()
        }

        if name == CGColorSpace.displayP3 ||
            name == CGColorSpace.extendedDisplayP3 ||
            name == CGColorSpace.extendedLinearDisplayP3 ||
            name == CGColorSpace.dcip3 {
            return .displayP3()
        }
        if let colorSpace, colorSpace.isWideGamutRGB {
            return .displayP3()
        }

        return .bt709()
    }

    private func colorInfo(
        for colorConfiguration: IntermediateColorConfiguration,
        hdrMetadataFlavor: HDRMetadataFlavor
    ) -> ColorInfo {
        switch colorConfiguration.avTransferFunction {
        case AVVideoTransferFunction_ITU_R_2100_HLG:
            return ColorInfo(
                isHDR: true,
                colorPrimaries: colorConfiguration.avColorPrimaries,
                transferFunction: colorConfiguration.avTransferFunction,
                transferFlavor: .hlg,
                hdrMetadataFlavor: hdrMetadataFlavor
            )
        case AVVideoTransferFunction_SMPTE_ST_2084_PQ:
            return ColorInfo(
                isHDR: true,
                colorPrimaries: colorConfiguration.avColorPrimaries,
                transferFunction: colorConfiguration.avTransferFunction,
                transferFlavor: .pq,
                hdrMetadataFlavor: hdrMetadataFlavor
            )
        default:
            return ColorInfo(
                isHDR: false,
                colorPrimaries: colorConfiguration.avColorPrimaries,
                transferFunction: colorConfiguration.avTransferFunction,
                transferFlavor: .sdr,
                hdrMetadataFlavor: hdrMetadataFlavor
            )
        }
    }

    private func hasHDRGainMap(_ imageSource: CGImageSource) -> Bool {
        if #available(macOS 15.0, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            return true
        }

        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            return true
        }

        return false
    }

    @available(macOS 15.0, *)
    private func makeGainMappedHDRImageIfAvailable(from imageSource: CGImageSource) -> CIImage? {
        guard hasHDRGainMap(imageSource) else {
            return nil
        }

        let sourceImage = CIImage(
            cgImageSource: imageSource,
            index: 0,
            options: [.applyOrientationProperty: true]
        )
        let gainMap = CIImage(
            cgImageSource: imageSource,
            index: 0,
            options: [.auxiliaryHDRGainMap: true]
        )
        return sourceImage.applyingGainMap(gainMap)
    }

    private func finish(writer: AVAssetWriter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = writer.error {
                    continuation.resume(throwing: RenderError.exportFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func aspectFitRect(imageSize: CGSize, into canvas: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }

        let widthRatio = canvas.width / imageSize.width
        let heightRatio = canvas.height / imageSize.height
        let scale = min(widthRatio, heightRatio)

        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (canvas.width - width) / 2
        let y = (canvas.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func aspectFillRect(imageSize: CGSize, into canvas: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }

        let widthRatio = canvas.width / imageSize.width
        let heightRatio = canvas.height / imageSize.height
        let scale = max(widthRatio, heightRatio)

        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (canvas.width - width) / 2
        let y = (canvas.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func scaled(rect: CGRect, scale: CGFloat) -> CGRect {
        let width = rect.width * scale
        let height = rect.height * scale
        return CGRect(
            x: rect.midX - (width / 2),
            y: rect.midY - (height / 2),
            width: width,
            height: height
        )
    }

    private func temporaryClipURL() -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("MonthlyVideoGenerator", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }
    #endif
}
