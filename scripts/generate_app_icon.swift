#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

struct IconGeneratorOptions {
    let iconsetDirectory: URL
    let masterPNG: URL?
}

enum IconGeneratorError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case bitmapCreationFailed
    case pngEncodingFailed(String)

    var description: String {
        switch self {
        case .invalidArguments(let message):
            return message
        case .bitmapCreationFailed:
            return "Failed to create bitmap context for icon rendering."
        case .pngEncodingFailed(let filename):
            return "Failed to encode PNG for \(filename)."
        }
    }
}

let iconsetEntries: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func parseOptions(arguments: [String]) throws -> IconGeneratorOptions {
    var iconsetDirectory: URL?
    var masterPNG: URL?
    var index = 1

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--iconset-dir":
            index += 1
            guard index < arguments.count else {
                throw IconGeneratorError.invalidArguments("Missing value for --iconset-dir.")
            }
            iconsetDirectory = URL(fileURLWithPath: arguments[index])
        case "--master-png":
            index += 1
            guard index < arguments.count else {
                throw IconGeneratorError.invalidArguments("Missing value for --master-png.")
            }
            masterPNG = URL(fileURLWithPath: arguments[index])
        default:
            throw IconGeneratorError.invalidArguments(
                "Unknown argument '\(argument)'. Expected --iconset-dir <path> [--master-png <path>]."
            )
        }
        index += 1
    }

    guard let iconsetDirectory else {
        throw IconGeneratorError.invalidArguments("Usage: generate_app_icon.swift --iconset-dir <path> [--master-png <path>]")
    }

    return IconGeneratorOptions(iconsetDirectory: iconsetDirectory, masterPNG: masterPNG)
}

func roundedPath(in rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(
        roundedRect: rect,
        xRadius: radius,
        yRadius: radius
    )
}

func withShadow(color: NSColor, blur: CGFloat, offset: CGSize, draw: () -> Void) {
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func fillLinearGradient(path: NSBezierPath, colors: [NSColor], locations: [CGFloat], angle: CGFloat) {
    guard let gradient = NSGradient(colors: colors, atLocations: locations, colorSpace: .deviceRGB) else {
        return
    }
    gradient.draw(in: path, angle: angle)
}

func fillRadialGlow(
    context: CGContext,
    clipPath: NSBezierPath,
    center: CGPoint,
    startRadius: CGFloat,
    endRadius: CGFloat,
    startColor: NSColor,
    endColor: NSColor
) {
    let colors = [startColor.cgColor, endColor.cgColor] as CFArray
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) else {
        return
    }

    NSGraphicsContext.saveGraphicsState()
    clipPath.addClip()
    context.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: startRadius,
        endCenter: center,
        endRadius: endRadius,
        options: [.drawsAfterEndLocation]
    )
    NSGraphicsContext.restoreGraphicsState()
}

func makeBitmap(size: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw IconGeneratorError.bitmapCreationFailed
    }
    return bitmap
}

func image(from bitmap: NSBitmapImageRep, size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(bitmap)
    return image
}

