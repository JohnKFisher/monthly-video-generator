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

private extension StillImageClipFactory.AnimatedCollageMotionProfile {
    func with(
        driftX: CGFloat? = nil,
        driftY: CGFloat? = nil,
        rotationMultiplier: CGFloat? = nil,
        scaleAmplitudeMultiplier: CGFloat? = nil,
        staggerStep: CGFloat? = nil,
        entranceFloor: CGFloat? = nil,
        parallaxX: CGFloat? = nil,
        parallaxY: CGFloat? = nil,
        backgroundZoomBase: CGFloat? = nil,
        backgroundZoomAmplitude: CGFloat? = nil,
        backgroundCycles: CGFloat? = nil,
        centerAttraction: CGFloat? = nil,
        orbitDegrees: CGFloat? = nil,
        bounceStrength: CGFloat? = nil
    ) -> StillImageClipFactory.AnimatedCollageMotionProfile {
        .init(
            backgroundZoomBase: backgroundZoomBase ?? self.backgroundZoomBase,
            backgroundZoomAmplitude: backgroundZoomAmplitude ?? self.backgroundZoomAmplitude,
            backgroundCycles: backgroundCycles ?? self.backgroundCycles,
            driftScaleX: driftX ?? self.driftScaleX,
            driftScaleY: driftY ?? self.driftScaleY,
            rotationMultiplier: rotationMultiplier ?? self.rotationMultiplier,
            scaleAmplitudeMultiplier: scaleAmplitudeMultiplier ?? self.scaleAmplitudeMultiplier,
            staggerStep: staggerStep ?? self.staggerStep,
            entranceFloor: entranceFloor ?? self.entranceFloor,
            parallaxOffsetX: parallaxX ?? self.parallaxOffsetX,
            parallaxOffsetY: parallaxY ?? self.parallaxOffsetY,
            centerAttraction: centerAttraction ?? self.centerAttraction,
            orbitDegrees: orbitDegrees ?? self.orbitDegrees,
            bounceStrength: bounceStrength ?? self.bounceStrength
        )
    }
}

private extension StillImageClipFactory.AnimatedCollageLightingStyle {
    func with(
        backgroundAlpha: CGFloat? = nil,
        vignetteAlpha: CGFloat? = nil,
        overlayGradientAlpha: CGFloat? = nil,
        bloomAlpha: CGFloat? = nil,
        edgeGlowAlpha: CGFloat? = nil,
        lightLeakAlpha: CGFloat? = nil,
        reflectionAlpha: CGFloat? = nil,
        ghostOffset: CGFloat? = nil,
        dustAlpha: CGFloat? = nil
    ) -> StillImageClipFactory.AnimatedCollageLightingStyle {
        .init(
            backgroundAlpha: backgroundAlpha ?? self.backgroundAlpha,
            vignetteAlpha: vignetteAlpha ?? self.vignetteAlpha,
            overlayGradientAlpha: overlayGradientAlpha ?? self.overlayGradientAlpha,
            bloomAlpha: bloomAlpha ?? self.bloomAlpha,
            edgeGlowAlpha: edgeGlowAlpha ?? self.edgeGlowAlpha,
            lightLeakAlpha: lightLeakAlpha ?? self.lightLeakAlpha,
            reflectionAlpha: reflectionAlpha ?? self.reflectionAlpha,
            ghostOffset: ghostOffset ?? self.ghostOffset,
            dustAlpha: dustAlpha ?? self.dustAlpha
        )
    }
}

public final class StillImageClipFactory: @unchecked Sendable {
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
                avTransferFunction: AVVideoTransferFunction_IEC_sRGB,
                avYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
                cvColorPrimaries: kCVImageBufferColorPrimaries_P3_D65,
                cvTransferFunction: kCVImageBufferTransferFunction_sRGB,
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

    package final class TitleCardPreviewRenderer {
        private let renderImage: (CGFloat) throws -> CGImage

        fileprivate init(renderImage: @escaping (CGFloat) throws -> CGImage) {
            self.renderImage = renderImage
        }

        package func render(progress: CGFloat) throws -> CGImage {
            try renderImage(min(max(progress, 0), 1))
        }
    }

