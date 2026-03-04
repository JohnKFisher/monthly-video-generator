import AVFoundation
import Foundation
#if canImport(AppKit)
import AppKit
#endif

public final class StillImageClipFactory {
    public init() {}

    public func makeVideoClip(fromImageURL url: URL, duration: CMTime, renderSize: CGSize) async throws -> URL {
        #if canImport(AppKit)
        guard let image = NSImage(contentsOf: url) else {
            throw RenderError.exportFailed("Unable to load image at \(url.path)")
        }
        return try await makeVideoClip(fromImage: image, duration: duration, renderSize: renderSize)
        #else
        throw RenderError.exportFailed("Image rendering requires AppKit support")
        #endif
    }

    public func makeTitleCardClip(title: String, duration: CMTime, renderSize: CGSize) async throws -> URL {
        #if canImport(AppKit)
        let image = makeTitleCardImage(title: title, renderSize: renderSize)
        return try await makeVideoClip(fromImage: image, duration: duration, renderSize: renderSize)
        #else
        throw RenderError.exportFailed("Title card rendering requires AppKit support")
        #endif
    }

    #if canImport(AppKit)
    private func makeVideoClip(fromImage image: NSImage, duration: CMTime, renderSize: CGSize) async throws -> URL {
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

            guard let pixelBuffer = makePixelBuffer(from: image, renderSize: renderSize) else {
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

    private func makePixelBuffer(from image: NSImage, renderSize: CGSize) -> CVPixelBuffer? {
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
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: renderSize))

        guard let cgImage = image.cgImageRepresentation() else {
            return nil
        }

        let fittedRect = aspectFitRect(imageSize: CGSize(width: cgImage.width, height: cgImage.height), into: renderSize)
        context.draw(cgImage, in: fittedRect)

        return buffer
    }

    private func aspectFitRect(imageSize: CGSize, into canvas: CGSize) -> CGRect {
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

    private func makeTitleCardImage(title: String, renderSize: CGSize) -> NSImage {
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

        return image
    }

    private func temporaryClipURL() -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("MonthlyVideoGenerator", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }
    #endif
}

#if canImport(AppKit)
private extension NSImage {
    func cgImageRepresentation() -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
#endif