func renderMasterIcon(size: Int) throws -> NSBitmapImageRep {
    let bitmap = try makeBitmap(size: size)
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconGeneratorError.bitmapCreationFailed
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.imageInterpolation = .high

    guard let context = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        throw IconGeneratorError.bitmapCreationFailed
    }

    let canvas = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
    context.clear(canvas)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tileInset = canvas.width * 0.085
    let tileRect = canvas.insetBy(dx: tileInset, dy: tileInset)
    let tileRadius = canvas.width * 0.19
    let tilePath = roundedPath(in: tileRect, radius: tileRadius)

    withShadow(
        color: NSColor.black.withAlphaComponent(0.22),
        blur: canvas.width * 0.06,
        offset: CGSize(width: 0, height: -canvas.width * 0.02)
    ) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        tilePath.fill()
    }

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()

    fillLinearGradient(
        path: tilePath,
        colors: [
            NSColor(srgbRed: 0.05, green: 0.35, blue: 0.40, alpha: 1.0),
            NSColor(srgbRed: 0.11, green: 0.23, blue: 0.40, alpha: 1.0),
            NSColor(srgbRed: 0.18, green: 0.14, blue: 0.27, alpha: 1.0)
        ],
        locations: [0.0, 0.55, 1.0],
        angle: -35
    )

    fillRadialGlow(
        context: context,
        clipPath: tilePath,
        center: CGPoint(x: tileRect.maxX - canvas.width * 0.14, y: tileRect.minY + canvas.width * 0.22),
        startRadius: canvas.width * 0.04,
        endRadius: canvas.width * 0.38,
        startColor: NSColor(srgbRed: 0.98, green: 0.55, blue: 0.41, alpha: 0.40),
        endColor: NSColor.clear
    )

    fillRadialGlow(
        context: context,
        clipPath: tilePath,
        center: CGPoint(x: tileRect.minX + canvas.width * 0.24, y: tileRect.maxY - canvas.width * 0.22),
        startRadius: canvas.width * 0.03,
        endRadius: canvas.width * 0.34,
        startColor: NSColor(srgbRed: 0.96, green: 0.78, blue: 0.48, alpha: 0.24),
        endColor: NSColor.clear
    )

    let glossRect = CGRect(
        x: tileRect.minX,
        y: tileRect.midY,
        width: tileRect.width,
        height: tileRect.height * 0.5
    )
    let glossPath = roundedPath(in: glossRect, radius: tileRadius * 0.75)
    fillLinearGradient(
        path: glossPath,
        colors: [
            NSColor.white.withAlphaComponent(0.16),
            NSColor.white.withAlphaComponent(0.02),
            NSColor.white.withAlphaComponent(0.0)
        ],
        locations: [0.0, 0.42, 1.0],
        angle: 90
    )

    let arcColor = NSColor.white.withAlphaComponent(0.08)
    arcColor.setStroke()
    let arcPath = NSBezierPath()
    arcPath.lineWidth = canvas.width * 0.028
    arcPath.appendArc(
        withCenter: CGPoint(x: tileRect.maxX - canvas.width * 0.14, y: tileRect.maxY - canvas.width * 0.11),
        radius: canvas.width * 0.34,
        startAngle: 148,
        endAngle: 274
    )
    arcPath.stroke()

    NSGraphicsContext.restoreGraphicsState()

    let cardRect = CGRect(
        x: tileRect.minX + tileRect.width * 0.21,
        y: tileRect.minY + tileRect.height * 0.18,
        width: tileRect.width * 0.58,
        height: tileRect.height * 0.60
    )
    let cardRadius = canvas.width * 0.065

    let backCardRect = cardRect.offsetBy(dx: canvas.width * 0.02, dy: -canvas.width * 0.02)
    let backCardPath = roundedPath(in: backCardRect, radius: cardRadius)
    NSColor.white.withAlphaComponent(0.12).setFill()
    backCardPath.fill()

    let cardShadowColor = NSColor.black.withAlphaComponent(0.18)
    withShadow(
        color: cardShadowColor,
        blur: canvas.width * 0.038,
        offset: CGSize(width: 0, height: -canvas.width * 0.012)
    ) {
        let cardPath = roundedPath(in: cardRect, radius: cardRadius)
        NSColor(srgbRed: 0.98, green: 0.96, blue: 0.93, alpha: 1.0).setFill()
        cardPath.fill()
    }

    let cardPath = roundedPath(in: cardRect, radius: cardRadius)
    NSColor(srgbRed: 0.80, green: 0.76, blue: 0.71, alpha: 0.45).setStroke()
    cardPath.lineWidth = canvas.width * 0.004
    cardPath.stroke()

    let headerRect = CGRect(
        x: cardRect.minX,
        y: cardRect.maxY - cardRect.height * 0.23,
        width: cardRect.width,
        height: cardRect.height * 0.23
    )
    let headerPath = roundedPath(in: headerRect, radius: cardRadius)
    NSGraphicsContext.saveGraphicsState()
    cardPath.addClip()
    fillLinearGradient(
        path: headerPath,
        colors: [
            NSColor(srgbRed: 0.95, green: 0.46, blue: 0.39, alpha: 1.0),
            NSColor(srgbRed: 0.97, green: 0.64, blue: 0.40, alpha: 1.0)
        ],
        locations: [0.0, 1.0],
        angle: 0
    )
    NSGraphicsContext.restoreGraphicsState()

    let ringY = headerRect.maxY - headerRect.height * 0.02
    let ringWidth = cardRect.width * 0.11
    let ringHeight = headerRect.height * 0.36
    for factor in [0.28, 0.72] {
        let ringRect = CGRect(
            x: cardRect.minX + cardRect.width * factor - ringWidth * 0.5,
            y: ringY - ringHeight,
            width: ringWidth,
            height: ringHeight
        )
        let ringPath = roundedPath(in: ringRect, radius: ringHeight * 0.42)
        NSColor(srgbRed: 0.13, green: 0.19, blue: 0.29, alpha: 0.96).setFill()
        ringPath.fill()

        let ringHighlightRect = ringRect.insetBy(dx: ringWidth * 0.18, dy: ringHeight * 0.18)
        let ringHighlight = roundedPath(in: ringHighlightRect, radius: ringHeight * 0.24)
        NSColor.white.withAlphaComponent(0.18).setFill()
        ringHighlight.fill()
    }

    let playDiscRect = CGRect(
        x: cardRect.midX - cardRect.width * 0.20,
        y: cardRect.minY + cardRect.height * 0.24,
        width: cardRect.width * 0.40,
        height: cardRect.width * 0.40
    )
    let playDiscPath = NSBezierPath(ovalIn: playDiscRect)
    fillLinearGradient(
        path: playDiscPath,
        colors: [
            NSColor(srgbRed: 0.11, green: 0.26, blue: 0.37, alpha: 1.0),
            NSColor(srgbRed: 0.15, green: 0.18, blue: 0.29, alpha: 1.0)
        ],
        locations: [0.0, 1.0],
        angle: -32
    )
    NSColor.white.withAlphaComponent(0.08).setStroke()
    playDiscPath.lineWidth = canvas.width * 0.004
    playDiscPath.stroke()

    let trianglePath = NSBezierPath()
    trianglePath.move(to: CGPoint(x: playDiscRect.minX + playDiscRect.width * 0.39, y: playDiscRect.minY + playDiscRect.height * 0.29))
    trianglePath.line(to: CGPoint(x: playDiscRect.minX + playDiscRect.width * 0.39, y: playDiscRect.maxY - playDiscRect.height * 0.29))
    trianglePath.line(to: CGPoint(x: playDiscRect.maxX - playDiscRect.width * 0.23, y: playDiscRect.midY))
    trianglePath.close()
    NSColor(srgbRed: 0.98, green: 0.89, blue: 0.75, alpha: 1.0).setFill()
    trianglePath.fill()

    let lineColor = NSColor(srgbRed: 0.64, green: 0.69, blue: 0.76, alpha: 0.85)
    let lineWidth = cardRect.width * 0.16
    let lineHeight = cardRect.height * 0.035
    let lineRadius = lineHeight * 0.5
    let lineX = cardRect.minX + cardRect.width * 0.14
    var lineY = cardRect.minY + cardRect.height * 0.15
    for index in 0..<3 {
        let widthScale = index == 1 ? 0.60 : 0.48
        let rect = CGRect(
            x: lineX,
            y: lineY,
            width: lineWidth * widthScale,
            height: lineHeight
        )
        let linePath = roundedPath(in: rect, radius: lineRadius)
        lineColor.withAlphaComponent(index == 2 ? 0.65 : 0.85).setFill()
        linePath.fill()
        lineY += lineHeight * 1.9
    }

    let highlightRect = CGRect(
        x: cardRect.maxX - cardRect.width * 0.27,
        y: cardRect.minY + cardRect.height * 0.13,
        width: cardRect.width * 0.13,
        height: cardRect.width * 0.13
    )
    let highlightPath = roundedPath(in: highlightRect, radius: highlightRect.width * 0.34)
    fillLinearGradient(
        path: highlightPath,
        colors: [
            NSColor(srgbRed: 0.97, green: 0.74, blue: 0.45, alpha: 1.0),
            NSColor(srgbRed: 0.95, green: 0.54, blue: 0.37, alpha: 1.0)
        ],
        locations: [0.0, 1.0],
        angle: -45
    )

    let footerRect = CGRect(
        x: cardRect.minX + cardRect.width * 0.56,
        y: cardRect.minY + cardRect.height * 0.12,
        width: cardRect.width * 0.16,
        height: cardRect.height * 0.035
    )
    let footerPath = roundedPath(in: footerRect, radius: lineRadius)
    NSColor(srgbRed: 0.24, green: 0.40, blue: 0.52, alpha: 0.82).setFill()
    footerPath.fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func writePNG(bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconGeneratorError.pngEncodingFailed(url.lastPathComponent)
    }
    try data.write(to: url)
}

func scaledBitmap(from source: NSImage, size: Int) throws -> NSBitmapImageRep {
    let bitmap = try makeBitmap(size: size)
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconGeneratorError.bitmapCreationFailed
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.imageInterpolation = .high
    source.draw(
        in: CGRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

do {
    let options = try parseOptions(arguments: CommandLine.arguments)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: options.iconsetDirectory, withIntermediateDirectories: true)

    let masterBitmap = try renderMasterIcon(size: 1024)
    let masterImage = image(from: masterBitmap, size: 1024)

    if let masterPNG = options.masterPNG {
        try fileManager.createDirectory(
            at: masterPNG.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writePNG(bitmap: masterBitmap, to: masterPNG)
    }

    for entry in iconsetEntries {
        let bitmap = entry.size == 1024 ? masterBitmap : try scaledBitmap(from: masterImage, size: entry.size)
        try writePNG(bitmap: bitmap, to: options.iconsetDirectory.appendingPathComponent(entry.name))
    }
} catch {
    fputs("generate_app_icon.swift: \(error)\n", stderr)
    exit(1)
}