    fileprivate struct AnimatedTitleCardPalette {
        let start: CGColor
        let end: CGColor
        let accent: CGColor
        let secondaryAccent: CGColor
        let text: CGColor
        let panel: CGColor
        let highlight: CGColor

        init(
            start: CGColor,
            end: CGColor,
            accent: CGColor,
            secondaryAccent: CGColor? = nil,
            text: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.98),
            panel: CGColor = CGColor(gray: 0, alpha: 0.28),
            highlight: CGColor? = nil
        ) {
            self.start = start
            self.end = end
            self.accent = accent
            self.secondaryAccent = secondaryAccent ?? accent
            self.text = text
            self.panel = panel
            self.highlight = highlight ?? CGColor(red: 1, green: 1, blue: 1, alpha: 0.22)
        }
    }

    fileprivate enum AnimatedCollageTileShape {
        case rounded
        case framed
        case cutout
    }

    fileprivate struct AnimatedCollageMotionProfile {
        let backgroundZoomBase: CGFloat
        let backgroundZoomAmplitude: CGFloat
        let backgroundCycles: CGFloat
        let driftScaleX: CGFloat
        let driftScaleY: CGFloat
        let rotationMultiplier: CGFloat
        let scaleAmplitudeMultiplier: CGFloat
        let staggerStep: CGFloat
        let entranceFloor: CGFloat
        let parallaxOffsetX: CGFloat
        let parallaxOffsetY: CGFloat
        let centerAttraction: CGFloat
        let orbitDegrees: CGFloat
        let bounceStrength: CGFloat
    }

    fileprivate struct AnimatedCollageLayoutTemplate {
        let normalizedRects: [CGRect]
        let tileShape: AnimatedCollageTileShape
        let frameInsetRatio: CGFloat
        let cornerRadiusRatio: CGFloat
        let shuffleRects: Bool
    }

    fileprivate struct AnimatedCollageOverlayStyle {
        let backdropRect: CGRect
        let titleRect: CGRect
        let contextRect: CGRect
        let accentRect: CGRect
        let cornerRadius: CGFloat
        let alignment: CTTextAlignment
        let titleFontName: String
        let titleFontScale: CGFloat
        let contextFontName: String
        let contextFontScale: CGFloat
        let accentColorUsesSecondary: Bool
        let showBackdrop: Bool
        let showAccentRule: Bool
        let strokeAlpha: CGFloat
        let glowAlpha: CGFloat
    }

    fileprivate struct AnimatedCollageLightingStyle {
        let backgroundAlpha: CGFloat
        let vignetteAlpha: CGFloat
        let overlayGradientAlpha: CGFloat
        let bloomAlpha: CGFloat
        let edgeGlowAlpha: CGFloat
        let lightLeakAlpha: CGFloat
        let reflectionAlpha: CGFloat
        let ghostOffset: CGFloat
        let dustAlpha: CGFloat
    }

    fileprivate struct AnimatedCollageRecipe {
        let paletteOptions: [AnimatedTitleCardPalette]
        let layout: AnimatedCollageLayoutTemplate
        let motion: AnimatedCollageMotionProfile
        let overlay: AnimatedCollageOverlayStyle
        let lighting: AnimatedCollageLightingStyle
        let maxTileCount: Int
        let tileOpacityRange: ClosedRange<CGFloat>
        let tileRotationRange: ClosedRange<CGFloat>
        let tileScaleRange: ClosedRange<CGFloat>
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
        let depth: CGFloat
    }

    private struct AnimatedTitleCardFrameSet {
        let recipe: AnimatedCollageRecipe
        let backgroundImage: CGImage?
        let backgroundBaseRect: CGRect?
        let gradientImage: CGImage?
        let palette: AnimatedTitleCardPalette
        let tiles: [AnimatedTitleCardTile]
        let titleOverlayImage: CGImage?
        let title: String
        let contextLine: String?
    }

    private struct ConceptTitleCardPalette {
        let start: CGColor
        let end: CGColor
        let accent: CGColor
        let secondaryAccent: CGColor
        let text: CGColor
        let panel: CGColor
        let paper: CGColor
    }

    private struct ConceptTitleCardFrameSet {
        let treatment: OpeningTitleTreatment
        let title: String
        let contextLine: String?
        let dateSpanText: String?
        let metaLine: String?
        let previewImages: [TitleCardPreviewImage]
        let heroImage: CGImage?
        let blurredBackgroundImage: CGImage?
        let palette: ConceptTitleCardPalette
        let seed: UInt64
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

    private let ciContext: CIContext

    public init() {
        ciContext = CIContext(options: [CIContextOption.cacheIntermediates: false])
    }

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
        frameRate: Int = 30,
        dynamicRange: DynamicRange = .sdr
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
            frameRate: frameRate,
            dynamicRange: dynamicRange
        )
    }

    public func makeTitleCardClip(
        descriptor: OpeningTitleCardDescriptor,
        previewAssets: [TitleCardPreviewAsset],
        duration: CMTime,
        renderSize: CGSize,
        frameRate: Int = 30,
        dynamicRange: DynamicRange = .sdr
    ) async throws -> URL {
        try await makeTitleCardClip(
            descriptor: descriptor,
            previewAssets: previewAssets,
            duration: duration,
            renderSize: renderSize,
            frameRate: frameRate,
            dynamicRange: dynamicRange,
            treatment: .shippingDefault
        )
    }

    package func makeTitleCardClip(
        descriptor: OpeningTitleCardDescriptor,
        previewAssets: [TitleCardPreviewAsset],
        duration: CMTime,
        renderSize: CGSize,
        frameRate: Int = 30,
        dynamicRange: DynamicRange = .sdr,
        treatment: OpeningTitleTreatment
    ) async throws -> URL {
        #if canImport(AppKit)
        let resolvedTitle = descriptor.resolvedTitle
        let displayContextLine = descriptor.displayContextLine
        let titleCardColorConfiguration = titleCardColorConfiguration(for: dynamicRange)
        let titleCardColorSpace = titleCardColorConfiguration.cgColorSpace

        switch treatment {
        case .currentCollage:
            if !previewAssets.isEmpty {
                do {
                    let animatedFrameSet = try await makeAnimatedTitleCardFrameSet(
                        descriptor: descriptor,
                        previewAssets: previewAssets,
                        renderSize: renderSize,
                        colorSpace: titleCardColorSpace
                    )
                    return try await makeVideoClip(
                        duration: duration,
                        renderSize: renderSize,
                        frameRate: frameRate,
                        colorConfiguration: titleCardColorConfiguration
                    ) { [animatedFrameSet] frameIndex, totalFrames in
                        let denominator = max(totalFrames - 1, 1)
                        let progress = CGFloat(frameIndex) / CGFloat(denominator)
                        return try self.makeAnimatedTitleCardFrame(
                            frameSet: animatedFrameSet,
                            progress: progress,
                            renderSize: renderSize,
                            colorSpace: titleCardColorSpace
                        )
                    }
                } catch {
                    // Fall back to the static card if previews fail to load or animate.
                }
            }
            return try await makeLegacyStaticTitleCardClip(
                title: resolvedTitle,
                contextLine: displayContextLine,
                duration: duration,
                renderSize: renderSize,
                frameRate: frameRate,
                colorConfiguration: titleCardColorConfiguration,
                colorSpace: titleCardColorSpace
            )

        case .legacyStatic:
            return try await makeLegacyStaticTitleCardClip(
                title: resolvedTitle,
                contextLine: displayContextLine,
                duration: duration,
                renderSize: renderSize,
                frameRate: frameRate,
                colorConfiguration: titleCardColorConfiguration,
                colorSpace: titleCardColorSpace
            )

        case _ where animatedCollageRecipe(for: treatment) != nil:
            let collageRecipe = animatedCollageRecipe(for: treatment)!
            let animatedFrameSet = try await makeAnimatedCollageVariantFrameSet(
                descriptor: descriptor,
                previewAssets: previewAssets,
                renderSize: renderSize,
                colorSpace: titleCardColorSpace,
                recipe: collageRecipe
            )
            return try await makeVideoClip(
                duration: duration,
                renderSize: renderSize,
                frameRate: frameRate,
                colorConfiguration: titleCardColorConfiguration
            ) { [animatedFrameSet] frameIndex, totalFrames in
                let denominator = max(totalFrames - 1, 1)
                let progress = CGFloat(frameIndex) / CGFloat(denominator)
                return try self.makeAnimatedCollageVariantFrame(
                    frameSet: animatedFrameSet,
                    progress: progress,
                    renderSize: renderSize,
                    colorSpace: titleCardColorSpace
                )
            }

        default:
            let frameSet = try await makeConceptTitleCardFrameSet(
                descriptor: descriptor,
                previewAssets: previewAssets,
                treatment: treatment,
                renderSize: renderSize,
                colorSpace: titleCardColorSpace
            )
            return try await makeVideoClip(
                duration: duration,
                renderSize: renderSize,
                frameRate: frameRate,
                colorConfiguration: titleCardColorConfiguration
            ) { [frameSet] frameIndex, totalFrames in
                let denominator = max(totalFrames - 1, 1)
                let progress = CGFloat(frameIndex) / CGFloat(denominator)
                return try self.makeConceptTitleCardFrame(
                    frameSet: frameSet,
                    progress: progress,
                    renderSize: renderSize,
                    colorSpace: titleCardColorSpace
                )
            }
        }
        #else
        throw RenderError.exportFailed("Title card rendering requires AppKit support")
        #endif
    }

    package func makeTitleCardPreviewImages(
        descriptor: OpeningTitleCardDescriptor,
        previewAssets: [TitleCardPreviewAsset],
        renderSize: CGSize,
        dynamicRange: DynamicRange = .sdr,
        treatment: OpeningTitleTreatment,
        progressValues: [CGFloat]
    ) async throws -> [CGImage] {
        #if canImport(AppKit)
        guard !progressValues.isEmpty else {
            return []
        }
        let renderer = try await makeTitleCardPreviewRenderer(
            descriptor: descriptor,
            previewAssets: previewAssets,
            renderSize: renderSize,
            dynamicRange: dynamicRange,
            treatment: treatment
        )
        return try progressValues.map { try renderer.render(progress: $0) }
        #else
        throw RenderError.exportFailed("Title card rendering requires AppKit support")
        #endif
    }

    package func makeTitleCardPreviewRenderer(
        descriptor: OpeningTitleCardDescriptor,
        previewAssets: [TitleCardPreviewAsset],
        renderSize: CGSize,
        dynamicRange: DynamicRange = .sdr,
        treatment: OpeningTitleTreatment
    ) async throws -> TitleCardPreviewRenderer {
        #if canImport(AppKit)
        let resolvedTitle = descriptor.resolvedTitle
        let displayContextLine = descriptor.displayContextLine
        let titleCardColorConfiguration = titleCardColorConfiguration(for: dynamicRange)
        let titleCardColorSpace = titleCardColorConfiguration.cgColorSpace

        switch treatment {
        case .currentCollage:
            if !previewAssets.isEmpty {
                do {
                    let animatedFrameSet = try await makeAnimatedTitleCardFrameSet(
                        descriptor: descriptor,
                        previewAssets: previewAssets,
                        renderSize: renderSize,
                        colorSpace: titleCardColorSpace
                    )
                    return TitleCardPreviewRenderer { progress in
                        try self.makeAnimatedTitleCardFrameImage(
                            frameSet: animatedFrameSet,
                            progress: progress,
                            renderSize: renderSize,
                            colorSpace: titleCardColorSpace
                        )
                    }
                } catch {
                    // Fall back to the static card if previews fail to load or animate.
                }
            }
            let titleImage: CGImage
            do {
                titleImage = try await Self.makeStaticTitleCardRasterizedImage(
                    title: resolvedTitle,
                    contextLine: displayContextLine,
                    renderSize: renderSize,
                    colorSpace: titleCardColorSpace
                )
            } catch {
                titleImage = try makeFallbackTitleCardImage(
                    renderSize: renderSize,
                    title: resolvedTitle,
                    contextLine: displayContextLine,
                    colorSpace: titleCardColorSpace
                )
            }
            return TitleCardPreviewRenderer { _ in titleImage }

        case .legacyStatic:
            let titleImage: CGImage
            do {
                titleImage = try await Self.makeStaticTitleCardRasterizedImage(
                    title: resolvedTitle,
                    contextLine: displayContextLine,
                    renderSize: renderSize,
                    colorSpace: titleCardColorSpace
                )
            } catch {
                titleImage = try makeFallbackTitleCardImage(
                    renderSize: renderSize,
                    title: resolvedTitle,
                    contextLine: displayContextLine,
                    colorSpace: titleCardColorSpace
                )
            }
            return TitleCardPreviewRenderer { _ in titleImage }

        case _ where animatedCollageRecipe(for: treatment) != nil:
            let collageRecipe = animatedCollageRecipe(for: treatment)!
            let animatedFrameSet = try await makeAnimatedCollageVariantFrameSet(
                descriptor: descriptor,
                previewAssets: previewAssets,
                renderSize: renderSize,
                colorSpace: titleCardColorSpace,
                recipe: collageRecipe
            )
            return TitleCardPreviewRenderer { progress in
                try self.makeAnimatedCollageVariantFrameImage(
                    frameSet: animatedFrameSet,
                    progress: progress,
                    renderSize: renderSize,
                    colorSpace: titleCardColorSpace
                )
            }

        default:
            let frameSet = try await makeConceptTitleCardFrameSet(
                descriptor: descriptor,
                previewAssets: previewAssets,
                treatment: treatment,
                renderSize: renderSize,
                colorSpace: titleCardColorSpace
            )
            return TitleCardPreviewRenderer { progress in
                try self.makeConceptTitleCardFrameImage(
                    frameSet: frameSet,
                    progress: progress,
                    renderSize: renderSize,
                    colorSpace: titleCardColorSpace
                )
            }
        }
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
        let candidateCodecs = preferredIntermediateCodecs(
            for: renderSize,
            colorConfiguration: colorConfiguration
        )
        var lastError: Error?
        var failureDetails: [String] = []

        for codec in candidateCodecs {
            do {
                return try await makeVideoClip(
                    duration: duration,
                    renderSize: renderSize,
                    frameRate: frameRate,
                    colorConfiguration: colorConfiguration,
                    codec: codec,
                    imageProvider: imageProvider
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                failureDetails.append("\(codecName(codec)): \(describe(error))")
            }
        }

        if lastError != nil {
            throw RenderError.exportFailed(
                """
                Unable to encode still image clip with compatible codecs [\(candidateCodecs.map(\.rawValue).joined(separator: ", "))]. \
                Failures: \(failureDetails.joined(separator: " | "))
                """
            )
        }
        throw RenderError.exportFailed("Unable to encode still image clip with any compatible codec")
    }

    private func makeVideoClip(
        duration: CMTime,
        renderSize: CGSize,
        frameRate: Int,
        colorConfiguration: IntermediateColorConfiguration,
        codec: AVVideoCodecType,
        imageProvider: (Int, Int) throws -> CIImage
    ) async throws -> URL {
        let totalFrames = max(Int(ceil(duration.seconds * Double(frameRate))), 1)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let outputURL = temporaryClipURL()

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
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
            throw RenderError.exportFailed(
                "Failed to add writer input for still image clip with codec \(codecName(codec))"
            )
        }
        writer.add(input)

        guard writer.startWriting() else {
            if let writerError = writer.error {
                throw RenderError.exportFailed(
                    "Unable to start writing still image clip with codec \(codecName(codec)). \(describe(writerError))"
                )
            }
            throw RenderError.exportFailed(
                "Unable to start writing still image clip with codec \(codecName(codec)). Settings: \(settings)"
            )
        }
        writer.startSession(atSourceTime: .zero)

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
                if let writerError = writer.error {
                    throw RenderError.exportFailed(
                        "Failed to append image frame with codec \(codecName(codec)). \(describe(writerError))"
                    )
                }
                throw RenderError.exportFailed(
                    "Failed to append image frame with codec \(codecName(codec))"
                )
            }
        }

        writer.endSession(atSourceTime: duration)
        input.markAsFinished()
        try await finish(writer: writer)
        return outputURL
    }

    private func preferredIntermediateCodecs(
        for renderSize: CGSize,
        colorConfiguration: IntermediateColorConfiguration
    ) -> [AVVideoCodecType] {
        let width = Int(renderSize.width.rounded())
        let height = Int(renderSize.height.rounded())
        let largeFrame = width > 4096 || height > 2304
        let candidates: [AVVideoCodecType]
        if colorConfiguration.requiresMain10Profile {
            candidates = largeFrame ? [.proRes422, .hevc] : [.hevc, .proRes422]
        } else {
            candidates = largeFrame ? [.proRes422, .hevc, .h264] : [.h264, .hevc, .proRes422]
        }

        let validationWriterURL = temporaryClipURL()
        defer { try? FileManager.default.removeItem(at: validationWriterURL) }

        guard let validationWriter = try? AVAssetWriter(outputURL: validationWriterURL, fileType: .mov) else {
            return candidates
        }

        let filtered = candidates.filter { candidate in
            let settings = writerVideoSettings(
                codec: candidate,
                renderSize: CGSize(width: width, height: height),
                colorConfiguration: colorConfiguration
            )
            return validationWriter.canApply(outputSettings: settings, forMediaType: .video)
        }
        return filtered.isEmpty ? candidates : filtered
    }

    private func codecName(_ codec: AVVideoCodecType) -> String {
        codec.rawValue
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let reason = nsError.localizedFailureReason ?? nsError.localizedRecoverySuggestion ?? "No additional details."
        let userInfoSummary = nsError.userInfo
            .map { key, value in "\(key)=\(value)" }
            .sorted()
            .joined(separator: ", ")
        if userInfoSummary.isEmpty {
            return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription). \(reason)"
        }
        return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription). \(reason). userInfo{\(userInfoSummary)}"
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

    private func titleCardColorConfiguration(for dynamicRange: DynamicRange) -> IntermediateColorConfiguration {
        dynamicRange == .hdr ? .hlgBT2020() : .bt709()
    }

    private func makeAnimatedTitleCardFrameSet(
        descriptor: OpeningTitleCardDescriptor,
        previewAssets: [TitleCardPreviewAsset],
        renderSize: CGSize,
        colorSpace: CGColorSpace
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
        let backgroundImage = makeBlurredBackgroundImage(
            from: shuffledPreviews[0].image,
            renderSize: renderSize,
            colorSpace: colorSpace
        )
        let backgroundBaseRect = backgroundImage.map {
            Self.aspectFillRect(
                imageSize: CGSize(width: $0.width, height: $0.height),
                into: renderSize
            )
        }

        return AnimatedTitleCardFrameSet(
            recipe: currentCollageControlRecipe(),
            backgroundImage: backgroundImage,
            backgroundBaseRect: backgroundBaseRect,
            gradientImage: makeAnimatedTitleCardGradientImage(
                palette: palette,
                renderSize: renderSize,
                colorSpace: colorSpace
            ),
            palette: palette,
            tiles: makeAnimatedTiles(
                previews: shuffledPreviews,
                renderSize: renderSize,
                generator: &generator
            ),
            titleOverlayImage: makeAnimatedTitleCardTitleOverlayImage(
                title: descriptor.resolvedTitle,
                contextLine: descriptor.displayContextLine,
                accentColor: palette.accent,
                renderSize: renderSize,
                colorSpace: colorSpace
            ),
            title: descriptor.resolvedTitle,
            contextLine: descriptor.displayContextLine
        )
    }

    private func loadAnimatedPreviewImages(
        from previewAssets: [TitleCardPreviewAsset],
        targetDimension: Int
    ) async throws -> [TitleCardPreviewImage] {
        guard !previewAssets.isEmpty else {
            return []
        }

        let maxConcurrentPreviewLoads = 3
        var previews = Array<TitleCardPreviewImage?>(repeating: nil, count: previewAssets.count)
        var nextIndex = 0

        while nextIndex < previewAssets.count {
            let remaining = previewAssets.count - nextIndex

            if remaining >= maxConcurrentPreviewLoads {
                let firstIndex = nextIndex
                let secondIndex = nextIndex + 1
                let thirdIndex = nextIndex + 2
                let firstAsset = previewAssets[firstIndex]
                let secondAsset = previewAssets[secondIndex]
                let thirdAsset = previewAssets[thirdIndex]

                async let firstPreview = loadPreviewImageIfAvailable(
                    from: firstAsset,
                    targetDimension: targetDimension
                )
                async let secondPreview = loadPreviewImageIfAvailable(
                    from: secondAsset,
                    targetDimension: targetDimension
                )
                async let thirdPreview = loadPreviewImageIfAvailable(
                    from: thirdAsset,
                    targetDimension: targetDimension
                )

                let (resolvedFirstPreview, resolvedSecondPreview, resolvedThirdPreview) = try await (
                    firstPreview,
                    secondPreview,
                    thirdPreview
                )
                previews[firstIndex] = resolvedFirstPreview
                previews[secondIndex] = resolvedSecondPreview
                previews[thirdIndex] = resolvedThirdPreview
                nextIndex += maxConcurrentPreviewLoads
                continue
            }

            previews[nextIndex] = try await loadPreviewImageIfAvailable(
                from: previewAssets[nextIndex],
                targetDimension: targetDimension
            )
            nextIndex += 1
        }

        return previews.compactMap { $0 }
    }

    private func loadPreviewImageIfAvailable(
        from previewAsset: TitleCardPreviewAsset,
        targetDimension: Int
    ) async throws -> TitleCardPreviewImage? {
        do {
            let image = try await loadPreviewImage(from: previewAsset, targetDimension: targetDimension)
            return TitleCardPreviewImage(image: image, filename: previewAsset.filename)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
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
        return try autoreleasepool {
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
                phase: phase,
                depth: CGFloat(maxTiles - index) / CGFloat(max(maxTiles, 1))
            )
        }
    }

    private func makeAnimatedTitleCardFrame(
        frameSet: AnimatedTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) throws -> CIImage {
        CIImage(cgImage: try makeAnimatedTitleCardFrameImage(
            frameSet: frameSet,
            progress: progress,
            renderSize: renderSize,
            colorSpace: colorSpace
        ))
    }

    private func makeAnimatedTitleCardFrameImage(
        frameSet: AnimatedTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
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
            throw RenderError.exportFailed("Unable to allocate animated title card frame")
        }

        let fullRect = CGRect(origin: .zero, size: renderSize)
        context.setFillColor(frameSet.palette.start)
        context.fill(fullRect)

        if let backgroundImage = frameSet.backgroundImage,
           let baseRect = frameSet.backgroundBaseRect {
            let zoom = 1.04 + 0.03 * sin(progress * .pi * 2)
            let backgroundRect = scaled(rect: baseRect, scale: zoom)

            context.saveGState()
            context.setAlpha(0.36)
            context.draw(backgroundImage, in: backgroundRect)
            context.restoreGState()
        }

        if let gradientImage = frameSet.gradientImage {
            context.draw(gradientImage, in: fullRect)
        } else {
            drawFullCanvasGradient(
                colors: [
                    frameSet.palette.start.copy(alpha: 0.18) ?? frameSet.palette.start,
                    frameSet.palette.end.copy(alpha: 0.82) ?? frameSet.palette.end
                ],
                start: CGPoint(x: 0, y: renderSize.height),
                end: CGPoint(x: renderSize.width, y: 0),
                colorSpace: colorSpace,
                context: context,
                rect: fullRect
            )
        }

        for tile in frameSet.tiles {
            drawAnimatedTile(tile, progress: progress, renderSize: renderSize, context: context, accentColor: frameSet.palette.accent)
        }

        if let titleOverlayImage = frameSet.titleOverlayImage {
            context.draw(titleOverlayImage, in: fullRect)
        } else {
            drawTitleBackdrop(renderSize: renderSize, context: context)
            drawTitleBlock(
                title: frameSet.title,
                contextLine: frameSet.contextLine,
                accentColor: frameSet.palette.accent,
                renderSize: renderSize,
                context: context
            )
        }

        guard let image = context.makeImage() else {
            throw RenderError.exportFailed("Unable to create animated title card frame")
        }

        return image
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
        colorSpace: CGColorSpace,
        context: CGContext,
        rect: CGRect
    ) {
        let gradientColors = colors.map { color in
            color.converted(to: colorSpace, intent: .relativeColorimetric, options: nil) ?? color
        }

        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors as CFArray, locations: [0, 1]) else {
            return
        }

        context.saveGState()
        context.addRect(rect)
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }

    private func makeAnimatedTitleCardGradientImage(
        palette: AnimatedTitleCardPalette,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard let context = bitmapContext(renderSize: renderSize, colorSpace: colorSpace) else {
            return nil
        }

        drawFullCanvasGradient(
            colors: [
                palette.start.copy(alpha: 0.18) ?? palette.start,
                palette.end.copy(alpha: 0.82) ?? palette.end
            ],
            start: CGPoint(x: 0, y: renderSize.height),
            end: CGPoint(x: renderSize.width, y: 0),
            colorSpace: colorSpace,
            context: context,
            rect: CGRect(origin: .zero, size: renderSize)
        )
        return context.makeImage()
    }

    private func makeAnimatedTitleCardTitleOverlayImage(
        title: String,
        contextLine: String?,
        accentColor: CGColor,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard let context = bitmapContext(renderSize: renderSize, colorSpace: colorSpace) else {
            return nil
        }

        drawTitleBackdrop(renderSize: renderSize, context: context)
        drawTitleBlock(
            title: title,
            contextLine: contextLine,
            accentColor: accentColor,
            renderSize: renderSize,
            context: context
        )
        return context.makeImage()
    }

    private func currentCollageControlRecipe() -> AnimatedCollageRecipe {
        AnimatedCollageRecipe(
            paletteOptions: currentCollagePaletteOptions(),
            layout: currentCollageLayoutTemplate(),
            motion: currentCollageMotionProfile(),
            overlay: lowerLeftOverlayStyle(),
            lighting: currentCollageLightingStyle(),
            maxTileCount: 6,
            tileOpacityRange: 0.78...0.95,
            tileRotationRange: -7...7,
            tileScaleRange: 0.02...0.05
        )
    }

    private func animatedCollageRecipe(for treatment: OpeningTitleTreatment) -> AnimatedCollageRecipe? {
        switch treatment {
        case .collageSunriseGlow:
            return AnimatedCollageRecipe(
                paletteOptions: sunriseCollagePaletteOptions(),
                layout: currentCollageLayoutTemplate(),
                motion: gentleCollageMotionProfile(),
                overlay: lowerLeftOverlayStyle(strokeAlpha: 0.08, glowAlpha: 0.14),
                lighting: sunriseCollageLightingStyle(),
                maxTileCount: 6,
                tileOpacityRange: 0.82...0.96,
                tileRotationRange: -5...5,
                tileScaleRange: 0.018...0.04
            )
        case .collageMidnightNeon:
            return AnimatedCollageRecipe(
                paletteOptions: midnightNeonPaletteOptions(),
                layout: currentCollageLayoutTemplate(),
                motion: currentCollageMotionProfile().with(parallaxX: 0.01),
                overlay: lowerLeftOverlayStyle(strokeAlpha: 0.14, glowAlpha: 0.12),
                lighting: neonCollageLightingStyle(),
                maxTileCount: 6,
                tileOpacityRange: 0.84...0.98,
                tileRotationRange: -8...8,
                tileScaleRange: 0.022...0.055
            )
        case .collageSoftFilm:
            return AnimatedCollageRecipe(
                paletteOptions: softFilmPaletteOptions(),
                layout: currentCollageLayoutTemplate(),
                motion: gentleCollageMotionProfile(),
                overlay: lowerLeftOverlayStyle(strokeAlpha: 0.04, glowAlpha: 0.02),
                lighting: softFilmCollageLightingStyle(),
                maxTileCount: 6,
                tileOpacityRange: 0.80...0.92,
                tileRotationRange: -4...4,
                tileScaleRange: 0.012...0.03
            )
        case .collageDenseMosaic:
            return AnimatedCollageRecipe(
                paletteOptions: currentCollagePaletteOptions(),
                layout: denseMosaicLayoutTemplate(),
                motion: currentCollageMotionProfile(),
                overlay: lowerLeftOverlayStyle(titleFontScale: 0.057),
                lighting: currentCollageLightingStyle(),
                maxTileCount: 10,
                tileOpacityRange: 0.80...0.94,
                tileRotationRange: -8...8,
                tileScaleRange: 0.014...0.03
            )
        case .collageAiryHero:
            return AnimatedCollageRecipe(
                paletteOptions: currentCollagePaletteOptions(),
                layout: airyHeroLayoutTemplate(),
                motion: gentleCollageMotionProfile(),
                overlay: lowerLeftOverlayStyle(titleFontScale: 0.062, contextFontScale: 0.021),
                lighting: currentCollageLightingStyle().with(bloomAlpha: 0.08),
                maxTileCount: 4,
                tileOpacityRange: 0.84...0.98,
                tileRotationRange: -5...5,
                tileScaleRange: 0.02...0.04
            )
        case .collageGentleFloat:
            return AnimatedCollageRecipe(
                paletteOptions: currentCollagePaletteOptions(),
                layout: currentCollageLayoutTemplate(),
                motion: gentleCollageMotionProfile(),
                overlay: lowerLeftOverlayStyle(),
                lighting: currentCollageLightingStyle(),
                maxTileCount: 6,
                tileOpacityRange: 0.82...0.96,
                tileRotationRange: -4...4,
                tileScaleRange: 0.012...0.03
            )
        case .collageParallaxSweep:
            return AnimatedCollageRecipe(
                paletteOptions: currentCollagePaletteOptions(),
                layout: currentCollageLayoutTemplate(),
                motion: parallaxCollageMotionProfile(),
                overlay: lowerLeftOverlayStyle(strokeAlpha: 0.08),
                lighting: currentCollageLightingStyle().with(overlayGradientAlpha: 0.08),
                maxTileCount: 6,
                tileOpacityRange: 0.82...0.96,
                tileRotationRange: -6...6,
                tileScaleRange: 0.02...0.05
            )
        case .collageKineticBounce:
            return AnimatedCollageRecipe(
                paletteOptions: currentCollagePaletteOptions(),
                layout: currentCollageLayoutTemplate(),
                motion: kineticCollageMotionProfile(),
                overlay: lowerLeftOverlayStyle(strokeAlpha: 0.10, glowAlpha: 0.06),
                lighting: currentCollageLightingStyle().with(bloomAlpha: 0.06),
                maxTileCount: 6,
                tileOpacityRange: 0.84...0.98,
                tileRotationRange: -9...9,
                tileScaleRange: 0.024...0.06
            )
        case .collageGlassTitle:
            return AnimatedCollageRecipe(
                paletteOptions: glassCollagePaletteOptions(),
                layout: currentCollageLayoutTemplate(),
                motion: currentCollageMotionProfile(),
                overlay: lowerLeftOverlayStyle(strokeAlpha: 0.18, glowAlpha: 0.14),
                lighting: currentCollageLightingStyle().with(edgeGlowAlpha: 0.08),
                maxTileCount: 6,
                tileOpacityRange: 0.84...0.98,
                tileRotationRange: -6...6,
                tileScaleRange: 0.02...0.05
            )
        case .collageEdgeLit:
            return AnimatedCollageRecipe(
                paletteOptions: edgeLitPaletteOptions(),
                layout: currentCollageLayoutTemplate(),
                motion: currentCollageMotionProfile(),
                overlay: lowerLeftOverlayStyle(strokeAlpha: 0.16, glowAlpha: 0.10),
                lighting: edgeLitCollageLightingStyle(),
                maxTileCount: 6,
                tileOpacityRange: 0.84...0.98,
                tileRotationRange: -7...7,
                tileScaleRange: 0.02...0.05
            )
        case .collageRibbonArc:
            return AnimatedCollageRecipe(
                paletteOptions: sunriseCollagePaletteOptions(),
                layout: ribbonArcLayoutTemplate(),
                motion: parallaxCollageMotionProfile().with(orbitDegrees: 4),
                overlay: centeredOverlayStyle(),
                lighting: sunriseCollageLightingStyle().with(bloomAlpha: 0.12),
                maxTileCount: 7,
                tileOpacityRange: 0.82...0.96,
                tileRotationRange: -10...10,
                tileScaleRange: 0.018...0.04
            )
        case .collageCenterBurst:
            return AnimatedCollageRecipe(
                paletteOptions: currentCollagePaletteOptions(),
                layout: centerBurstLayoutTemplate(),
                motion: burstCollageMotionProfile(),
                overlay: centeredOverlayStyle(glowAlpha: 0.06),
                lighting: currentCollageLightingStyle().with(overlayGradientAlpha: 0.10, bloomAlpha: 0.08),
                maxTileCount: 8,
                tileOpacityRange: 0.82...0.96,
                tileRotationRange: -12...12,
                tileScaleRange: 0.02...0.06
            )
        case .collageGalleryWall:
            return AnimatedCollageRecipe(
                paletteOptions: galleryWallPaletteOptions(),
                layout: galleryWallLayoutTemplate(),
                motion: gentleCollageMotionProfile(),
                overlay: lowerLeftOverlayStyle(titleFontScale: 0.052, contextFontScale: 0.019),
                lighting: galleryWallLightingStyle(),
                maxTileCount: 7,
                tileOpacityRange: 0.88...1.0,
                tileRotationRange: -3...3,
                tileScaleRange: 0.01...0.025
            )
        case .collageFilmBurn:
            return AnimatedCollageRecipe(
                paletteOptions: filmBurnPaletteOptions(),
                layout: currentCollageLayoutTemplate(),
                motion: gentleCollageMotionProfile().with(backgroundCycles: 0.75),
                overlay: lowerLeftOverlayStyle(strokeAlpha: 0.06),
                lighting: filmBurnLightingStyle(),
                maxTileCount: 6,
                tileOpacityRange: 0.80...0.94,
                tileRotationRange: -6...6,
                tileScaleRange: 0.018...0.04
            )
        case .collageLightbox:
            return AnimatedCollageRecipe(
                paletteOptions: lightboxPaletteOptions(),
                layout: lightboxLayoutTemplate(),
                motion: gentleCollageMotionProfile().with(driftX: 0.45, driftY: 0.35),
                overlay: centeredOverlayStyle(
                    cornerRadius: 30,
                    titleFontScale: 0.058,
                    contextFontScale: 0.020,
                    strokeAlpha: 0.10,
                    glowAlpha: 0.0
                ),
                lighting: lightboxLightingStyle(),
                maxTileCount: 6,
                tileOpacityRange: 0.92...1.0,
                tileRotationRange: -3...3,
                tileScaleRange: 0.01...0.024
            )
        case .collageCutoutChaos:
            return AnimatedCollageRecipe(
                paletteOptions: scrapbookCutoutPaletteOptions(),
                layout: cutoutChaosLayoutTemplate(),
                motion: kineticCollageMotionProfile().with(centerAttraction: 0.25),
                overlay: centeredOverlayStyle(glowAlpha: 0.08),
                lighting: currentCollageLightingStyle().with(overlayGradientAlpha: 0.12, bloomAlpha: 0.10),
                maxTileCount: 9,
                tileOpacityRange: 0.82...0.98,
                tileRotationRange: -14...14,
                tileScaleRange: 0.02...0.06
            )
        case .collageReflectionPool:
            return AnimatedCollageRecipe(
                paletteOptions: glassCollagePaletteOptions(),
                layout: reflectionPoolLayoutTemplate(),
                motion: gentleCollageMotionProfile(),
                overlay: centeredOverlayStyle(strokeAlpha: 0.16, glowAlpha: 0.10),
                lighting: reflectionPoolLightingStyle(),
                maxTileCount: 5,
                tileOpacityRange: 0.88...1.0,
                tileRotationRange: -5...5,
                tileScaleRange: 0.012...0.028
            )
        case .collageCascadeColumns:
            return AnimatedCollageRecipe(
                paletteOptions: midnightNeonPaletteOptions(),
                layout: cascadeColumnsLayoutTemplate(),
                motion: cascadeCollageMotionProfile(),
                overlay: centeredOverlayStyle(titleFontScale: 0.060, contextFontScale: 0.020, glowAlpha: 0.06),
                lighting: edgeLitCollageLightingStyle().with(overlayGradientAlpha: 0.08),
                maxTileCount: 8,
                tileOpacityRange: 0.84...0.98,
                tileRotationRange: -5...5,
                tileScaleRange: 0.014...0.03
            )
        case .collageOrbitRing:
            return AnimatedCollageRecipe(
                paletteOptions: currentCollagePaletteOptions(),
                layout: orbitRingLayoutTemplate(),
                motion: orbitCollageMotionProfile(),
                overlay: centeredOverlayStyle(glowAlpha: 0.08),
                lighting: currentCollageLightingStyle().with(bloomAlpha: 0.08),
                maxTileCount: 8,
                tileOpacityRange: 0.84...0.98,
                tileRotationRange: -8...8,
                tileScaleRange: 0.016...0.04
            )
        case .collagePrismShift:
            return AnimatedCollageRecipe(
                paletteOptions: prismShiftPaletteOptions(),
                layout: prismShiftLayoutTemplate(),
                motion: parallaxCollageMotionProfile().with(orbitDegrees: 3),
                overlay: centeredOverlayStyle(strokeAlpha: 0.18, glowAlpha: 0.14),
                lighting: prismShiftLightingStyle(),
                maxTileCount: 6,
                tileOpacityRange: 0.84...0.98,
                tileRotationRange: -7...7,
                tileScaleRange: 0.018...0.045
            )
        default:
            return nil
        }
    }

    private func makeAnimatedCollageVariantFrameSet(
        descriptor: OpeningTitleCardDescriptor,
        previewAssets: [TitleCardPreviewAsset],
        renderSize: CGSize,
        colorSpace: CGColorSpace,
        recipe: AnimatedCollageRecipe
    ) async throws -> AnimatedTitleCardFrameSet {
        let previewImages = try await loadAnimatedPreviewImages(
            from: previewAssets,
            targetDimension: Int(max(renderSize.width, renderSize.height).rounded())
        )
        guard !previewImages.isEmpty else {
            throw RenderError.exportFailed("Animated collage previews unavailable")
        }

        var generator = SeededRandomNumberGenerator(seed: descriptor.variationSeed ^ 0xD1B54A32D192ED03)
        var shuffledPreviews = previewImages
        shuffledPreviews.shuffle(using: &generator)
        let palette = animatedPalette(for: recipe, using: &generator)
        let backgroundImage = makeBlurredBackgroundImage(
            from: shuffledPreviews[0].image,
            renderSize: renderSize,
            colorSpace: colorSpace
        )
        let backgroundBaseRect = backgroundImage.map {
            Self.aspectFillRect(
                imageSize: CGSize(width: $0.width, height: $0.height),
                into: renderSize
            )
        }

        return AnimatedTitleCardFrameSet(
            recipe: recipe,
            backgroundImage: backgroundImage,
            backgroundBaseRect: backgroundBaseRect,
            gradientImage: makeAnimatedCollageGradientImage(
                palette: palette,
                recipe: recipe,
                renderSize: renderSize,
                colorSpace: colorSpace
            ),
            palette: palette,
            tiles: makeAnimatedCollageVariantTiles(
                previews: shuffledPreviews,
                renderSize: renderSize,
                generator: &generator,
                recipe: recipe
            ),
            titleOverlayImage: makeAnimatedCollageOverlayImage(
                title: descriptor.resolvedTitle,
                contextLine: descriptor.displayContextLine,
                palette: palette,
                recipe: recipe,
                renderSize: renderSize,
                colorSpace: colorSpace
            ),
            title: descriptor.resolvedTitle,
            contextLine: descriptor.displayContextLine
        )
    }

    private func makeAnimatedCollageVariantFrame(
        frameSet: AnimatedTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) throws -> CIImage {
        CIImage(cgImage: try makeAnimatedCollageVariantFrameImage(
            frameSet: frameSet,
            progress: progress,
            renderSize: renderSize,
            colorSpace: colorSpace
        ))
    }

    private func makeAnimatedCollageVariantFrameImage(
        frameSet: AnimatedTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
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
            throw RenderError.exportFailed("Unable to allocate animated collage frame")
        }

        let recipe = frameSet.recipe
        let fullRect = CGRect(origin: .zero, size: renderSize)
        context.setFillColor(frameSet.palette.start)
        context.fill(fullRect)

        if let backgroundImage = frameSet.backgroundImage,
           let baseRect = frameSet.backgroundBaseRect {
            let oscillation = sin(progress * .pi * 2 * recipe.motion.backgroundCycles)
            let zoom = recipe.motion.backgroundZoomBase + recipe.motion.backgroundZoomAmplitude * oscillation
            let backgroundRect = scaled(rect: baseRect, scale: zoom).offsetBy(
                dx: renderSize.width * recipe.motion.parallaxOffsetX * oscillation,
                dy: renderSize.height * recipe.motion.parallaxOffsetY * cos(progress * .pi * 2 * recipe.motion.backgroundCycles)
            )

            context.saveGState()
            context.setAlpha(recipe.lighting.backgroundAlpha)
            context.draw(backgroundImage, in: backgroundRect)
            context.restoreGState()
        }

        if let gradientImage = frameSet.gradientImage {
            context.draw(gradientImage, in: fullRect)
        }

        drawAnimatedCollageLighting(
            progress: progress,
            renderSize: renderSize,
            palette: frameSet.palette,
            recipe: recipe,
            colorSpace: colorSpace,
            context: context
        )

        for tile in frameSet.tiles {
            drawAnimatedCollageTile(
                tile,
                progress: progress,
                renderSize: renderSize,
                palette: frameSet.palette,
                recipe: recipe,
                context: context
            )
        }

        if let titleOverlayImage = frameSet.titleOverlayImage {
            context.draw(titleOverlayImage, in: fullRect)
        }

        guard let image = context.makeImage() else {
            throw RenderError.exportFailed("Unable to create animated collage frame")
        }
        return image
    }

    private func animatedPalette(
        for recipe: AnimatedCollageRecipe,
        using generator: inout SeededRandomNumberGenerator
    ) -> AnimatedTitleCardPalette {
        recipe.paletteOptions[Int.random(in: 0..<recipe.paletteOptions.count, using: &generator)]
    }

    private func makeAnimatedCollageVariantTiles(
        previews: [TitleCardPreviewImage],
        renderSize: CGSize,
        generator: inout SeededRandomNumberGenerator,
        recipe: AnimatedCollageRecipe
    ) -> [AnimatedTitleCardTile] {
        var rects = recipe.layout.normalizedRects
        if recipe.layout.shuffleRects {
            rects.shuffle(using: &generator)
        }

        let maxTiles = min(previews.count, rects.count, recipe.maxTileCount)
        return Array(previews.prefix(maxTiles).enumerated()).map { index, preview in
            let xDrift = CGFloat.random(
                in: -(renderSize.width * 0.03 * recipe.motion.driftScaleX)...(renderSize.width * 0.03 * recipe.motion.driftScaleX),
                using: &generator
            )
            let yDrift = CGFloat.random(
                in: -(renderSize.height * 0.025 * recipe.motion.driftScaleY)...(renderSize.height * 0.025 * recipe.motion.driftScaleY),
                using: &generator
            )
            return AnimatedTitleCardTile(
                preview: preview,
                normalizedRect: rects[index],
                baseRotation: CGFloat.random(in: recipe.tileRotationRange, using: &generator) * recipe.motion.rotationMultiplier,
                drift: CGPoint(x: xDrift, y: yDrift),
                scaleAmplitude: CGFloat.random(in: recipe.tileScaleRange, using: &generator) * recipe.motion.scaleAmplitudeMultiplier,
                opacity: CGFloat.random(in: recipe.tileOpacityRange, using: &generator),
                delay: CGFloat(index) * recipe.motion.staggerStep,
                phase: CGFloat.random(in: 0...(CGFloat.pi * 2), using: &generator),
                depth: CGFloat(maxTiles - index) / CGFloat(max(maxTiles, 1))
            )
        }
    }

    private func drawAnimatedCollageTile(
        _ tile: AnimatedTitleCardTile,
        progress: CGFloat,
        renderSize: CGSize,
        palette: AnimatedTitleCardPalette,
        recipe: AnimatedCollageRecipe,
        context: CGContext
    ) {
        var rect = CGRect(
            x: tile.normalizedRect.minX * renderSize.width,
            y: tile.normalizedRect.minY * renderSize.height,
            width: tile.normalizedRect.width * renderSize.width,
            height: tile.normalizedRect.height * renderSize.height
        )

        let easedProgress = max(0, min(1, (progress - tile.delay) / max(1 - tile.delay, 0.2)))
        let oscillation = sin((progress + tile.phase) * .pi * 2 * recipe.motion.backgroundCycles)
        rect.origin.x += tile.drift.x * oscillation
        rect.origin.y += tile.drift.y * cos((progress + tile.phase) * .pi * 2 * recipe.motion.backgroundCycles)

        if recipe.motion.centerAttraction > 0 {
            let centerRect = CGRect(
                x: renderSize.width * 0.5 - rect.width * 0.38,
                y: renderSize.height * 0.5 - rect.height * 0.38,
                width: rect.width * 0.76,
                height: rect.height * 0.76
            )
            rect = interpolatedRect(
                from: centerRect,
                to: rect,
                progress: pow(easedProgress, max(0.6, 1 - recipe.motion.centerAttraction * 0.4))
            )
        }

        if recipe.motion.orbitDegrees != 0 {
            let center = CGPoint(x: renderSize.width * 0.5, y: renderSize.height * 0.5)
            let rectCenter = CGPoint(x: rect.midX, y: rect.midY)
            let angle = recipe.motion.orbitDegrees * (.pi / 180) * sin((progress + tile.phase) * .pi * 2) * (0.35 + tile.depth * 0.65)
            let rotatedCenter = rotated(point: rectCenter, around: center, by: angle)
            rect.origin.x += rotatedCenter.x - rectCenter.x
            rect.origin.y += rotatedCenter.y - rectCenter.y
        }

        let bounce = 1 + recipe.motion.bounceStrength * sin(easedProgress * .pi) * (1 - easedProgress)
        rect = scaled(rect: rect, scale: (1.0 + (tile.scaleAmplitude * easedProgress)) * bounce)
        let alpha = tile.opacity * min(max(easedProgress * 1.3, recipe.motion.entranceFloor), 1)

        if recipe.lighting.ghostOffset > 0 {
            let ghostOffset = renderSize.width * recipe.lighting.ghostOffset
            drawGhostTile(tile.preview.image, rect: rect.offsetBy(dx: ghostOffset, dy: ghostOffset * 0.16), color: palette.accent, alpha: alpha * 0.12, shape: recipe.layout.tileShape, cornerRadius: rect.width * recipe.layout.cornerRadiusRatio, frameInsetRatio: recipe.layout.frameInsetRatio, context: context)
            drawGhostTile(tile.preview.image, rect: rect.offsetBy(dx: -ghostOffset * 0.7, dy: ghostOffset * 0.10), color: palette.secondaryAccent, alpha: alpha * 0.10, shape: recipe.layout.tileShape, cornerRadius: rect.width * recipe.layout.cornerRadiusRatio, frameInsetRatio: recipe.layout.frameInsetRatio, context: context)
        }

        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: tile.baseRotation * (.pi / 180))
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.setAlpha(alpha)
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: max(rect.width * 0.035, 12), color: CGColor(gray: 0, alpha: 0.35 + (tile.depth * 0.12)))

        switch recipe.layout.tileShape {
        case .rounded:
            let clipPath = CGPath(roundedRect: rect, cornerWidth: rect.width * recipe.layout.cornerRadiusRatio, cornerHeight: rect.width * recipe.layout.cornerRadiusRatio, transform: nil)
            context.addPath(clipPath)
            context.clip()
            let imageRect = Self.aspectFillRect(
                imageSize: CGSize(width: tile.preview.image.width, height: tile.preview.image.height),
                into: rect.size
            ).offsetBy(dx: rect.minX, dy: rect.minY)
            context.draw(tile.preview.image, in: imageRect)
        case .framed:
            let outerPath = CGPath(roundedRect: rect, cornerWidth: rect.width * recipe.layout.cornerRadiusRatio, cornerHeight: rect.width * recipe.layout.cornerRadiusRatio, transform: nil)
            context.setFillColor(palette.panel.copy(alpha: 0.94) ?? palette.panel)
            context.addPath(outerPath)
            context.fillPath()
            let inset = rect.width * recipe.layout.frameInsetRatio
            let imageRect = rect.insetBy(dx: inset, dy: inset)
            let innerPath = CGPath(roundedRect: imageRect, cornerWidth: imageRect.width * max(recipe.layout.cornerRadiusRatio - 0.02, 0.01), cornerHeight: imageRect.width * max(recipe.layout.cornerRadiusRatio - 0.02, 0.01), transform: nil)
            context.addPath(innerPath)
            context.clip()
            let fillRect = Self.aspectFillRect(
                imageSize: CGSize(width: tile.preview.image.width, height: tile.preview.image.height),
                into: imageRect.size
            ).offsetBy(dx: imageRect.minX, dy: imageRect.minY)
            context.draw(tile.preview.image, in: fillRect)
        case .cutout:
            let clipPath = makeCutoutPath(rect: rect, phase: tile.phase)
            context.addPath(clipPath)
            context.clip()
            let imageRect = Self.aspectFillRect(
                imageSize: CGSize(width: tile.preview.image.width, height: tile.preview.image.height),
                into: rect.size
            ).offsetBy(dx: rect.minX, dy: rect.minY)
            context.draw(tile.preview.image, in: imageRect)
        }
        context.restoreGState()

        if recipe.lighting.reflectionAlpha > 0 {
            drawReflectedTile(
                tile.preview.image,
                rect: rect,
                alpha: alpha * recipe.lighting.reflectionAlpha,
                shape: recipe.layout.tileShape,
                cornerRadius: rect.width * recipe.layout.cornerRadiusRatio,
                frameInsetRatio: recipe.layout.frameInsetRatio,
                context: context
            )
        }

        context.saveGState()
        let path: CGPath
        switch recipe.layout.tileShape {
        case .rounded:
            path = CGPath(roundedRect: rect, cornerWidth: rect.width * recipe.layout.cornerRadiusRatio, cornerHeight: rect.width * recipe.layout.cornerRadiusRatio, transform: nil)
        case .framed:
            path = CGPath(roundedRect: rect, cornerWidth: rect.width * recipe.layout.cornerRadiusRatio, cornerHeight: rect.width * recipe.layout.cornerRadiusRatio, transform: nil)
        case .cutout:
            path = makeCutoutPath(rect: rect, phase: tile.phase)
        }
        context.addPath(path)
        context.setStrokeColor((recipe.layout.tileShape == .framed ? palette.highlight : palette.accent).copy(alpha: 0.30) ?? palette.accent)
        context.setLineWidth(max(rect.width * 0.006, 2))
        context.strokePath()
        context.restoreGState()

        if recipe.lighting.edgeGlowAlpha > 0 {
            context.saveGState()
            context.addPath(path)
            context.setStrokeColor((palette.secondaryAccent.copy(alpha: recipe.lighting.edgeGlowAlpha) ?? palette.secondaryAccent))
            context.setLineWidth(max(rect.width * 0.012, 4))
            context.setShadow(offset: .zero, blur: max(rect.width * 0.05, 16), color: palette.secondaryAccent.copy(alpha: recipe.lighting.edgeGlowAlpha * 0.8))
            context.strokePath()
            context.restoreGState()
        }
    }

    private func drawAnimatedCollageLighting(
        progress: CGFloat,
        renderSize: CGSize,
        palette: AnimatedTitleCardPalette,
        recipe: AnimatedCollageRecipe,
        colorSpace: CGColorSpace,
        context: CGContext
    ) {
        let fullRect = CGRect(origin: .zero, size: renderSize)
        if recipe.lighting.overlayGradientAlpha > 0 {
            drawFullCanvasGradient(
                colors: [
                    palette.accent.copy(alpha: recipe.lighting.overlayGradientAlpha) ?? palette.accent,
                    palette.end.copy(alpha: 0) ?? palette.end
                ],
                start: CGPoint(x: 0, y: renderSize.height),
                end: CGPoint(x: renderSize.width, y: 0),
                colorSpace: colorSpace,
                context: context,
                rect: fullRect
            )
        }

        if recipe.lighting.bloomAlpha > 0 {
            drawRadialGlow(
                center: CGPoint(x: renderSize.width * (0.18 + 0.04 * sin(progress * .pi * 2)), y: renderSize.height * 0.82),
                radius: renderSize.width * 0.38,
                color: palette.accent.copy(alpha: recipe.lighting.bloomAlpha) ?? palette.accent,
                colorSpace: colorSpace,
                context: context
            )
            drawRadialGlow(
                center: CGPoint(x: renderSize.width * 0.78, y: renderSize.height * (0.24 + 0.03 * cos(progress * .pi * 2))),
                radius: renderSize.width * 0.28,
                color: palette.secondaryAccent.copy(alpha: recipe.lighting.bloomAlpha * 0.75) ?? palette.secondaryAccent,
                colorSpace: colorSpace,
                context: context
            )
        }

        if recipe.lighting.lightLeakAlpha > 0 {
            let leakRect = CGRect(
                x: renderSize.width * (0.02 + 0.06 * sin(progress * .pi * 2)),
                y: renderSize.height * 0.10,
                width: renderSize.width * 0.22,
                height: renderSize.height * 0.95
            )
            drawLinearLeak(in: leakRect, color: palette.accent.copy(alpha: recipe.lighting.lightLeakAlpha) ?? palette.accent, colorSpace: colorSpace, context: context)
        }

        if recipe.lighting.vignetteAlpha > 0 {
            drawVignette(in: fullRect, alpha: recipe.lighting.vignetteAlpha, colorSpace: colorSpace, context: context)
        }

        if recipe.lighting.dustAlpha > 0 {
            drawDust(
                in: fullRect,
                alpha: recipe.lighting.dustAlpha,
                context: context
            )
        }
    }

    private func makeAnimatedCollageGradientImage(
        palette: AnimatedTitleCardPalette,
        recipe: AnimatedCollageRecipe,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard let context = bitmapContext(renderSize: renderSize, colorSpace: colorSpace) else {
            return nil
        }

        drawFullCanvasGradient(
            colors: [
                palette.start.copy(alpha: 0.12) ?? palette.start,
                palette.end.copy(alpha: 0.82) ?? palette.end
            ],
            start: CGPoint(x: 0, y: renderSize.height),
            end: CGPoint(x: renderSize.width, y: 0),
            colorSpace: colorSpace,
            context: context,
            rect: CGRect(origin: .zero, size: renderSize)
        )
        if recipe.lighting.overlayGradientAlpha > 0 {
            drawFullCanvasGradient(
                colors: [
                    palette.secondaryAccent.copy(alpha: recipe.lighting.overlayGradientAlpha * 0.8) ?? palette.secondaryAccent,
                    palette.start.copy(alpha: 0) ?? palette.start
                ],
                start: CGPoint(x: renderSize.width, y: renderSize.height * 0.9),
                end: CGPoint(x: 0, y: 0),
                colorSpace: colorSpace,
                context: context,
                rect: CGRect(origin: .zero, size: renderSize)
            )
        }
        return context.makeImage()
    }

    private func makeAnimatedCollageOverlayImage(
        title: String,
        contextLine: String?,
        palette: AnimatedTitleCardPalette,
        recipe: AnimatedCollageRecipe,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard let context = bitmapContext(renderSize: renderSize, colorSpace: colorSpace) else {
            return nil
        }
        drawAnimatedCollageOverlay(
            title: title,
            contextLine: contextLine,
            palette: palette,
            recipe: recipe,
            renderSize: renderSize,
            context: context
        )
        return context.makeImage()
    }

    private func drawAnimatedCollageOverlay(
        title: String,
        contextLine: String?,
        palette: AnimatedTitleCardPalette,
        recipe: AnimatedCollageRecipe,
        renderSize: CGSize,
        context: CGContext
    ) {
        let overlay = recipe.overlay
        let backdropRect = resolvedRect(from: overlay.backdropRect, in: renderSize)
        let titleRect = resolvedRect(from: overlay.titleRect, in: renderSize)
        let contextRect = resolvedRect(from: overlay.contextRect, in: renderSize)
        let accentRect = CGRect(
            x: renderSize.width * overlay.accentRect.minX,
            y: renderSize.height * overlay.accentRect.minY,
            width: max(renderSize.width * overlay.accentRect.width, 96),
            height: max(renderSize.height * overlay.accentRect.height, 6)
        )
        let accentColor = overlay.accentColorUsesSecondary ? palette.secondaryAccent : palette.accent

        if overlay.showBackdrop {
            let backdropPath = CGPath(roundedRect: backdropRect, cornerWidth: overlay.cornerRadius, cornerHeight: overlay.cornerRadius, transform: nil)
            context.saveGState()
            context.setFillColor(palette.panel)
            context.addPath(backdropPath)
            context.fillPath()
            context.restoreGState()

            if overlay.strokeAlpha > 0 {
                context.saveGState()
                context.addPath(backdropPath)
                context.setStrokeColor((palette.highlight.copy(alpha: overlay.strokeAlpha) ?? palette.highlight))
                context.setLineWidth(2)
                context.strokePath()
                context.restoreGState()
            }

            if overlay.glowAlpha > 0 {
                context.saveGState()
                context.addPath(backdropPath)
                context.setStrokeColor((accentColor.copy(alpha: overlay.glowAlpha) ?? accentColor))
                context.setLineWidth(5)
                context.setShadow(offset: .zero, blur: 24, color: accentColor.copy(alpha: overlay.glowAlpha * 0.75))
                context.strokePath()
                context.restoreGState()
            }
        }

        if overlay.showAccentRule {
            context.saveGState()
            context.setFillColor(accentColor)
            context.fill(accentRect)
            context.restoreGState()
        }

        if let contextLine, !contextLine.isEmpty {
            let contextStyle = paragraphStyle(alignment: overlay.alignment, lineBreakMode: .byTruncatingTail)
            let contextAttributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): CTFontCreateWithName(overlay.contextFontName as CFString, max(renderSize.width * overlay.contextFontScale, 18), nil),
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): palette.text.copy(alpha: 0.85) ?? palette.text,
                NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): contextStyle,
                NSAttributedString.Key(rawValue: kCTKernAttributeName as String): 1.6
            ]
            drawAttributedString(
                NSAttributedString(string: contextLine, attributes: contextAttributes),
                in: contextRect,
                context: context
            )
        }

        let titleStyle = paragraphStyle(alignment: overlay.alignment, lineBreakMode: .byWordWrapping)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): CTFontCreateWithName(overlay.titleFontName as CFString, max(renderSize.width * overlay.titleFontScale, 40), nil),
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): palette.text,
            NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): titleStyle
        ]
        drawAttributedString(
            NSAttributedString(string: title, attributes: titleAttributes),
            in: titleRect,
            context: context
        )
    }

    private func drawGhostTile(
        _ image: CGImage,
        rect: CGRect,
        color: CGColor,
        alpha: CGFloat,
        shape: AnimatedCollageTileShape,
        cornerRadius: CGFloat,
        frameInsetRatio: CGFloat,
        context: CGContext
    ) {
        context.saveGState()
        context.setAlpha(alpha)
        switch shape {
        case .rounded:
            let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.addPath(path)
            context.clip()
            context.setFillColor(color)
            context.fill(rect)
        case .framed:
            let outer = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.addPath(outer)
            context.clip()
            context.setFillColor(color)
            context.fill(rect)
        case .cutout:
            let path = makeCutoutPath(rect: rect, phase: 0.3)
            context.addPath(path)
            context.clip()
            context.setFillColor(color)
            context.fill(rect)
        }
        context.restoreGState()
    }

    private func drawReflectedTile(
        _ image: CGImage,
        rect: CGRect,
        alpha: CGFloat,
        shape: AnimatedCollageTileShape,
        cornerRadius: CGFloat,
        frameInsetRatio: CGFloat,
        context: CGContext
    ) {
        let reflectionRect = CGRect(
            x: rect.minX,
            y: rect.minY - rect.height * 0.92,
            width: rect.width,
            height: rect.height
        )
        context.saveGState()
        context.setAlpha(alpha)
        let clipPath: CGPath
        switch shape {
        case .rounded, .framed:
            clipPath = CGPath(roundedRect: reflectionRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        case .cutout:
            clipPath = makeCutoutPath(rect: reflectionRect, phase: 0.6)
        }
        context.addPath(clipPath)
        context.clip()
        context.translateBy(x: reflectionRect.midX, y: reflectionRect.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -reflectionRect.midX, y: -reflectionRect.midY)
        let imageRect = Self.aspectFillRect(
            imageSize: CGSize(width: image.width, height: image.height),
            into: reflectionRect.size
        ).offsetBy(dx: reflectionRect.minX, dy: reflectionRect.minY)
        context.draw(image, in: imageRect)
        context.restoreGState()
    }

    private func drawRadialGlow(
        center: CGPoint,
        radius: CGFloat,
        color: CGColor,
        colorSpace: CGColorSpace,
        context: CGContext
    ) {
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                color,
                color.copy(alpha: 0) ?? color
            ] as CFArray,
            locations: [0, 1]
        ) else {
            return
        }
        context.saveGState()
        context.setBlendMode(.screen)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        context.restoreGState()
    }

    private func drawLinearLeak(
        in rect: CGRect,
        color: CGColor,
        colorSpace: CGColorSpace,
        context: CGContext
    ) {
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                color.copy(alpha: 0) ?? color,
                color,
                color.copy(alpha: 0) ?? color
            ] as CFArray,
            locations: [0, 0.5, 1]
        ) else {
            return
        }
        context.saveGState()
        context.setBlendMode(.screen)
        context.addRect(rect)
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        context.restoreGState()
    }

    private func drawVignette(
        in rect: CGRect,
        alpha: CGFloat,
        colorSpace: CGColorSpace,
        context: CGContext
    ) {
        let color = CGColor(gray: 0, alpha: alpha)
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                color.copy(alpha: 0) ?? color,
                color
            ] as CFArray,
            locations: [0.25, 1]
        ) else {
            return
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.saveGState()
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: min(rect.width, rect.height) * 0.18,
            endCenter: center,
            endRadius: max(rect.width, rect.height) * 0.72,
            options: []
        )
        context.restoreGState()
    }

    private func drawDust(
        in rect: CGRect,
        alpha: CGFloat,
        context: CGContext
    ) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: alpha))
        for index in 0..<24 {
            let x = rect.width * (0.08 + 0.84 * abs(sin(CGFloat(index) * 13.17)))
            let y = rect.height * (0.10 + 0.80 * abs(cos(CGFloat(index) * 7.41)))
            let size = max(1.2, rect.width * 0.0016 * (0.6 + abs(sin(CGFloat(index) * 2.91))))
            context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
        }
        context.restoreGState()
    }

    private func resolvedRect(from normalizedRect: CGRect, in renderSize: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.minX * renderSize.width,
            y: normalizedRect.minY * renderSize.height,
            width: normalizedRect.width * renderSize.width,
            height: normalizedRect.height * renderSize.height
        )
    }

    private func interpolatedRect(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * progress,
            y: start.minY + (end.minY - start.minY) * progress,
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }

    private func rotated(point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + (dx * cos(angle)) - (dy * sin(angle)),
            y: center.y + (dx * sin(angle)) + (dy * cos(angle))
        )
    }

    private func makeCutoutPath(rect: CGRect, phase: CGFloat) -> CGPath {
        let inset = rect.width * 0.06
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + inset * 0.3, y: rect.minY + inset * 0.9))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + inset * 0.15))
        path.addLine(to: CGPoint(x: rect.maxX - inset * 0.7, y: rect.minY + rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX - inset * 0.2, y: rect.minY + rect.height * 0.46))
        path.addLine(to: CGPoint(x: rect.maxX - inset * 0.8, y: rect.maxY - inset * 0.3))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.maxY - inset * 0.2))
        path.addLine(to: CGPoint(x: rect.minX + inset * 0.1, y: rect.maxY - rect.height * 0.18))
        path.addLine(to: CGPoint(x: rect.minX + inset * 0.5, y: rect.minY + rect.height * 0.28))
        path.closeSubpath()
        return path
    }

    private func currentCollagePaletteOptions() -> [AnimatedTitleCardPalette] {
        [
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
    }

    private func sunriseCollagePaletteOptions() -> [AnimatedTitleCardPalette] {
        [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.28, green: 0.12, blue: 0.11, alpha: 1),
                end: CGColor(red: 0.10, green: 0.09, blue: 0.17, alpha: 1),
                accent: CGColor(red: 0.98, green: 0.74, blue: 0.43, alpha: 1),
                secondaryAccent: CGColor(red: 0.98, green: 0.44, blue: 0.35, alpha: 1),
                panel: CGColor(red: 0.05, green: 0.04, blue: 0.06, alpha: 0.26)
            ),
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.24, green: 0.10, blue: 0.08, alpha: 1),
                end: CGColor(red: 0.09, green: 0.07, blue: 0.16, alpha: 1),
                accent: CGColor(red: 1.0, green: 0.82, blue: 0.49, alpha: 1),
                secondaryAccent: CGColor(red: 0.93, green: 0.47, blue: 0.31, alpha: 1),
                panel: CGColor(red: 0.08, green: 0.05, blue: 0.06, alpha: 0.24)
            )
        ]
    }

    private func midnightNeonPaletteOptions() -> [AnimatedTitleCardPalette] {
        [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.03, green: 0.05, blue: 0.12, alpha: 1),
                end: CGColor(red: 0.08, green: 0.02, blue: 0.14, alpha: 1),
                accent: CGColor(red: 0.20, green: 0.92, blue: 0.98, alpha: 1),
                secondaryAccent: CGColor(red: 0.93, green: 0.24, blue: 0.76, alpha: 1),
                panel: CGColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 0.30),
                highlight: CGColor(red: 0.74, green: 0.86, blue: 1, alpha: 0.30)
            )
        ]
    }

    private func softFilmPaletteOptions() -> [AnimatedTitleCardPalette] {
        [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.26, green: 0.24, blue: 0.18, alpha: 1),
                end: CGColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1),
                accent: CGColor(red: 0.87, green: 0.74, blue: 0.52, alpha: 1),
                secondaryAccent: CGColor(red: 0.54, green: 0.63, blue: 0.44, alpha: 1),
                panel: CGColor(red: 0.10, green: 0.11, blue: 0.10, alpha: 0.24),
                highlight: CGColor(red: 0.98, green: 0.94, blue: 0.86, alpha: 0.18)
            )
        ]
    }

    private func glassCollagePaletteOptions() -> [AnimatedTitleCardPalette] {
        [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.05, green: 0.09, blue: 0.16, alpha: 1),
                end: CGColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 1),
                accent: CGColor(red: 0.64, green: 0.87, blue: 1.0, alpha: 1),
                secondaryAccent: CGColor(red: 0.34, green: 0.79, blue: 0.88, alpha: 1),
                panel: CGColor(red: 0.82, green: 0.90, blue: 1.0, alpha: 0.16),
                highlight: CGColor(red: 0.98, green: 1.0, blue: 1.0, alpha: 0.34)
            )
        ]
    }

    private func edgeLitPaletteOptions() -> [AnimatedTitleCardPalette] {
        [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1),
                end: CGColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1),
                accent: CGColor(red: 0.40, green: 0.86, blue: 0.98, alpha: 1),
                secondaryAccent: CGColor(red: 0.86, green: 0.96, blue: 1.0, alpha: 1),
                panel: CGColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 0.30),
                highlight: CGColor(red: 0.72, green: 0.92, blue: 1.0, alpha: 0.34)
            )
        ]
    }

    private func galleryWallPaletteOptions() -> [AnimatedTitleCardPalette] {
        [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1),
                end: CGColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1),
                accent: CGColor(red: 0.90, green: 0.72, blue: 0.48, alpha: 1),
                secondaryAccent: CGColor(red: 0.82, green: 0.79, blue: 0.72, alpha: 1),
                panel: CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 0.62),
                highlight: CGColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 0.24)
            )
        ]
    }

    private func filmBurnPaletteOptions() -> [AnimatedTitleCardPalette] {
        [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.16, green: 0.08, blue: 0.04, alpha: 1),
                end: CGColor(red: 0.05, green: 0.03, blue: 0.04, alpha: 1),
                accent: CGColor(red: 1.0, green: 0.75, blue: 0.36, alpha: 1),
                secondaryAccent: CGColor(red: 0.93, green: 0.35, blue: 0.18, alpha: 1),
                panel: CGColor(red: 0.06, green: 0.04, blue: 0.03, alpha: 0.26)
            )
        ]
    }

    private func lightboxPaletteOptions() -> [AnimatedTitleCardPalette] {
        [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1),
                end: CGColor(red: 0.88, green: 0.86, blue: 0.82, alpha: 1),
                accent: CGColor(red: 0.18, green: 0.56, blue: 0.78, alpha: 1),
                secondaryAccent: CGColor(red: 0.88, green: 0.48, blue: 0.26, alpha: 1),
                text: CGColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1),
                panel: CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 0.84),
                highlight: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.52)
            )
        ]
    }

    private func scrapbookCutoutPaletteOptions() -> [AnimatedTitleCardPalette] {
        [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.34, green: 0.27, blue: 0.18, alpha: 1),
                end: CGColor(red: 0.18, green: 0.14, blue: 0.11, alpha: 1),
                accent: CGColor(red: 0.92, green: 0.32, blue: 0.24, alpha: 1),
                secondaryAccent: CGColor(red: 0.24, green: 0.68, blue: 0.84, alpha: 1),
                panel: CGColor(red: 0.95, green: 0.92, blue: 0.86, alpha: 0.88),
                highlight: CGColor(red: 0.98, green: 0.96, blue: 0.90, alpha: 0.28)
            )
        ]
    }

    private func prismShiftPaletteOptions() -> [AnimatedTitleCardPalette] {
        [
            AnimatedTitleCardPalette(
                start: CGColor(red: 0.07, green: 0.08, blue: 0.14, alpha: 1),
                end: CGColor(red: 0.03, green: 0.04, blue: 0.09, alpha: 1),
                accent: CGColor(red: 0.56, green: 0.89, blue: 0.98, alpha: 1),
                secondaryAccent: CGColor(red: 0.98, green: 0.56, blue: 0.88, alpha: 1),
                panel: CGColor(red: 0.74, green: 0.82, blue: 0.94, alpha: 0.16),
                highlight: CGColor(red: 0.98, green: 1.0, blue: 1.0, alpha: 0.40)
            )
        ]
    }

    private func currentCollageLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.06, y: 0.60, width: 0.24, height: 0.22),
                CGRect(x: 0.30, y: 0.64, width: 0.20, height: 0.18),
                CGRect(x: 0.56, y: 0.58, width: 0.28, height: 0.24),
                CGRect(x: 0.72, y: 0.30, width: 0.18, height: 0.18),
                CGRect(x: 0.50, y: 0.28, width: 0.18, height: 0.16),
                CGRect(x: 0.16, y: 0.26, width: 0.22, height: 0.20)
            ],
            tileShape: .rounded,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.06,
            shuffleRects: true
        )
    }

    private func denseMosaicLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.05, y: 0.68, width: 0.18, height: 0.16),
                CGRect(x: 0.22, y: 0.70, width: 0.16, height: 0.15),
                CGRect(x: 0.40, y: 0.67, width: 0.15, height: 0.14),
                CGRect(x: 0.56, y: 0.66, width: 0.16, height: 0.15),
                CGRect(x: 0.73, y: 0.64, width: 0.18, height: 0.17),
                CGRect(x: 0.12, y: 0.46, width: 0.18, height: 0.16),
                CGRect(x: 0.33, y: 0.45, width: 0.16, height: 0.15),
                CGRect(x: 0.54, y: 0.43, width: 0.18, height: 0.16),
                CGRect(x: 0.72, y: 0.39, width: 0.16, height: 0.15),
                CGRect(x: 0.20, y: 0.25, width: 0.18, height: 0.17)
            ],
            tileShape: .rounded,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.05,
            shuffleRects: true
        )
    }

    private func airyHeroLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.10, y: 0.57, width: 0.24, height: 0.24),
                CGRect(x: 0.58, y: 0.56, width: 0.24, height: 0.24),
                CGRect(x: 0.62, y: 0.24, width: 0.18, height: 0.18),
                CGRect(x: 0.18, y: 0.23, width: 0.20, height: 0.18)
            ],
            tileShape: .rounded,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.06,
            shuffleRects: false
        )
    }

    private func ribbonArcLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.04, y: 0.54, width: 0.18, height: 0.18),
                CGRect(x: 0.18, y: 0.66, width: 0.16, height: 0.16),
                CGRect(x: 0.34, y: 0.73, width: 0.16, height: 0.16),
                CGRect(x: 0.51, y: 0.74, width: 0.16, height: 0.16),
                CGRect(x: 0.67, y: 0.67, width: 0.16, height: 0.16),
                CGRect(x: 0.80, y: 0.54, width: 0.16, height: 0.16),
                CGRect(x: 0.72, y: 0.30, width: 0.16, height: 0.16)
            ],
            tileShape: .rounded,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.06,
            shuffleRects: false
        )
    }

    private func centerBurstLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.18, y: 0.62, width: 0.17, height: 0.17),
                CGRect(x: 0.37, y: 0.72, width: 0.15, height: 0.15),
                CGRect(x: 0.58, y: 0.68, width: 0.16, height: 0.16),
                CGRect(x: 0.72, y: 0.51, width: 0.16, height: 0.16),
                CGRect(x: 0.67, y: 0.30, width: 0.16, height: 0.16),
                CGRect(x: 0.49, y: 0.19, width: 0.16, height: 0.16),
                CGRect(x: 0.28, y: 0.23, width: 0.16, height: 0.16),
                CGRect(x: 0.14, y: 0.42, width: 0.16, height: 0.16)
            ],
            tileShape: .rounded,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.06,
            shuffleRects: false
        )
    }

    private func galleryWallLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.08, y: 0.58, width: 0.20, height: 0.22),
                CGRect(x: 0.31, y: 0.60, width: 0.18, height: 0.20),
                CGRect(x: 0.54, y: 0.56, width: 0.20, height: 0.24),
                CGRect(x: 0.76, y: 0.55, width: 0.14, height: 0.18),
                CGRect(x: 0.18, y: 0.28, width: 0.18, height: 0.20),
                CGRect(x: 0.42, y: 0.26, width: 0.18, height: 0.18),
                CGRect(x: 0.67, y: 0.24, width: 0.16, height: 0.18)
            ],
            tileShape: .framed,
            frameInsetRatio: 0.06,
            cornerRadiusRatio: 0.05,
            shuffleRects: false
        )
    }

    private func lightboxLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.10, y: 0.60, width: 0.18, height: 0.18),
                CGRect(x: 0.31, y: 0.60, width: 0.18, height: 0.18),
                CGRect(x: 0.52, y: 0.60, width: 0.18, height: 0.18),
                CGRect(x: 0.18, y: 0.36, width: 0.18, height: 0.18),
                CGRect(x: 0.40, y: 0.36, width: 0.18, height: 0.18),
                CGRect(x: 0.62, y: 0.36, width: 0.18, height: 0.18)
            ],
            tileShape: .rounded,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.04,
            shuffleRects: false
        )
    }

    private func cutoutChaosLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.06, y: 0.59, width: 0.21, height: 0.21),
                CGRect(x: 0.20, y: 0.68, width: 0.17, height: 0.17),
                CGRect(x: 0.38, y: 0.61, width: 0.20, height: 0.20),
                CGRect(x: 0.60, y: 0.64, width: 0.17, height: 0.17),
                CGRect(x: 0.75, y: 0.52, width: 0.17, height: 0.17),
                CGRect(x: 0.66, y: 0.28, width: 0.18, height: 0.18),
                CGRect(x: 0.46, y: 0.20, width: 0.18, height: 0.18),
                CGRect(x: 0.25, y: 0.24, width: 0.18, height: 0.18),
                CGRect(x: 0.12, y: 0.39, width: 0.18, height: 0.18)
            ],
            tileShape: .cutout,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.02,
            shuffleRects: false
        )
    }

    private func reflectionPoolLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.12, y: 0.60, width: 0.18, height: 0.18),
                CGRect(x: 0.31, y: 0.66, width: 0.16, height: 0.16),
                CGRect(x: 0.50, y: 0.62, width: 0.18, height: 0.18),
                CGRect(x: 0.68, y: 0.64, width: 0.16, height: 0.16),
                CGRect(x: 0.78, y: 0.46, width: 0.14, height: 0.14)
            ],
            tileShape: .rounded,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.05,
            shuffleRects: false
        )
    }

    private func cascadeColumnsLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.06, y: 0.24, width: 0.14, height: 0.42),
                CGRect(x: 0.21, y: 0.34, width: 0.14, height: 0.38),
                CGRect(x: 0.36, y: 0.20, width: 0.14, height: 0.44),
                CGRect(x: 0.51, y: 0.32, width: 0.14, height: 0.36),
                CGRect(x: 0.66, y: 0.24, width: 0.14, height: 0.42),
                CGRect(x: 0.81, y: 0.35, width: 0.12, height: 0.34),
                CGRect(x: 0.18, y: 0.72, width: 0.14, height: 0.16),
                CGRect(x: 0.62, y: 0.72, width: 0.14, height: 0.16)
            ],
            tileShape: .rounded,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.045,
            shuffleRects: false
        )
    }

    private func orbitRingLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.15, y: 0.58, width: 0.15, height: 0.15),
                CGRect(x: 0.29, y: 0.73, width: 0.14, height: 0.14),
                CGRect(x: 0.50, y: 0.77, width: 0.14, height: 0.14),
                CGRect(x: 0.69, y: 0.69, width: 0.14, height: 0.14),
                CGRect(x: 0.78, y: 0.49, width: 0.14, height: 0.14),
                CGRect(x: 0.69, y: 0.28, width: 0.14, height: 0.14),
                CGRect(x: 0.47, y: 0.18, width: 0.14, height: 0.14),
                CGRect(x: 0.24, y: 0.27, width: 0.14, height: 0.14)
            ],
            tileShape: .rounded,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.05,
            shuffleRects: false
        )
    }

    private func prismShiftLayoutTemplate() -> AnimatedCollageLayoutTemplate {
        AnimatedCollageLayoutTemplate(
            normalizedRects: [
                CGRect(x: 0.08, y: 0.60, width: 0.22, height: 0.20),
                CGRect(x: 0.28, y: 0.66, width: 0.18, height: 0.16),
                CGRect(x: 0.52, y: 0.60, width: 0.24, height: 0.22),
                CGRect(x: 0.72, y: 0.34, width: 0.18, height: 0.18),
                CGRect(x: 0.48, y: 0.26, width: 0.18, height: 0.16),
                CGRect(x: 0.18, y: 0.26, width: 0.20, height: 0.18)
            ],
            tileShape: .rounded,
            frameInsetRatio: 0.0,
            cornerRadiusRatio: 0.06,
            shuffleRects: false
        )
    }

    private func currentCollageMotionProfile() -> AnimatedCollageMotionProfile {
        AnimatedCollageMotionProfile(
            backgroundZoomBase: 1.04,
            backgroundZoomAmplitude: 0.03,
            backgroundCycles: 1.0,
            driftScaleX: 1.0,
            driftScaleY: 1.0,
            rotationMultiplier: 1.0,
            scaleAmplitudeMultiplier: 1.0,
            staggerStep: 0.06,
            entranceFloor: 0.15,
            parallaxOffsetX: 0,
            parallaxOffsetY: 0,
            centerAttraction: 0,
            orbitDegrees: 0,
            bounceStrength: 0
        )
    }

    private func gentleCollageMotionProfile() -> AnimatedCollageMotionProfile {
        currentCollageMotionProfile().with(
            driftX: 0.55,
            driftY: 0.45,
            rotationMultiplier: 0.55,
            scaleAmplitudeMultiplier: 0.55,
            backgroundZoomAmplitude: 0.018,
            backgroundCycles: 0.75
        )
    }

    private func parallaxCollageMotionProfile() -> AnimatedCollageMotionProfile {
        currentCollageMotionProfile().with(
            driftX: 1.1,
            driftY: 0.9,
            parallaxX: 0.018,
            parallaxY: 0.008,
            backgroundZoomAmplitude: 0.038
        )
    }

    private func kineticCollageMotionProfile() -> AnimatedCollageMotionProfile {
        currentCollageMotionProfile().with(
            driftX: 1.25,
            driftY: 1.10,
            rotationMultiplier: 1.2,
            scaleAmplitudeMultiplier: 1.25,
            staggerStep: 0.045,
            bounceStrength: 0.14
        )
    }

    private func burstCollageMotionProfile() -> AnimatedCollageMotionProfile {
        currentCollageMotionProfile().with(
            rotationMultiplier: 1.25,
            scaleAmplitudeMultiplier: 1.1,
            staggerStep: 0.035,
            centerAttraction: 1.0,
            bounceStrength: 0.10
        )
    }

    private func orbitCollageMotionProfile() -> AnimatedCollageMotionProfile {
        currentCollageMotionProfile().with(
            driftX: 0.45,
            driftY: 0.45,
            backgroundZoomAmplitude: 0.02,
            backgroundCycles: 0.85,
            orbitDegrees: 10
        )
    }

    private func cascadeCollageMotionProfile() -> AnimatedCollageMotionProfile {
        currentCollageMotionProfile().with(
            driftX: 0.35,
            driftY: 1.35,
            rotationMultiplier: 0.4,
            scaleAmplitudeMultiplier: 0.45,
            backgroundZoomAmplitude: 0.02
        )
    }

    private func lowerLeftOverlayStyle(
        cornerRadius: CGFloat = 28,
        titleFontScale: CGFloat = 0.055,
        contextFontScale: CGFloat = 0.020,
        strokeAlpha: CGFloat = 0,
        glowAlpha: CGFloat = 0
    ) -> AnimatedCollageOverlayStyle {
        AnimatedCollageOverlayStyle(
            backdropRect: CGRect(x: 0.04, y: 0.07, width: 0.54, height: 0.30),
            titleRect: CGRect(x: 0.08, y: 0.12, width: 0.48, height: 0.18),
            contextRect: CGRect(x: 0.08, y: 0.31, width: 0.44, height: 0.05),
            accentRect: CGRect(x: 0.08, y: 0.30, width: 0.11, height: 0.008),
            cornerRadius: cornerRadius,
            alignment: .left,
            titleFontName: "AvenirNext-Bold",
            titleFontScale: titleFontScale,
            contextFontName: "AvenirNext-DemiBold",
            contextFontScale: contextFontScale,
            accentColorUsesSecondary: false,
            showBackdrop: true,
            showAccentRule: true,
            strokeAlpha: strokeAlpha,
            glowAlpha: glowAlpha
        )
    }

    private func centeredOverlayStyle(
        cornerRadius: CGFloat = 34,
        titleFontScale: CGFloat = 0.052,
        contextFontScale: CGFloat = 0.019,
        strokeAlpha: CGFloat = 0.12,
        glowAlpha: CGFloat = 0
    ) -> AnimatedCollageOverlayStyle {
        AnimatedCollageOverlayStyle(
            backdropRect: CGRect(x: 0.19, y: 0.08, width: 0.62, height: 0.28),
            titleRect: CGRect(x: 0.25, y: 0.13, width: 0.50, height: 0.15),
            contextRect: CGRect(x: 0.26, y: 0.29, width: 0.48, height: 0.05),
            accentRect: CGRect(x: 0.37, y: 0.115, width: 0.26, height: 0.006),
            cornerRadius: cornerRadius,
            alignment: .center,
            titleFontName: "AvenirNext-Bold",
            titleFontScale: titleFontScale,
            contextFontName: "AvenirNext-DemiBold",
            contextFontScale: contextFontScale,
            accentColorUsesSecondary: true,
            showBackdrop: true,
            showAccentRule: true,
            strokeAlpha: strokeAlpha,
            glowAlpha: glowAlpha
        )
    }

    private func currentCollageLightingStyle() -> AnimatedCollageLightingStyle {
        AnimatedCollageLightingStyle(
            backgroundAlpha: 0.36,
            vignetteAlpha: 0.0,
            overlayGradientAlpha: 0.0,
            bloomAlpha: 0.0,
            edgeGlowAlpha: 0.0,
            lightLeakAlpha: 0.0,
            reflectionAlpha: 0.0,
            ghostOffset: 0.0,
            dustAlpha: 0.0
        )
    }

    private func sunriseCollageLightingStyle() -> AnimatedCollageLightingStyle {
        currentCollageLightingStyle().with(
            vignetteAlpha: 0.08,
            overlayGradientAlpha: 0.10,
            bloomAlpha: 0.16,
        )
    }

    private func neonCollageLightingStyle() -> AnimatedCollageLightingStyle {
        currentCollageLightingStyle().with(
            vignetteAlpha: 0.10,
            overlayGradientAlpha: 0.08,
            bloomAlpha: 0.10,
            edgeGlowAlpha: 0.10,
        )
    }

    private func softFilmCollageLightingStyle() -> AnimatedCollageLightingStyle {
        currentCollageLightingStyle().with(
            vignetteAlpha: 0.10,
            lightLeakAlpha: 0.04,
            dustAlpha: 0.08
        )
    }

    private func edgeLitCollageLightingStyle() -> AnimatedCollageLightingStyle {
        currentCollageLightingStyle().with(
            vignetteAlpha: 0.10,
            overlayGradientAlpha: 0.06,
            bloomAlpha: 0.06,
            edgeGlowAlpha: 0.14,
        )
    }

    private func galleryWallLightingStyle() -> AnimatedCollageLightingStyle {
        currentCollageLightingStyle().with(
            backgroundAlpha: 0.28,
            vignetteAlpha: 0.10,
            overlayGradientAlpha: 0.05,
            bloomAlpha: 0.06,
        )
    }

    private func filmBurnLightingStyle() -> AnimatedCollageLightingStyle {
        currentCollageLightingStyle().with(
            vignetteAlpha: 0.08,
            overlayGradientAlpha: 0.06,
            bloomAlpha: 0.08,
            lightLeakAlpha: 0.16,
            dustAlpha: 0.10
        )
    }

    private func lightboxLightingStyle() -> AnimatedCollageLightingStyle {
        currentCollageLightingStyle().with(
            backgroundAlpha: 0.18,
            overlayGradientAlpha: 0.03,
            bloomAlpha: 0.04
        )
    }

    private func reflectionPoolLightingStyle() -> AnimatedCollageLightingStyle {
        currentCollageLightingStyle().with(
            backgroundAlpha: 0.30,
            vignetteAlpha: 0.12,
            bloomAlpha: 0.08,
            reflectionAlpha: 0.18
        )
    }

    private func prismShiftLightingStyle() -> AnimatedCollageLightingStyle {
        currentCollageLightingStyle().with(
            vignetteAlpha: 0.08,
            overlayGradientAlpha: 0.10,
            bloomAlpha: 0.10,
            edgeGlowAlpha: 0.08,
            ghostOffset: 0.010
        )
    }

    private func bitmapContext(
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) -> CGContext? {
        let width = max(1, Int(renderSize.width.rounded()))
        let height = max(1, Int(renderSize.height.rounded()))

        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
    }

    private func makeBlurredBackgroundImage(
        from image: CGImage,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        let canvasRect = CGRect(origin: .zero, size: renderSize)
        let baseImage = CIImage(cgImage: image)
        let backgroundImage = Self.aspectFillImage(baseImage, renderSize: renderSize)
        let clamped = backgroundImage.clampedToExtent()
        let blurred = clamped.applyingFilter(
            "CIGaussianBlur",
            parameters: [kCIInputRadiusKey: max(renderSize.width, renderSize.height) * 0.015]
        ).cropped(to: canvasRect)

        return ciContext.createCGImage(
            blurred,
            from: canvasRect,
            format: .RGBA8,
            colorSpace: colorSpace
        )
    }

    @MainActor
    private static func makeStaticTitleCardRasterizedImage(
        title: String,
        contextLine: String?,
        renderSize: CGSize,
        colorSpace: CGColorSpace
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
              let safeImage = Self.rasterizedImage(rawImage, renderSize: renderSize, colorSpace: colorSpace) else {
            throw RenderError.exportFailed("Unable to create title card image")
        }

        return safeImage
    }

    private func makeFallbackTitleCardImage(
        renderSize: CGSize,
        title: String,
        contextLine: String?,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
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

    private func makeLegacyStaticTitleCardClip(
        title: String,
        contextLine: String?,
        duration: CMTime,
        renderSize: CGSize,
        frameRate: Int,
        colorConfiguration: IntermediateColorConfiguration,
        colorSpace: CGColorSpace
    ) async throws -> URL {
        let titleImage: CGImage
        do {
            titleImage = try await Self.makeStaticTitleCardRasterizedImage(
                title: title,
                contextLine: contextLine,
                renderSize: renderSize,
                colorSpace: colorSpace
            )
        } catch {
            titleImage = try makeFallbackTitleCardImage(
                renderSize: renderSize,
                title: title,
                contextLine: contextLine,
                colorSpace: colorSpace
            )
        }
        return try await makeVideoClip(
            fromRasterizedImage: CIImage(cgImage: titleImage),
            duration: duration,
            renderSize: renderSize,
            frameRate: frameRate,
            colorConfiguration: colorConfiguration
        )
    }

    private func makeConceptTitleCardFrameSet(
        descriptor: OpeningTitleCardDescriptor,
        previewAssets: [TitleCardPreviewAsset],
        treatment: OpeningTitleTreatment,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) async throws -> ConceptTitleCardFrameSet {
        let previewImages: [TitleCardPreviewImage]
        do {
            previewImages = try await loadAnimatedPreviewImages(
                from: previewAssets,
                targetDimension: Int(max(renderSize.width, renderSize.height).rounded())
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            previewImages = []
        }

        let heroImage = previewImages.first?.image
        let blurredBackgroundImage = heroImage.flatMap {
            makeBlurredBackgroundImage(from: $0, renderSize: renderSize, colorSpace: colorSpace)
        }

        return ConceptTitleCardFrameSet(
            treatment: treatment,
            title: descriptor.resolvedTitle,
            contextLine: descriptor.displayContextLine,
            dateSpanText: descriptor.dateSpanText,
            metaLine: combinedMetaLine(contextLine: descriptor.displayContextLine, dateSpanText: descriptor.dateSpanText),
            previewImages: previewImages,
            heroImage: heroImage,
            blurredBackgroundImage: blurredBackgroundImage,
            palette: conceptPalette(for: treatment),
            seed: descriptor.variationSeed
        )
    }

    private func combinedMetaLine(contextLine: String?, dateSpanText: String?) -> String? {
        let parts = [contextLine, dateSpanText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return nil
        }
        return Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }.joined(separator: " • ")
    }

    private func conceptPalette(for treatment: OpeningTitleTreatment) -> ConceptTitleCardPalette {
        switch treatment {
        case .collageSunriseGlow,
             .collageMidnightNeon,
             .collageSoftFilm,
             .collageDenseMosaic,
             .collageAiryHero,
             .collageGentleFloat,
             .collageParallaxSweep,
             .collageKineticBounce,
             .collageGlassTitle,
             .collageEdgeLit,
             .collageRibbonArc,
             .collageCenterBurst,
             .collageGalleryWall,
             .collageFilmBurn,
             .collageLightbox,
             .collageCutoutChaos,
             .collageReflectionPool,
             .collageCascadeColumns,
             .collageOrbitRing,
             .collagePrismShift:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.05, green: 0.08, blue: 0.12, alpha: 1),
                end: CGColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1),
                accent: CGColor(red: 0.30, green: 0.82, blue: 0.86, alpha: 1),
                secondaryAccent: CGColor(red: 0.94, green: 0.68, blue: 0.30, alpha: 1),
                text: CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1),
                panel: CGColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 0.62),
                paper: CGColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)
            )
        case .heroLowerThird:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.04, green: 0.08, blue: 0.12, alpha: 1),
                end: CGColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1),
                accent: CGColor(red: 0.98, green: 0.72, blue: 0.29, alpha: 1),
                secondaryAccent: CGColor(red: 0.38, green: 0.86, blue: 0.80, alpha: 1),
                text: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                panel: CGColor(gray: 0, alpha: 0.38),
                paper: CGColor(red: 0.94, green: 0.92, blue: 0.88, alpha: 1)
            )
        case .splitEditorial:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.11, green: 0.08, blue: 0.07, alpha: 1),
                end: CGColor(red: 0.06, green: 0.05, blue: 0.10, alpha: 1),
                accent: CGColor(red: 0.93, green: 0.46, blue: 0.28, alpha: 1),
                secondaryAccent: CGColor(red: 0.91, green: 0.85, blue: 0.78, alpha: 1),
                text: CGColor(red: 0.99, green: 0.97, blue: 0.94, alpha: 1),
                panel: CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 0.72),
                paper: CGColor(red: 0.95, green: 0.90, blue: 0.84, alpha: 1)
            )
        case .contactSheetStamp:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1),
                end: CGColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1),
                accent: CGColor(red: 0.96, green: 0.41, blue: 0.34, alpha: 1),
                secondaryAccent: CGColor(red: 0.95, green: 0.82, blue: 0.42, alpha: 1),
                text: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                panel: CGColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 0.84),
                paper: CGColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)
            )
        case .polaroidStack, .scrapbookExplosion:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.68, green: 0.57, blue: 0.42, alpha: 1),
                end: CGColor(red: 0.45, green: 0.35, blue: 0.26, alpha: 1),
                accent: CGColor(red: 0.80, green: 0.18, blue: 0.24, alpha: 1),
                secondaryAccent: CGColor(red: 0.18, green: 0.43, blue: 0.68, alpha: 1),
                text: CGColor(red: 0.12, green: 0.10, blue: 0.09, alpha: 1),
                panel: CGColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 0.92),
                paper: CGColor(red: 0.94, green: 0.88, blue: 0.78, alpha: 1)
            )
        case .filmstripMarquee, .broadcastMeltdown:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1),
                end: CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1),
                accent: CGColor(red: 1.0, green: 0.27, blue: 0.31, alpha: 1),
                secondaryAccent: CGColor(red: 0.20, green: 0.86, blue: 0.97, alpha: 1),
                text: CGColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1),
                panel: CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 0.84),
                paper: CGColor(red: 0.95, green: 0.95, blue: 0.94, alpha: 1)
            )
        case .minimalDateSpotlight, .centeredCinematic:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.05, green: 0.08, blue: 0.12, alpha: 1),
                end: CGColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1),
                accent: CGColor(red: 0.90, green: 0.84, blue: 0.68, alpha: 1),
                secondaryAccent: CGColor(red: 0.47, green: 0.64, blue: 0.94, alpha: 1),
                text: CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1),
                panel: CGColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 0.60),
                paper: CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1)
            )
        case .triptychParallax:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1),
                end: CGColor(red: 0.03, green: 0.05, blue: 0.10, alpha: 1),
                accent: CGColor(red: 0.94, green: 0.68, blue: 0.30, alpha: 1),
                secondaryAccent: CGColor(red: 0.36, green: 0.77, blue: 0.86, alpha: 1),
                text: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                panel: CGColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 0.68),
                paper: CGColor(red: 0.95, green: 0.94, blue: 0.92, alpha: 1)
            )
        case .photoBookCover:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.94, green: 0.92, blue: 0.88, alpha: 1),
                end: CGColor(red: 0.86, green: 0.82, blue: 0.74, alpha: 1),
                accent: CGColor(red: 0.45, green: 0.32, blue: 0.19, alpha: 1),
                secondaryAccent: CGColor(red: 0.77, green: 0.60, blue: 0.38, alpha: 1),
                text: CGColor(red: 0.18, green: 0.15, blue: 0.12, alpha: 1),
                panel: CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 0.94),
                paper: CGColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1)
            )
        case .museumPlaque:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.07, green: 0.06, blue: 0.05, alpha: 1),
                end: CGColor(red: 0.14, green: 0.12, blue: 0.10, alpha: 1),
                accent: CGColor(red: 0.84, green: 0.66, blue: 0.39, alpha: 1),
                secondaryAccent: CGColor(red: 0.74, green: 0.73, blue: 0.70, alpha: 1),
                text: CGColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 1),
                panel: CGColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 0.86),
                paper: CGColor(red: 0.88, green: 0.81, blue: 0.70, alpha: 1)
            )
        case .kaleidoscopeBloom:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.16, green: 0.05, blue: 0.18, alpha: 1),
                end: CGColor(red: 0.02, green: 0.08, blue: 0.14, alpha: 1),
                accent: CGColor(red: 1.0, green: 0.49, blue: 0.67, alpha: 1),
                secondaryAccent: CGColor(red: 0.43, green: 0.89, blue: 0.90, alpha: 1),
                text: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                panel: CGColor(red: 0.05, green: 0.03, blue: 0.08, alpha: 0.72),
                paper: CGColor(red: 0.97, green: 0.95, blue: 0.99, alpha: 1)
            )
        case .cosmicOrbitarium:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.01, green: 0.03, blue: 0.08, alpha: 1),
                end: CGColor(red: 0.08, green: 0.02, blue: 0.12, alpha: 1),
                accent: CGColor(red: 0.97, green: 0.76, blue: 0.35, alpha: 1),
                secondaryAccent: CGColor(red: 0.41, green: 0.66, blue: 1.0, alpha: 1),
                text: CGColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1),
                panel: CGColor(red: 0.03, green: 0.05, blue: 0.10, alpha: 0.70),
                paper: CGColor(red: 0.95, green: 0.95, blue: 0.98, alpha: 1)
            )
        case .liquidChrome:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1),
                end: CGColor(red: 0.09, green: 0.03, blue: 0.13, alpha: 1),
                accent: CGColor(red: 0.79, green: 0.88, blue: 1.0, alpha: 1),
                secondaryAccent: CGColor(red: 0.54, green: 0.97, blue: 0.86, alpha: 1),
                text: CGColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 1),
                panel: CGColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 0.62),
                paper: CGColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1)
            )
        case .currentCollage, .legacyStatic:
            return ConceptTitleCardPalette(
                start: CGColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1),
                end: CGColor(red: 0.02, green: 0.04, blue: 0.08, alpha: 1),
                accent: CGColor(red: 0.93, green: 0.72, blue: 0.29, alpha: 1),
                secondaryAccent: CGColor(red: 0.36, green: 0.80, blue: 0.86, alpha: 1),
                text: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                panel: CGColor(gray: 0, alpha: 0.52),
                paper: CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
            )
        }
    }

    private func makeConceptTitleCardFrame(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) throws -> CIImage {
        CIImage(cgImage: try makeConceptTitleCardFrameImage(
            frameSet: frameSet,
            progress: progress,
            renderSize: renderSize,
            colorSpace: colorSpace
        ))
    }

    private func makeConceptTitleCardFrameImage(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) throws -> CGImage {
        guard let context = bitmapContext(renderSize: renderSize, colorSpace: colorSpace) else {
            throw RenderError.exportFailed("Unable to allocate title treatment frame")
        }

        drawConceptBackdrop(frameSet: frameSet, progress: progress, renderSize: renderSize, colorSpace: colorSpace, context: context)

        switch frameSet.treatment {
        case .collageSunriseGlow,
             .collageMidnightNeon,
             .collageSoftFilm,
             .collageDenseMosaic,
             .collageAiryHero,
             .collageGentleFloat,
             .collageParallaxSweep,
             .collageKineticBounce,
             .collageGlassTitle,
             .collageEdgeLit,
             .collageRibbonArc,
             .collageCenterBurst,
             .collageGalleryWall,
             .collageFilmBurn,
             .collageLightbox,
             .collageCutoutChaos,
             .collageReflectionPool,
             .collageCascadeColumns,
             .collageOrbitRing,
             .collagePrismShift:
            drawHeroLowerThird(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .heroLowerThird:
            drawHeroLowerThird(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .splitEditorial:
            drawSplitEditorial(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .contactSheetStamp:
            drawContactSheetStamp(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .polaroidStack:
            drawPolaroidStack(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .filmstripMarquee:
            drawFilmstripMarquee(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .minimalDateSpotlight:
            drawMinimalDateSpotlight(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .centeredCinematic:
            drawCenteredCinematic(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .triptychParallax:
            drawTriptychParallax(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .photoBookCover:
            drawPhotoBookCover(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .museumPlaque:
            drawMuseumPlaque(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .kaleidoscopeBloom:
            drawKaleidoscopeBloom(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .broadcastMeltdown:
            drawBroadcastMeltdown(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .cosmicOrbitarium:
            drawCosmicOrbitarium(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .scrapbookExplosion:
            drawScrapbookExplosion(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .liquidChrome:
            drawLiquidChrome(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        case .currentCollage, .legacyStatic:
            drawMinimalDateSpotlight(frameSet: frameSet, progress: progress, renderSize: renderSize, context: context)
        }

        guard let image = context.makeImage() else {
            throw RenderError.exportFailed("Unable to create title treatment frame")
        }
        return image
    }

    private func drawConceptBackdrop(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        colorSpace: CGColorSpace,
        context: CGContext
    ) {
        let palette = frameSet.palette
        let fullRect = CGRect(origin: .zero, size: renderSize)
        context.setFillColor(palette.start)
        context.fill(fullRect)

        if let backgroundImage = frameSet.blurredBackgroundImage {
            let baseRect = Self.aspectFillRect(
                imageSize: CGSize(width: backgroundImage.width, height: backgroundImage.height),
                into: renderSize
            )
            let zoom = 1.03 + 0.03 * sin(progress * .pi * 2)
            let shiftedRect = scaled(rect: baseRect, scale: zoom).offsetBy(
                dx: sin(progress * .pi * 2) * renderSize.width * 0.015,
                dy: cos(progress * .pi * 2) * renderSize.height * 0.012
            )
            context.saveGState()
            context.setAlpha(0.34)
            context.draw(backgroundImage, in: shiftedRect)
            context.restoreGState()
        }

        drawFullCanvasGradient(
            colors: [
                palette.start.copy(alpha: 0.20) ?? palette.start,
                palette.end.copy(alpha: 0.92) ?? palette.end
            ],
            start: CGPoint(x: 0, y: renderSize.height),
            end: CGPoint(x: renderSize.width, y: 0),
            colorSpace: colorSpace,
            context: context,
            rect: fullRect
        )

        drawVignette(renderSize: renderSize, context: context, colorSpace: colorSpace)
    }

    private func drawHeroLowerThird(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        let fullRect = CGRect(origin: .zero, size: renderSize)
        if let heroImage = frameSet.heroImage {
            drawImageCard(
                heroImage,
                in: scaled(rect: fullRect, scale: 1.03 + (0.03 * progress)),
                context: context,
                alpha: 0.85
            )
        }
        drawSoftPanel(rect: CGRect(x: 0, y: 0, width: renderSize.width, height: renderSize.height * 0.36), fill: frameSet.palette.panel, context: context)
        drawAccentRule(rect: CGRect(x: renderSize.width * 0.08, y: renderSize.height * 0.21, width: renderSize.width * 0.16, height: 8), color: frameSet.palette.accent, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: renderSize.width * 0.08, y: renderSize.height * 0.25, width: renderSize.width * 0.44, height: renderSize.height * 0.05), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.018, 20), color: frameSet.palette.secondaryAccent, alignment: .left, lineBreakMode: .byTruncatingTail, kern: 2.2, context: context)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 8), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
        drawStyledText(frameSet.title, in: CGRect(x: renderSize.width * 0.08, y: renderSize.height * 0.08, width: renderSize.width * 0.56, height: renderSize.height * 0.16), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.064, 58), color: frameSet.palette.text, alignment: .left, context: context)
        context.restoreGState()

        let tileWidth = renderSize.width * 0.16
        for index in 0..<3 {
            guard let image = previewImage(at: index + 1, from: frameSet) else { continue }
            let rect = CGRect(
                x: renderSize.width * (0.70 + (CGFloat(index) * 0.08)),
                y: renderSize.height * (0.50 + sin((progress + CGFloat(index) * 0.17) * .pi * 2) * 0.025),
                width: tileWidth,
                height: renderSize.height * 0.20
            )
            drawImageCard(
                image,
                in: rect,
                context: context,
                cornerRadius: 24,
                rotationDegrees: CGFloat(index - 1) * 6,
                alpha: 0.92,
                strokeColor: frameSet.palette.secondaryAccent.copy(alpha: 0.36),
                shadowOpacity: 0.28
            )
        }
    }

    private func drawSplitEditorial(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        let leftPanel = CGRect(x: 0, y: 0, width: renderSize.width * 0.42, height: renderSize.height)
        drawSoftPanel(rect: leftPanel, fill: frameSet.palette.panel, context: context)
        drawAccentRule(rect: CGRect(x: renderSize.width * 0.08, y: renderSize.height * 0.74, width: renderSize.width * 0.14, height: 7), color: frameSet.palette.accent, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: renderSize.width * 0.08, y: renderSize.height * 0.78, width: renderSize.width * 0.26, height: renderSize.height * 0.05), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.018, 18), color: frameSet.palette.secondaryAccent, alignment: .left, lineBreakMode: .byTruncatingTail, kern: 2, context: context)
        drawStyledText(frameSet.title, in: CGRect(x: renderSize.width * 0.08, y: renderSize.height * 0.40, width: renderSize.width * 0.28, height: renderSize.height * 0.28), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.060, 52), color: frameSet.palette.text, alignment: .left, context: context)

        let cards: [CGRect] = [
            CGRect(x: renderSize.width * 0.52, y: renderSize.height * 0.56, width: renderSize.width * 0.22, height: renderSize.height * 0.24),
            CGRect(x: renderSize.width * 0.69, y: renderSize.height * 0.34, width: renderSize.width * 0.20, height: renderSize.height * 0.22),
            CGRect(x: renderSize.width * 0.46, y: renderSize.height * 0.18, width: renderSize.width * 0.24, height: renderSize.height * 0.20)
        ]

        for (index, rect) in cards.enumerated() {
            guard let image = previewImage(at: index, from: frameSet) else { continue }
            let animatedRect = rect.offsetBy(
                dx: sin((progress + CGFloat(index) * 0.11) * .pi * 2) * renderSize.width * 0.01,
                dy: cos((progress + CGFloat(index) * 0.14) * .pi * 2) * renderSize.height * 0.012
            )
            drawImageCard(
                image,
                in: animatedRect,
                context: context,
                cornerRadius: 28,
                rotationDegrees: CGFloat(index == 1 ? 4 : -5),
                alpha: 0.96,
                strokeColor: frameSet.palette.paper.copy(alpha: 0.42),
                shadowOpacity: 0.30
            )
        }
    }

    private func drawContactSheetStamp(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        let columns = 3
        let rows = 2
        let cellWidth = renderSize.width * 0.25
        let cellHeight = renderSize.height * 0.24
        let startX = renderSize.width * 0.08
        let startY = renderSize.height * 0.22

        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard let image = previewImage(at: index, from: frameSet) else { continue }
                let rect = CGRect(
                    x: startX + CGFloat(column) * (cellWidth + renderSize.width * 0.03),
                    y: startY + CGFloat(rows - 1 - row) * (cellHeight + renderSize.height * 0.04),
                    width: cellWidth,
                    height: cellHeight
                )
                drawImageCard(
                    image,
                    in: rect,
                    context: context,
                    cornerRadius: 18,
                    alpha: 0.94,
                    strokeColor: frameSet.palette.paper.copy(alpha: 0.28),
                    shadowOpacity: 0.20
                )
            }
        }

        let stampRect = CGRect(
            x: renderSize.width * 0.30,
            y: renderSize.height * 0.32 + sin(progress * .pi * 2) * renderSize.height * 0.01,
            width: renderSize.width * 0.40,
            height: renderSize.height * 0.22
        )
        drawSoftPanel(rect: stampRect, fill: frameSet.palette.paper.copy(alpha: 0.95) ?? frameSet.palette.paper, stroke: frameSet.palette.accent, lineWidth: 5, cornerRadius: 20, rotationDegrees: -5, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: stampRect.minX + stampRect.width * 0.12, y: stampRect.minY + stampRect.height * 0.66, width: stampRect.width * 0.76, height: stampRect.height * 0.14), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.015, 16), color: frameSet.palette.accent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 2.4, context: context)
        drawStyledText(frameSet.title, in: CGRect(x: stampRect.minX + stampRect.width * 0.08, y: stampRect.minY + stampRect.height * 0.18, width: stampRect.width * 0.84, height: stampRect.height * 0.40), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.050, 48), color: CGColor(gray: 0.10, alpha: 1), alignment: .center, context: context)
    }

    private func drawPolaroidStack(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        for index in 0..<4 {
            guard let image = previewImage(at: index, from: frameSet) else { continue }
            let rect = CGRect(
                x: renderSize.width * (0.14 + CGFloat(index) * 0.17),
                y: renderSize.height * (0.34 + sin((progress + CGFloat(index) * 0.12) * .pi * 2) * 0.04),
                width: renderSize.width * 0.22,
                height: renderSize.height * 0.30
            )
            drawPolaroidCard(
                image: image,
                rect: rect,
                rotationDegrees: [-10, -3, 5, 12][index],
                context: context
            )
        }

        let labelRect = CGRect(x: renderSize.width * 0.18, y: renderSize.height * 0.08, width: renderSize.width * 0.64, height: renderSize.height * 0.16)
        drawSoftPanel(rect: labelRect, fill: frameSet.palette.paper.copy(alpha: 0.94) ?? frameSet.palette.paper, context: context)
        drawStyledText(frameSet.title, in: CGRect(x: labelRect.minX + labelRect.width * 0.06, y: labelRect.minY + labelRect.height * 0.42, width: labelRect.width * 0.88, height: labelRect.height * 0.34), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.048, 46), color: CGColor(gray: 0.14, alpha: 1), alignment: .center, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: labelRect.minX + labelRect.width * 0.06, y: labelRect.minY + labelRect.height * 0.12, width: labelRect.width * 0.88, height: labelRect.height * 0.20), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.015, 15), color: frameSet.palette.accent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 1.8, context: context)
    }

    private func drawFilmstripMarquee(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        let stripRect = CGRect(x: 0, y: renderSize.height * 0.28, width: renderSize.width, height: renderSize.height * 0.34)
        drawSoftPanel(rect: stripRect, fill: frameSet.palette.panel, context: context)
        drawFilmPerforations(in: stripRect, renderSize: renderSize, context: context)

        let tileWidth = renderSize.width * 0.24
        let baseOffset = progress * tileWidth * 0.8
        for index in 0..<(max(frameSet.previewImages.count, 5)) {
            guard let image = previewImage(at: index, from: frameSet) else { continue }
            let x = -tileWidth * 0.5 + CGFloat(index) * (tileWidth * 0.82) - baseOffset
            let rect = CGRect(x: x, y: stripRect.minY + stripRect.height * 0.16, width: tileWidth, height: stripRect.height * 0.68)
            drawImageCard(image, in: rect, context: context, cornerRadius: 12, alpha: 0.96, strokeColor: frameSet.palette.secondaryAccent.copy(alpha: 0.22), shadowOpacity: 0.15)
        }

        drawAccentRule(rect: CGRect(x: renderSize.width * 0.36, y: renderSize.height * 0.71, width: renderSize.width * 0.28, height: 6), color: frameSet.palette.accent, context: context)
        drawStyledText(frameSet.title, in: CGRect(x: renderSize.width * 0.18, y: renderSize.height * 0.73, width: renderSize.width * 0.64, height: renderSize.height * 0.12), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.055, 50), color: frameSet.palette.text, alignment: .center, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: renderSize.width * 0.18, y: renderSize.height * 0.18, width: renderSize.width * 0.64, height: renderSize.height * 0.05), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.016, 16), color: frameSet.palette.secondaryAccent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 2.2, context: context)
    }

    private func drawMinimalDateSpotlight(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        drawRadialGlow(center: CGPoint(x: renderSize.width * 0.5, y: renderSize.height * (0.56 + (sin(progress * .pi * 2) * 0.015))), radius: renderSize.width * 0.20, color: frameSet.palette.accent.copy(alpha: 0.32) ?? frameSet.palette.accent, context: context, colorSpace: frameSet.palette.text.colorSpace ?? CGColorSpaceCreateDeviceRGB())
        drawStyledText(frameSet.title, in: CGRect(x: renderSize.width * 0.12, y: renderSize.height * 0.44, width: renderSize.width * 0.76, height: renderSize.height * 0.18), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.080, 72), color: frameSet.palette.text, alignment: .center, context: context)
        drawAccentRule(rect: CGRect(x: renderSize.width * 0.36, y: renderSize.height * 0.40, width: renderSize.width * 0.28, height: 4), color: frameSet.palette.secondaryAccent, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: renderSize.width * 0.24, y: renderSize.height * 0.32, width: renderSize.width * 0.52, height: renderSize.height * 0.05), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.017, 18), color: frameSet.palette.secondaryAccent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 2.8, context: context)
    }

    private func drawCenteredCinematic(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        if let heroImage = frameSet.heroImage {
            drawImageCard(
                heroImage,
                in: scaled(rect: CGRect(origin: .zero, size: renderSize), scale: 1.04 + (0.02 * progress)),
                context: context,
                alpha: 0.92
            )
        }
        drawSoftPanel(rect: CGRect(x: renderSize.width * 0.18, y: renderSize.height * 0.22, width: renderSize.width * 0.64, height: renderSize.height * 0.28), fill: frameSet.palette.panel.copy(alpha: 0.46) ?? frameSet.palette.panel, context: context)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: CGColor(gray: 0, alpha: 0.52))
        drawStyledText(frameSet.title, in: CGRect(x: renderSize.width * 0.16, y: renderSize.height * 0.35, width: renderSize.width * 0.68, height: renderSize.height * 0.12), fontName: "Georgia-Bold", fontSize: max(renderSize.width * 0.060, 54), color: frameSet.palette.text, alignment: .center, context: context)
        context.restoreGState()
        drawStyledText(frameSet.metaLine, in: CGRect(x: renderSize.width * 0.20, y: renderSize.height * 0.27, width: renderSize.width * 0.60, height: renderSize.height * 0.05), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.016, 17), color: frameSet.palette.accent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 2.0, context: context)
    }

    private func drawTriptychParallax(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        let widths = [0.24, 0.20, 0.24]
        let xs = [0.10, 0.40, 0.66]
        for index in 0..<3 {
            guard let image = previewImage(at: index, from: frameSet) else { continue }
            let rect = CGRect(
                x: renderSize.width * xs[index],
                y: renderSize.height * 0.08 + cos((progress + CGFloat(index) * 0.13) * .pi * 2) * renderSize.height * 0.03,
                width: renderSize.width * widths[index],
                height: renderSize.height * 0.74
            )
            drawImageCard(
                image,
                in: rect,
                context: context,
                cornerRadius: 22,
                alpha: 0.94,
                strokeColor: frameSet.palette.secondaryAccent.copy(alpha: 0.24),
                shadowOpacity: 0.22
            )
        }

        drawSoftPanel(rect: CGRect(x: renderSize.width * 0.26, y: renderSize.height * 0.12, width: renderSize.width * 0.48, height: renderSize.height * 0.20), fill: frameSet.palette.panel.copy(alpha: 0.58) ?? frameSet.palette.panel, context: context)
        drawStyledText(frameSet.title, in: CGRect(x: renderSize.width * 0.30, y: renderSize.height * 0.21, width: renderSize.width * 0.40, height: renderSize.height * 0.10), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.052, 48), color: frameSet.palette.text, alignment: .center, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: renderSize.width * 0.30, y: renderSize.height * 0.15, width: renderSize.width * 0.40, height: renderSize.height * 0.05), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.015, 15), color: frameSet.palette.accent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 2.2, context: context)
    }

    private func drawPhotoBookCover(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        context.setFillColor(frameSet.palette.paper)
        context.fill(CGRect(origin: .zero, size: renderSize))
        if let heroImage = frameSet.heroImage {
            let photoRect = CGRect(x: renderSize.width * 0.19, y: renderSize.height * 0.42, width: renderSize.width * 0.62, height: renderSize.height * 0.34)
            drawSoftPanel(rect: photoRect.insetBy(dx: -18, dy: -18), fill: CGColor(gray: 1, alpha: 0.86), stroke: frameSet.palette.secondaryAccent.copy(alpha: 0.24), lineWidth: 2, cornerRadius: 2, context: context)
            drawImageCard(heroImage, in: photoRect.offsetBy(dx: 0, dy: sin(progress * .pi * 2) * renderSize.height * 0.008), context: context, alpha: 1.0, shadowOpacity: 0.12)
        }
        drawStyledText(frameSet.title, in: CGRect(x: renderSize.width * 0.14, y: renderSize.height * 0.20, width: renderSize.width * 0.72, height: renderSize.height * 0.12), fontName: "Georgia-Bold", fontSize: max(renderSize.width * 0.052, 48), color: frameSet.palette.text, alignment: .center, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: renderSize.width * 0.18, y: renderSize.height * 0.13, width: renderSize.width * 0.64, height: renderSize.height * 0.05), fontName: "Georgia", fontSize: max(renderSize.width * 0.016, 16), color: frameSet.palette.accent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 1.1, context: context)
    }

    private func drawMuseumPlaque(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        let artRect = CGRect(x: renderSize.width * 0.17, y: renderSize.height * 0.24, width: renderSize.width * 0.48, height: renderSize.height * 0.48)
        drawSoftPanel(rect: artRect.insetBy(dx: -26, dy: -26), fill: CGColor(red: 0.19, green: 0.15, blue: 0.10, alpha: 1), stroke: frameSet.palette.accent.copy(alpha: 0.45), lineWidth: 6, cornerRadius: 6, context: context)
        if let heroImage = frameSet.heroImage {
            drawImageCard(heroImage, in: artRect.offsetBy(dx: 0, dy: sin(progress * .pi * 2) * renderSize.height * 0.006), context: context, alpha: 1.0)
        }
        let plaqueRect = CGRect(x: renderSize.width * 0.70, y: renderSize.height * 0.25, width: renderSize.width * 0.18, height: renderSize.height * 0.20)
        drawSoftPanel(rect: plaqueRect, fill: frameSet.palette.paper.copy(alpha: 0.95) ?? frameSet.palette.paper, stroke: frameSet.palette.secondaryAccent.copy(alpha: 0.30), lineWidth: 2, cornerRadius: 8, context: context)
        drawStyledText("Gallery 03", in: CGRect(x: plaqueRect.minX + plaqueRect.width * 0.12, y: plaqueRect.minY + plaqueRect.height * 0.72, width: plaqueRect.width * 0.76, height: plaqueRect.height * 0.12), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.010, 11), color: frameSet.palette.accent, alignment: .left, lineBreakMode: .byTruncatingTail, kern: 1.6, context: context)
        drawStyledText(frameSet.title, in: CGRect(x: plaqueRect.minX + plaqueRect.width * 0.12, y: plaqueRect.minY + plaqueRect.height * 0.32, width: plaqueRect.width * 0.76, height: plaqueRect.height * 0.32), fontName: "Georgia-Bold", fontSize: max(renderSize.width * 0.020, 19), color: CGColor(gray: 0.10, alpha: 1), alignment: .left, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: plaqueRect.minX + plaqueRect.width * 0.12, y: plaqueRect.minY + plaqueRect.height * 0.12, width: plaqueRect.width * 0.76, height: plaqueRect.height * 0.14), fontName: "Georgia", fontSize: max(renderSize.width * 0.010, 11), color: CGColor(gray: 0.22, alpha: 1), alignment: .left, lineBreakMode: .byWordWrapping, context: context)
    }

    private func drawKaleidoscopeBloom(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        let center = CGPoint(x: renderSize.width * 0.5, y: renderSize.height * 0.55)
        for index in 0..<8 {
            guard let image = previewImage(at: index, from: frameSet) else { continue }
            let angle = (CGFloat(index) / 8) * (.pi * 2) + progress * .pi * 0.2
            let radius = renderSize.width * (0.14 + 0.05 * sin(progress * .pi * 2 + CGFloat(index)))
            let rect = CGRect(
                x: center.x + cos(angle) * radius - renderSize.width * 0.10,
                y: center.y + sin(angle) * radius - renderSize.height * 0.09,
                width: renderSize.width * 0.20,
                height: renderSize.height * 0.18
            )
            drawImageCard(
                image,
                in: rect,
                context: context,
                cornerRadius: 24,
                rotationDegrees: angle * 180 / .pi + 90,
                alpha: 0.84,
                strokeColor: frameSet.palette.secondaryAccent.copy(alpha: 0.30),
                shadowOpacity: 0.18
            )
        }
        let plateRect = CGRect(x: renderSize.width * 0.30, y: renderSize.height * 0.40, width: renderSize.width * 0.40, height: renderSize.height * 0.22)
        drawSoftPanel(rect: plateRect, fill: frameSet.palette.panel.copy(alpha: 0.76) ?? frameSet.palette.panel, stroke: frameSet.palette.accent.copy(alpha: 0.34), lineWidth: 3, cornerRadius: 28, context: context)
        drawStyledText(frameSet.title, in: CGRect(x: plateRect.minX + plateRect.width * 0.10, y: plateRect.minY + plateRect.height * 0.38, width: plateRect.width * 0.80, height: plateRect.height * 0.26), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.052, 48), color: frameSet.palette.text, alignment: .center, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: plateRect.minX + plateRect.width * 0.10, y: plateRect.minY + plateRect.height * 0.16, width: plateRect.width * 0.80, height: plateRect.height * 0.12), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.015, 15), color: frameSet.palette.secondaryAccent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 2.2, context: context)
    }

    private func drawBroadcastMeltdown(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        drawScanlines(renderSize: renderSize, context: context)
        let blockRect = CGRect(x: renderSize.width * 0.07, y: renderSize.height * 0.12, width: renderSize.width * 0.46, height: renderSize.height * 0.28)
        drawSoftPanel(rect: blockRect, fill: frameSet.palette.panel.copy(alpha: 0.78) ?? frameSet.palette.panel, context: context)
        drawStyledText("03", in: CGRect(x: renderSize.width * 0.68, y: renderSize.height * 0.52, width: renderSize.width * 0.22, height: renderSize.height * 0.20), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.12, 120), color: frameSet.palette.accent.copy(alpha: 0.12) ?? frameSet.palette.accent, alignment: .center, context: context)
        drawChromaOffsetTitle(frameSet.title, rect: CGRect(x: renderSize.width * 0.09, y: renderSize.height * 0.20, width: renderSize.width * 0.40, height: renderSize.height * 0.14), renderSize: renderSize, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: renderSize.width * 0.10, y: renderSize.height * 0.14, width: renderSize.width * 0.34, height: renderSize.height * 0.05), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.015, 15), color: frameSet.palette.secondaryAccent, alignment: .left, lineBreakMode: .byTruncatingTail, kern: 2.4, context: context)

        let barY = renderSize.height * 0.62
        for index in 0..<3 {
            guard let image = previewImage(at: index, from: frameSet) else { continue }
            let rect = CGRect(
                x: renderSize.width * (0.58 + CGFloat(index) * 0.11),
                y: barY + sin((progress + CGFloat(index) * 0.15) * .pi * 2) * renderSize.height * 0.01,
                width: renderSize.width * 0.18,
                height: renderSize.height * 0.12
            )
            drawImageCard(image, in: rect, context: context, cornerRadius: 8, alpha: 0.96, strokeColor: frameSet.palette.accent.copy(alpha: 0.20), shadowOpacity: 0.10)
        }
    }

    private func drawCosmicOrbitarium(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        drawStarfield(seed: frameSet.seed ^ 0xC05A1C, renderSize: renderSize, context: context)
        let center = CGPoint(x: renderSize.width * 0.50, y: renderSize.height * 0.52)
        drawRadialGlow(center: center, radius: renderSize.width * 0.18, color: frameSet.palette.secondaryAccent.copy(alpha: 0.24) ?? frameSet.palette.secondaryAccent, context: context, colorSpace: frameSet.palette.text.colorSpace ?? CGColorSpaceCreateDeviceRGB())

        let orbitalRadii: [CGFloat] = [0.18, 0.26, 0.34, 0.42]
        for index in 0..<4 {
            guard let image = previewImage(at: index, from: frameSet) else { continue }
            let angle = progress * .pi * (0.8 + CGFloat(index) * 0.2) + CGFloat(index) * (.pi / 2)
            let radius = renderSize.width * orbitalRadii[index]
            let rect = CGRect(
                x: center.x + cos(angle) * radius - renderSize.width * 0.07,
                y: center.y + sin(angle) * radius * 0.58 - renderSize.height * 0.07,
                width: renderSize.width * 0.14,
                height: renderSize.height * 0.14
            )
            drawCircularImage(image, in: rect, context: context, strokeColor: frameSet.palette.accent.copy(alpha: 0.38), shadowOpacity: 0.28)
        }

        let titlePlate = CGRect(x: renderSize.width * 0.26, y: renderSize.height * 0.38, width: renderSize.width * 0.48, height: renderSize.height * 0.18)
        drawSoftPanel(rect: titlePlate, fill: frameSet.palette.panel.copy(alpha: 0.82) ?? frameSet.palette.panel, stroke: frameSet.palette.secondaryAccent.copy(alpha: 0.28), lineWidth: 2, cornerRadius: 36, context: context)
        drawStyledText(frameSet.title, in: CGRect(x: titlePlate.minX + titlePlate.width * 0.08, y: titlePlate.minY + titlePlate.height * 0.36, width: titlePlate.width * 0.84, height: titlePlate.height * 0.26), fontName: "Georgia-Bold", fontSize: max(renderSize.width * 0.050, 46), color: frameSet.palette.text, alignment: .center, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: titlePlate.minX + titlePlate.width * 0.10, y: titlePlate.minY + titlePlate.height * 0.16, width: titlePlate.width * 0.80, height: titlePlate.height * 0.10), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.014, 14), color: frameSet.palette.accent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 2.1, context: context)
    }

    private func drawScrapbookExplosion(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        context.setFillColor(frameSet.palette.paper)
        context.fill(CGRect(origin: .zero, size: renderSize))
        let scraps = [
            CGRect(x: renderSize.width * 0.07, y: renderSize.height * 0.58, width: renderSize.width * 0.20, height: renderSize.height * 0.18),
            CGRect(x: renderSize.width * 0.62, y: renderSize.height * 0.62, width: renderSize.width * 0.23, height: renderSize.height * 0.16),
            CGRect(x: renderSize.width * 0.12, y: renderSize.height * 0.18, width: renderSize.width * 0.24, height: renderSize.height * 0.20),
            CGRect(x: renderSize.width * 0.58, y: renderSize.height * 0.18, width: renderSize.width * 0.18, height: renderSize.height * 0.18)
        ]
        for (index, rect) in scraps.enumerated() {
            let color = index.isMultiple(of: 2) ? frameSet.palette.accent.copy(alpha: 0.10) : frameSet.palette.secondaryAccent.copy(alpha: 0.10)
            drawTornPaper(rect: rect, fill: color ?? frameSet.palette.paper, seed: frameSet.seed &+ UInt64(index), context: context)
        }
        for index in 0..<4 {
            guard let image = previewImage(at: index, from: frameSet) else { continue }
            let rect = scraps[index].offsetBy(dx: sin((progress + CGFloat(index) * 0.12) * .pi * 2) * renderSize.width * 0.005, dy: 0)
            drawPolaroidCard(image: image, rect: rect, rotationDegrees: [-12, 9, -6, 12][index], context: context)
            drawTapeStrip(rect: CGRect(x: rect.minX + rect.width * 0.30, y: rect.maxY - rect.height * 0.03, width: rect.width * 0.24, height: rect.height * 0.06), rotationDegrees: CGFloat(index.isMultiple(of: 2) ? -10 : 10), context: context)
        }
        let labelRect = CGRect(x: renderSize.width * 0.30, y: renderSize.height * 0.40, width: renderSize.width * 0.40, height: renderSize.height * 0.18)
        drawTornPaper(rect: labelRect, fill: CGColor(red: 0.98, green: 0.96, blue: 0.90, alpha: 0.98), seed: frameSet.seed ^ 0x515A, context: context)
        drawStyledText(frameSet.title, in: CGRect(x: labelRect.minX + labelRect.width * 0.08, y: labelRect.minY + labelRect.height * 0.44, width: labelRect.width * 0.84, height: labelRect.height * 0.24), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.050, 46), color: CGColor(gray: 0.16, alpha: 1), alignment: .center, context: context)
        drawStyledText(frameSet.metaLine, in: CGRect(x: labelRect.minX + labelRect.width * 0.08, y: labelRect.minY + labelRect.height * 0.18, width: labelRect.width * 0.84, height: labelRect.height * 0.10), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.014, 14), color: frameSet.palette.accent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 1.8, context: context)
    }

    private func drawLiquidChrome(
        frameSet: ConceptTitleCardFrameSet,
        progress: CGFloat,
        renderSize: CGSize,
        context: CGContext
    ) {
        let colorSpace = frameSet.palette.text.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        drawChromeBlob(center: CGPoint(x: renderSize.width * 0.26, y: renderSize.height * 0.62), radius: renderSize.width * 0.18, primary: frameSet.palette.accent, secondary: frameSet.palette.secondaryAccent, progress: progress, context: context, colorSpace: colorSpace)
        drawChromeBlob(center: CGPoint(x: renderSize.width * 0.74, y: renderSize.height * 0.56), radius: renderSize.width * 0.16, primary: frameSet.palette.secondaryAccent, secondary: frameSet.palette.accent, progress: progress + 0.2, context: context, colorSpace: colorSpace)
        drawChromeBlob(center: CGPoint(x: renderSize.width * 0.54, y: renderSize.height * 0.28), radius: renderSize.width * 0.12, primary: frameSet.palette.accent.copy(alpha: 0.8) ?? frameSet.palette.accent, secondary: frameSet.palette.paper, progress: progress + 0.4, context: context, colorSpace: colorSpace)

        for index in 0..<2 {
            guard let image = previewImage(at: index, from: frameSet) else { continue }
            let rect = CGRect(
                x: renderSize.width * (0.10 + CGFloat(index) * 0.62),
                y: renderSize.height * (0.16 + CGFloat(index) * 0.12),
                width: renderSize.width * 0.22,
                height: renderSize.height * 0.18
            )
            drawImageCard(image, in: rect, context: context, cornerRadius: 42, alpha: 0.88, strokeColor: frameSet.palette.paper.copy(alpha: 0.42), shadowOpacity: 0.32)
        }

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 14), blur: 34, color: frameSet.palette.secondaryAccent.copy(alpha: 0.35))
        drawStyledText(frameSet.title, in: CGRect(x: renderSize.width * 0.10, y: renderSize.height * 0.52, width: renderSize.width * 0.80, height: renderSize.height * 0.20), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.086, 78), color: frameSet.palette.text, alignment: .center, context: context)
        context.restoreGState()
        drawStyledText(frameSet.metaLine, in: CGRect(x: renderSize.width * 0.22, y: renderSize.height * 0.44, width: renderSize.width * 0.56, height: renderSize.height * 0.05), fontName: "AvenirNext-DemiBold", fontSize: max(renderSize.width * 0.016, 16), color: frameSet.palette.accent, alignment: .center, lineBreakMode: .byTruncatingTail, kern: 3.0, context: context)
    }

    private func previewImage(at index: Int, from frameSet: ConceptTitleCardFrameSet) -> CGImage? {
        guard !frameSet.previewImages.isEmpty else {
            return frameSet.heroImage
        }
        return frameSet.previewImages[index % frameSet.previewImages.count].image
    }

    private func drawStyledText(
        _ text: String?,
        in rect: CGRect,
        fontName: String,
        fontSize: CGFloat,
        color: CGColor,
        alignment: CTTextAlignment,
        lineBreakMode: CTLineBreakMode = .byWordWrapping,
        kern: CGFloat = 0,
        context: CGContext
    ) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, fontSize, nil),
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): paragraphStyle(alignment: alignment, lineBreakMode: lineBreakMode),
            NSAttributedString.Key(rawValue: kCTKernAttributeName as String): kern
        ]
        drawAttributedString(NSAttributedString(string: text, attributes: attributes), in: rect, context: context)
    }

    private func drawAccentRule(rect: CGRect, color: CGColor, context: CGContext) {
        context.saveGState()
        context.setFillColor(color)
        context.fill(rect)
        context.restoreGState()
    }

    private func drawSoftPanel(
        rect: CGRect,
        fill: CGColor,
        stroke: CGColor? = nil,
        lineWidth: CGFloat = 2,
        cornerRadius: CGFloat = 24,
        rotationDegrees: CGFloat = 0,
        context: CGContext
    ) {
        context.saveGState()
        if rotationDegrees != 0 {
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: rotationDegrees * (.pi / 180))
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        context.setShadow(offset: CGSize(width: 0, height: 12), blur: 24, color: CGColor(gray: 0, alpha: 0.20))
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        if let stroke {
            context.addPath(path)
            context.setStrokeColor(stroke)
            context.setLineWidth(lineWidth)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawImageCard(
        _ image: CGImage,
        in rect: CGRect,
        context: CGContext,
        cornerRadius: CGFloat = 0,
        rotationDegrees: CGFloat = 0,
        alpha: CGFloat = 1,
        strokeColor: CGColor? = nil,
        shadowOpacity: CGFloat = 0.24
    ) {
        context.saveGState()
        if rotationDegrees != 0 {
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: rotationDegrees * (.pi / 180))
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        context.setAlpha(alpha)
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: max(rect.width * 0.035, 12), color: CGColor(gray: 0, alpha: shadowOpacity))

        let drawRect = rect
        if cornerRadius > 0 {
            let clipPath = CGPath(roundedRect: drawRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.addPath(clipPath)
            context.clip()
        }
        let imageRect = Self.aspectFillRect(
            imageSize: CGSize(width: image.width, height: image.height),
            into: drawRect.size
        ).offsetBy(dx: drawRect.minX, dy: drawRect.minY)
        context.draw(image, in: imageRect)
        context.restoreGState()

        if let strokeColor {
            context.saveGState()
            if rotationDegrees != 0 {
                context.translateBy(x: rect.midX, y: rect.midY)
                context.rotate(by: rotationDegrees * (.pi / 180))
                context.translateBy(x: -rect.midX, y: -rect.midY)
            }
            let path = cornerRadius > 0
                ? CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                : CGPath(rect: rect, transform: nil)
            context.addPath(path)
            context.setStrokeColor(strokeColor)
            context.setLineWidth(max(rect.width * 0.006, 2))
            context.strokePath()
            context.restoreGState()
        }
    }

    private func drawPolaroidCard(
        image: CGImage,
        rect: CGRect,
        rotationDegrees: CGFloat,
        context: CGContext
    ) {
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: rotationDegrees * (.pi / 180))
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.20))
        let framePath = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.addPath(framePath)
        context.setFillColor(CGColor(gray: 1, alpha: 0.98))
        context.fillPath()
        let imageRect = CGRect(
            x: rect.minX + rect.width * 0.08,
            y: rect.minY + rect.height * 0.22,
            width: rect.width * 0.84,
            height: rect.height * 0.68
        )
        let clipPath = CGPath(roundedRect: imageRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(clipPath)
        context.clip()
        let fillRect = Self.aspectFillRect(imageSize: CGSize(width: image.width, height: image.height), into: imageRect.size)
            .offsetBy(dx: imageRect.minX, dy: imageRect.minY)
        context.draw(image, in: fillRect)
        context.restoreGState()
    }

    private func drawFilmPerforations(in rect: CGRect, renderSize: CGSize, context: CGContext) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        let holeWidth = renderSize.width * 0.012
        let spacing = holeWidth * 1.7
        var x = rect.minX + spacing * 0.5
        while x < rect.maxX {
            context.fill(CGRect(x: x, y: rect.minY + rect.height * 0.86, width: holeWidth, height: rect.height * 0.08))
            context.fill(CGRect(x: x, y: rect.minY + rect.height * 0.06, width: holeWidth, height: rect.height * 0.08))
            x += spacing
        }
        context.restoreGState()
    }

    private func drawVignette(renderSize: CGSize, context: CGContext, colorSpace: CGColorSpace) {
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(gray: 0, alpha: 0) as Any,
                CGColor(gray: 0, alpha: 0.52) as Any
            ] as CFArray,
            locations: [0.45, 1.0]
        ) else {
            return
        }
        let center = CGPoint(x: renderSize.width * 0.5, y: renderSize.height * 0.52)
        context.saveGState()
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: max(renderSize.width, renderSize.height) * 0.62,
            options: []
        )
        context.restoreGState()
    }

    private func drawRadialGlow(
        center: CGPoint,
        radius: CGFloat,
        color: CGColor,
        context: CGContext,
        colorSpace: CGColorSpace
    ) {
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                color,
                color.copy(alpha: 0) ?? color
            ] as CFArray,
            locations: [0, 1]
        ) else {
            return
        }
        context.saveGState()
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: []
        )
        context.restoreGState()
    }

    private func drawScanlines(renderSize: CGSize, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.06))
        context.setLineWidth(1)
        var y: CGFloat = 0
        while y <= renderSize.height {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: renderSize.width, y: y))
            y += 5
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawChromaOffsetTitle(
        _ text: String,
        rect: CGRect,
        renderSize: CGSize,
        context: CGContext
    ) {
        let offset = max(renderSize.width * 0.003, 3)
        drawStyledText(text, in: rect.offsetBy(dx: -offset, dy: 0), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.062, 56), color: CGColor(red: 1.0, green: 0.26, blue: 0.36, alpha: 0.65), alignment: .left, context: context)
        drawStyledText(text, in: rect.offsetBy(dx: offset, dy: 0), fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.062, 56), color: CGColor(red: 0.24, green: 0.88, blue: 1.0, alpha: 0.65), alignment: .left, context: context)
        drawStyledText(text, in: rect, fontName: "AvenirNext-Bold", fontSize: max(renderSize.width * 0.062, 56), color: CGColor(gray: 1, alpha: 1), alignment: .left, context: context)
    }

    private func drawCircularImage(
        _ image: CGImage,
        in rect: CGRect,
        context: CGContext,
        strokeColor: CGColor?,
        shadowOpacity: CGFloat
    ) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: shadowOpacity))
        context.addEllipse(in: rect)
        context.clip()
        let fillRect = Self.aspectFillRect(imageSize: CGSize(width: image.width, height: image.height), into: rect.size)
            .offsetBy(dx: rect.minX, dy: rect.minY)
        context.draw(image, in: fillRect)
        context.restoreGState()
        if let strokeColor {
            context.saveGState()
            context.addEllipse(in: rect)
            context.setStrokeColor(strokeColor)
            context.setLineWidth(max(rect.width * 0.02, 3))
            context.strokePath()
            context.restoreGState()
        }
    }

    private func drawStarfield(seed: UInt64, renderSize: CGSize, context: CGContext) {
        var generator = SeededRandomNumberGenerator(seed: seed)
        context.saveGState()
        for _ in 0..<90 {
            let x = CGFloat.random(in: 0...renderSize.width, using: &generator)
            let y = CGFloat.random(in: 0...renderSize.height, using: &generator)
            let radius = CGFloat.random(in: 1.2...3.2, using: &generator)
            let alpha = CGFloat.random(in: 0.15...0.85, using: &generator)
            context.setFillColor(CGColor(gray: 1, alpha: alpha))
            context.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius))
        }
        context.restoreGState()
    }

    private func drawTornPaper(rect: CGRect, fill: CGColor, seed: UInt64, context: CGContext) {
        var generator = SeededRandomNumberGenerator(seed: seed)
        let path = CGMutablePath()
        let points = 8
        for index in 0..<points {
            let angle = (CGFloat(index) / CGFloat(points)) * (.pi * 2)
            let radiusX = rect.width * CGFloat.random(in: 0.42...0.52, using: &generator)
            let radiusY = rect.height * CGFloat.random(in: 0.42...0.52, using: &generator)
            let point = CGPoint(
                x: rect.midX + cos(angle) * radiusX,
                y: rect.midY + sin(angle) * radiusY
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.12))
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        context.restoreGState()
    }

    private func drawTapeStrip(rect: CGRect, rotationDegrees: CGFloat, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: rotationDegrees * (.pi / 180))
        context.translateBy(x: -rect.midX, y: -rect.midY)
        context.setFillColor(CGColor(red: 0.95, green: 0.90, blue: 0.71, alpha: 0.54))
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private func drawChromeBlob(
        center: CGPoint,
        radius: CGFloat,
        primary: CGColor,
        secondary: CGColor,
        progress: CGFloat,
        context: CGContext,
        colorSpace: CGColorSpace
    ) {
        let stretchedCenter = CGPoint(
            x: center.x + sin(progress * .pi * 2) * radius * 0.12,
            y: center.y + cos(progress * .pi * 2) * radius * 0.08
        )
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                secondary.copy(alpha: 0.92) ?? secondary,
                primary.copy(alpha: 0.78) ?? primary,
                CGColor(gray: 1, alpha: 0.12)
            ] as CFArray,
            locations: [0, 0.55, 1]
        ) else {
            return
        }
        context.saveGState()
        context.setBlendMode(.screen)
        context.drawRadialGradient(
            gradient,
            startCenter: stretchedCenter,
            startRadius: radius * 0.08,
            endCenter: stretchedCenter,
            endRadius: radius,
            options: []
        )
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
    static func hdrGainMapImageSourceOptions() -> [CIImageOption: Any] {
        // Gain maps follow the source image's orientation metadata. If we decode
        // them without that transform, HDR stills can show a rotated ghost image.
        [
            .applyOrientationProperty: true,
            .auxiliaryHDRGainMap: true
        ]
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
            options: Self.hdrGainMapImageSourceOptions()
        )
        return sourceImage.applyingGainMap(gainMap)
    }

    private func finish(writer: AVAssetWriter) async throws {
        let writerReference = UncheckedSendableReference(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                let writer = writerReference.value
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
