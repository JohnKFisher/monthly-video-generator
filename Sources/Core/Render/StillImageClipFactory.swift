import AVFoundation
import Foundation
import ImageIO
#if canImport(AppKit)
import AppKit
#endif

public final class StillImageClipFactory {
    public init() {}

    public func makeVideoClip(fromImageURL url: URL, duration: CMTime, renderSize: CGSize) async throws -> URL {
        #if canImport(AppKit)
        let rasterizedImage = try loadRasterizedImage(from: url, renderSize: renderSize)
        return try await makeVideoClip(fromRasterizedImage: rasterizedImage, duration: duration, renderSize: renderSize)
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
            titleImage = try makeFallbackTitleCardImage(renderSize: renderSize)
        }
        return try await makeVideoClip(fromRasterizedImage: titleImage, duration: duration, renderSize: renderSize)
        #else
        throw RenderError.exportFailed("Title card rendering requires AppKit support")
        #endif
    }

    #if canImport(AppKit)
    private func makeVideoClip(fromRasterizedImage image: CGImage, duration: CMTime, renderSize: CGSize) async throws -> URL {
        let frameRate = 30
        let totalFrames = max(Int(ceil(duration.seconds * Double(frameRate))), 1)
        let outputURL = temporaryClipURL()

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else {
            throw RenderError.exportFailed("Failed to add writer input for still image clip")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw RenderError.exportFailed(writer.error?.localizedDescription ?? "Unable to start writing")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            guard let pixelBuffer = makePixelBuffer(fromRasterizedImage: image, renderSize: renderSize) else {
                throw RenderError.exportFailed("Failed to create pixel buffer")
            }

            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw RenderError.exportFailed(writer.error?.localizedDescription ?? "Failed to append image frame")
            }
        }

        input.markAsFinished()
        try await finish(writer: writer)
        return outputURL
    }

    private func loadRasterizedImage(from url: URL, renderSize: CGSize) throws -> CGImage {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RenderError.exportFailed("Unable to load image source at \(url.path)")
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

        guard let decodedImage,
              let rasterizedImage = Self.rasterizedImage(decodedImage, renderSize: renderSize) else {
            throw RenderError.exportFailed("Unable to decode image at \(url.path)")
        }

        return rasterizedImage
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
              let safeImage = Self.rasterizedImage(rawImage, renderSize: renderSize) else {
            throw RenderError.exportFailed("Unable to create title card image")
        }

        return safeImage
    }

    private func makeFallbackTitleCardImage(renderSize: CGSize) throws -> CGImage {
        let width = max(1, Int(renderSize.width.rounded()))
        let height = max(1, Int(renderSize.height.rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw RenderError.exportFailed("Unable to create fallback title card image at \(width)x\(height)")
        }

        context.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else {
            throw RenderError.exportFailed("Unable to finalize fallback title card image at \(width)x\(height)")
        }
        return image
    }

    private static func rasterizedImage(_ sourceImage: CGImage, renderSize: CGSize) -> CGImage? {
        let width = max(1, Int(renderSize.width.rounded()))
        let height = max(1, Int(renderSize.height.rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
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

    private func makePixelBuffer(fromRasterizedImage image: CGImage, renderSize: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(renderSize.width),
            Int(renderSize.height),
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ] as CFDictionary,
            &pixelBuffer
        )

        guard result == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: renderSize))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: renderSize))

        return buffer
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
