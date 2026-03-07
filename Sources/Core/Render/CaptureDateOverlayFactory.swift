import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class CaptureDateOverlayFactory {
    public init() {}

    public func makeOverlayPlate(text: String, renderSize: CGSize) throws -> URL {
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
            throw RenderError.exportFailed("Unable to allocate capture-date overlay context at \(width)x\(height)")
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let fontSize = max(renderSize.height * 0.018, 18)
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, fontSize, nil)
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

        let horizontalMargin = max(renderSize.width * 0.025, 24)
        let verticalMargin = max(renderSize.height * 0.025, 20)
        let horizontalPadding = max(fontSize * 0.7, 12)
        let verticalPadding = max(fontSize * 0.45, 8)

        let boxRect = CGRect(
            x: max(renderSize.width - horizontalMargin - textWidth - (horizontalPadding * 2), 0),
            y: verticalMargin,
            width: min(textWidth + (horizontalPadding * 2), renderSize.width),
            height: min(textHeight + (verticalPadding * 2), renderSize.height)
        ).integral

        let backgroundPath = CGPath(
            roundedRect: boxRect,
            cornerWidth: max(fontSize * 0.55, 10),
            cornerHeight: max(fontSize * 0.55, 10),
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
            offset: CGSize(width: 0, height: -max(fontSize * 0.08, 1.5)),
            blur: max(fontSize * 0.18, 1.5),
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        )
        context.textPosition = CGPoint(
            x: boxRect.maxX - horizontalPadding - textWidth,
            y: boxRect.minY + verticalPadding + descent
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
