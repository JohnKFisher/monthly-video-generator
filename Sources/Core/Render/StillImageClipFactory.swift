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

    public init() {}

    public func makeVideoClip(
        fromImageURL url: URL,
        duration: CMTime,
        renderSize: CGSize,
        dynamicRange: DynamicRange = .sdr
    ) async throws -> URL {
        #if canImport(AppKit)
        let payload = try loadRasterizedImage(from: url, renderSize: renderSize, dynamicRange: dynamicRange)
        return try await makeVideoClip(
            fromRasterizedImage: payload.image,
            duration: duration,
            renderSize: renderSize,
            colorConfiguration: payload.colorConfiguration
        )
        #else
        throw RenderError.exportFailed("Image rendering requires AppKit support")
        #endif
    }

    public func makeTitleCardClip(title: String, duration: CMTime, renderSize: CGSize) async throws -> URL {
        #if canImport(AppKit)
        let titleImage: CGImage
        do {
            titleImage = try await MainActor.run { [renderSize, title] in
                try Self.makeTitleCardRasterizedImage(title: title, renderSize: renderSize)
            }
        } catch {
            titleImage = try makeFallbackTitleCardImage(renderSize: renderSize, title: title)
        }
        return try await makeVideoClip(
            fromRasterizedImage: CIImage(cgImage: titleImage),
            duration: duration,
            renderSize: renderSize,
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
        colorConfiguration: IntermediateColorConfiguration
    ) async throws -> URL {
        let frameRate = 30
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
            render(
                image: image,
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

    @MainActor
    private static func makeTitleCardRasterizedImage(title: String, renderSize: CGSize) throws -> CGImage {
        let size = NSSize(width: renderSize.width, height: renderSize.height)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        let background = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
        background.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(renderSize.width * 0.05, 42), weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]

        let attributed = NSAttributedString(string: title, attributes: attributes)
        let textRect = NSRect(x: renderSize.width * 0.1, y: renderSize.height * 0.4, width: renderSize.width * 0.8, height: renderSize.height * 0.2)
        attributed.draw(in: textRect)

        var proposedRect = CGRect(origin: .zero, size: size)
        guard let rawImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              let safeImage = Self.rasterizedImage(rawImage, renderSize: renderSize, colorSpace: IntermediateColorConfiguration.bt709().cgColorSpace) else {
            throw RenderError.exportFailed("Unable to create title card image")
        }

        return safeImage
    }

    private func makeFallbackTitleCardImage(renderSize: CGSize, title: String) throws -> CGImage {
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

    private func drawFallbackTitle(text: String, context: CGContext, renderSize: CGSize) {
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
        let normalized = sourceImage.transformed(
            by: CGAffineTransform(
                translationX: -sourceImage.extent.minX,
                y: -sourceImage.extent.minY
            )
        )
        guard normalized.extent.width > 0, normalized.extent.height > 0 else {
            return CIImage(color: .black).cropped(to: canvasRect)
        }

        let fittedRect = aspectFitRect(imageSize: normalized.extent.size, into: renderSize)
        let scaleX = fittedRect.width / normalized.extent.width
        let scaleY = fittedRect.height / normalized.extent.height
        let transformed = normalized
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: fittedRect.minX, y: fittedRect.minY))
        let background = CIImage(color: .black).cropped(to: canvasRect)
        let composed = transformed.composited(over: background).cropped(to: canvasRect)
        return composed
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

    private func temporaryClipURL() -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("MonthlyVideoGenerator", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }
    #endif
}
