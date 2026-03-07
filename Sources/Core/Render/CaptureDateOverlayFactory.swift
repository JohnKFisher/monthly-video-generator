import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CaptureDateOverlayLayout: Equatable, Sendable {
    let fontSize: CGFloat
    let horizontalMargin: Int
    let verticalMargin: Int
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat

    static func metrics(for renderSize: CGSize) -> CaptureDateOverlayLayout {
        let fontSize = max(renderSize.height * 0.018, 18)
        return CaptureDateOverlayLayout(
            fontSize: fontSize,
            horizontalMargin: Int(ceil(max(renderSize.width * 0.025, 24))),
            verticalMargin: Int(ceil(max(renderSize.height * 0.025, 20))),
            horizontalPadding: max(fontSize * 0.7, 12),
            verticalPadding: max(fontSize * 0.45, 8),
            cornerRadius: max(fontSize * 0.55, 10)
        )
    }
}

public final class CaptureDateOverlayFactory {
    public init() {}

    public func makeOverlayPlate(text: String, renderSize: CGSize) throws -> URL {
        let layout = CaptureDateOverlayLayout.metrics(for: renderSize)
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, layout.fontSize, nil)
        let textColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.94)
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): textColor
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedText)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textHeight = ascent + descent + leading

        // Keep the rasterized plate tightly cropped to the badge itself. Full-frame
        // transparent overlays explode FFmpeg memory usage on long 4K HDR runs.
        let width = max(1, Int(ceil(textWidth + (layout.horizontalPadding * 2))))
        let height = max(1, Int(ceil(textHeight + (layout.verticalPadding * 2))))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw RenderError.exportFailed("Unable to allocate capture-date overlay context at \(width)x\(height)")
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let boxRect = CGRect(x: 0, y: 0, width: width, height: height).integral

        let backgroundPath = CGPath(
            roundedRect: boxRect,
            cornerWidth: layout.cornerRadius,
            cornerHeight: layout.cornerRadius,
            transform: nil
        )
        context.saveGState()
        context.addPath(backgroundPath)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.26))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.textMatrix = .identity
        context.setShadow(
            offset: CGSize(width: 0, height: -max(layout.fontSize * 0.08, 1.5)),
            blur: max(layout.fontSize * 0.18, 1.5),
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        )
        context.textPosition = CGPoint(
            x: layout.horizontalPadding,
            y: layout.verticalPadding + descent
        )
        CTLineDraw(line, context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw RenderError.exportFailed("Unable to finalize capture-date overlay image")
        }

        let outputURL = temporaryOverlayURL()
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw RenderError.exportFailed("Unable to create capture-date overlay destination at \(outputURL.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.exportFailed("Unable to write capture-date overlay image at \(outputURL.path)")
        }

        return outputURL
    }

    private func temporaryOverlayURL() -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("MonthlyVideoGenerator/CaptureDateOverlays", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    }
}
