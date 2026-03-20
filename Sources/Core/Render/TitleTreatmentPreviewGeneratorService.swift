import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

package struct TitleTreatmentPreviewConfiguration: Sendable {
    package let inputFolderURL: URL
    package let recursive: Bool
    package let title: String
    package let caption: String
    package let monthYear: MonthYear
    package let outputRootDirectory: URL
    package let outputDirectoryOverride: URL?
    package let durationSeconds: Double
    package let renderSize: CGSize
    package let frameRate: Int
    package let treatments: [OpeningTitleTreatment]
    package let variationSeed: UInt64

    package init(
        inputFolderURL: URL,
        recursive: Bool = false,
        title: String = "March 2026",
        caption: String = "Fisher Family Videos",
        monthYear: MonthYear = MonthYear(month: 3, year: 2026),
        outputRootDirectory: URL,
        outputDirectoryOverride: URL? = nil,
        durationSeconds: Double = 7.5,
        renderSize: CGSize = CGSize(width: 1920, height: 1080),
        frameRate: Int = 30,
        treatments: [OpeningTitleTreatment] = OpeningTitleTreatment.allCases,
        variationSeed: UInt64 = 0x2026032001
    ) {
        self.inputFolderURL = inputFolderURL
        self.recursive = recursive
        self.title = title
        self.caption = caption
        self.monthYear = monthYear
        self.outputRootDirectory = outputRootDirectory
        self.outputDirectoryOverride = outputDirectoryOverride
        self.durationSeconds = durationSeconds
        self.renderSize = renderSize
        self.frameRate = frameRate
        self.treatments = treatments
        self.variationSeed = variationSeed
    }
}

package struct TitleTreatmentPreviewArtifact: Codable, Equatable, Sendable {
    package let index: Int
    package let treatment: String
    package let displayName: String
    package let category: String
    package let description: String
    package let clipFilename: String?
    package let earlyStillFilename: String
    package let lateStillFilename: String
    package let clipNote: String?
}

package struct TitleTreatmentPreviewManifest: Codable, Equatable, Sendable {
    package let generatedAt: String
    package let inputFolder: String
    package let title: String
    package let caption: String
    package let durationSeconds: Double
    package let width: Int
    package let height: Int
    package let frameRate: Int
    package let treatmentCount: Int
    package let artifacts: [TitleTreatmentPreviewArtifact]
}

package struct TitleTreatmentPreviewResult: Sendable {
    package let outputDirectory: URL
    package let manifestURL: URL
    package let indexURL: URL
    package let standardContactSheetURL: URL
    package let wildContactSheetURL: URL
    package let artifacts: [TitleTreatmentPreviewArtifact]
}

private struct TitleTreatmentBoardEntry {
    let artifact: TitleTreatmentPreviewArtifact
    let earlyImage: CGImage
    let lateImage: CGImage
}

package final class TitleTreatmentPreviewGeneratorService: @unchecked Sendable {
    private let discoveryService = FolderMediaDiscoveryService()
    private let clipFactory = StillImageClipFactory()
    private let ffmpegResolver = FFmpegBinaryResolver()

    package init() {}

    package func generate(config: TitleTreatmentPreviewConfiguration) async throws -> TitleTreatmentPreviewResult {
        #if canImport(AppKit)
        let items = try await discoveryService.discover(folderURL: config.inputFolderURL, recursive: config.recursive)
        guard !items.isEmpty else {
            throw RenderError.noRenderableMedia
        }

        let descriptor = try makeDescriptor(items: items, config: config)
        let outputDirectory = try makeOutputDirectory(for: config)
        let normalizedPreviewDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TitleTreatmentPreviewGenerator-previews-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: normalizedPreviewDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: normalizedPreviewDirectory) }

        let previewAssets = try await materializePreviewAssets(
            from: descriptor.previewItems,
            targetDimension: normalizedPreviewDimension(for: config.renderSize),
            outputDirectory: normalizedPreviewDirectory
        )
        let ffmpegURL = try resolvePreviewFFmpegURL()

        var artifacts: [TitleTreatmentPreviewArtifact] = []
        var boardEntries: [TitleTreatmentBoardEntry] = []
        artifacts.reserveCapacity(config.treatments.count)
        boardEntries.reserveCapacity(config.treatments.count)

        for (offset, treatment) in config.treatments.enumerated() {
            let index = offset + 1
            let filePrefix = String(format: "%02d-%@", index, treatment.rawValue)
            let clipURL = outputDirectory.appendingPathComponent(filePrefix).appendingPathExtension("mov")
            let captureTimes = stillCaptureTimes(durationSeconds: config.durationSeconds, frameRate: config.frameRate)
            let stillProgresses = captureTimes.map {
                guard config.durationSeconds > 0 else { return CGFloat.zero }
                return CGFloat(min(max($0.seconds / config.durationSeconds, 0), 1))
            }
            let renderer = try await clipFactory.makeTitleCardPreviewRenderer(
                descriptor: descriptor,
                previewAssets: previewAssets,
                renderSize: config.renderSize,
                dynamicRange: .sdr,
                treatment: treatment
            )

            let stills = try stillProgresses.map { try renderer.render(progress: $0) }
            guard stills.count == 2 else {
                throw RenderError.exportFailed("Expected two preview stills for treatment \(treatment.rawValue)")
            }

            let earlyStillURL = outputDirectory.appendingPathComponent("\(filePrefix)-early").appendingPathExtension("png")
            let lateStillURL = outputDirectory.appendingPathComponent("\(filePrefix)-late").appendingPathExtension("png")
            try writePNG(stills[0], to: earlyStillURL)
            try writePNG(stills[1], to: lateStillURL)

            let clipFilename: String?
            let clipNote: String?
            do {
                let generatedClipURL = try await clipFactory.makeTitleCardClip(
                    descriptor: descriptor,
                    previewAssets: previewAssets,
                    duration: CMTime(seconds: config.durationSeconds, preferredTimescale: 600),
                    renderSize: config.renderSize,
                    frameRate: config.frameRate,
                    dynamicRange: .sdr,
                    treatment: treatment
                )
                if FileManager.default.fileExists(atPath: clipURL.path) {
                    try FileManager.default.removeItem(at: clipURL)
                }
                try FileManager.default.moveItem(at: generatedClipURL, to: clipURL)
                clipFilename = clipURL.lastPathComponent
                clipNote = nil
            } catch {
                try exportMovieWithFFmpeg(
                    renderer: renderer,
                    durationSeconds: config.durationSeconds,
                    frameRate: config.frameRate,
                    ffmpegURL: ffmpegURL,
                    outputURL: clipURL
                )
                clipFilename = clipURL.lastPathComponent
                clipNote = "Video preview encoded via ffmpeg fallback."
            }

            let artifact = TitleTreatmentPreviewArtifact(
                index: index,
                treatment: treatment.rawValue,
                displayName: treatment.displayName,
                category: treatment.category.rawValue,
                description: treatment.shortDescription,
                clipFilename: clipFilename,
                earlyStillFilename: earlyStillURL.lastPathComponent,
                lateStillFilename: lateStillURL.lastPathComponent,
                clipNote: clipNote
            )
            artifacts.append(artifact)
            boardEntries.append(
                TitleTreatmentBoardEntry(
                    artifact: artifact,
                    earlyImage: stills[0],
                    lateImage: stills[1]
                )
            )
        }

        let standardEntries = boardEntries.filter { $0.artifact.category == OpeningTitleTreatmentCategory.standard.rawValue }
        let wildEntries = boardEntries.filter { $0.artifact.category == OpeningTitleTreatmentCategory.wild.rawValue }
        let standardContactSheetURL = outputDirectory.appendingPathComponent("contact-sheet-standard.png")
        let wildContactSheetURL = outputDirectory.appendingPathComponent("contact-sheet-wild.png")
        try writeContactSheet(
            entries: standardEntries,
            heading: "Standard Treatments",
            outputURL: standardContactSheetURL
        )
        try writeContactSheet(
            entries: wildEntries,
            heading: "Wild Treatments",
            outputURL: wildContactSheetURL
        )

        let manifest = TitleTreatmentPreviewManifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            inputFolder: config.inputFolderURL.path,
            title: config.title,
            caption: config.caption,
            durationSeconds: config.durationSeconds,
            width: Int(config.renderSize.width.rounded()),
            height: Int(config.renderSize.height.rounded()),
            frameRate: config.frameRate,
            treatmentCount: artifacts.count,
            artifacts: artifacts
        )
        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        try JSONEncoder.pretty.encode(manifest).write(to: manifestURL)

        let indexURL = outputDirectory.appendingPathComponent("index.html")
        try writeHTMLIndex(
            manifest: manifest,
            standardBoardFilename: standardContactSheetURL.lastPathComponent,
            wildBoardFilename: wildContactSheetURL.lastPathComponent,
            outputURL: indexURL
        )

        return TitleTreatmentPreviewResult(
            outputDirectory: outputDirectory,
            manifestURL: manifestURL,
            indexURL: indexURL,
            standardContactSheetURL: standardContactSheetURL,
            wildContactSheetURL: wildContactSheetURL,
            artifacts: artifacts
        )
        #else
        throw RenderError.exportFailed("Title treatment previews require AppKit support")
        #endif
    }

    private func makeDescriptor(
        items: [MediaItem],
        config: TitleTreatmentPreviewConfiguration
    ) throws -> OpeningTitleCardDescriptor {
        let style = StyleProfile(
            openingTitle: config.title,
            titleDurationSeconds: config.durationSeconds,
            crossfadeDurationSeconds: 0,
            stillImageDurationSeconds: 5,
            showCaptureDateOverlay: false,
            openingTitleCaptionMode: .custom,
            openingTitleCaptionText: config.caption
        )
        let timeline = TimelineBuilder(
            variationSeedGenerator: { config.variationSeed }
        ).buildTimeline(
            items: items,
            ordering: .captureDateAscendingStable,
            style: style,
            source: .folder(path: config.inputFolderURL, recursive: config.recursive),
            monthYear: config.monthYear
        )

        guard let firstSegment = timeline.segments.first,
              case let .titleCard(descriptor) = firstSegment.asset else {
            throw RenderError.exportFailed("Unable to build a title-card descriptor for preview generation")
        }
        return descriptor
    }

    private func normalizedPreviewDimension(for renderSize: CGSize) -> Int {
        let maxDimension = Int(max(renderSize.width, renderSize.height).rounded())
        return min(max(maxDimension, 720), 1440)
    }

    private func resolvePreviewFFmpegURL() throws -> URL {
        try ffmpegResolver.resolveProbeBinary(mode: .autoSystemThenBundled).ffmpegURL
    }

    private func materializePreviewAssets(
        from items: [MediaItem],
        targetDimension: Int,
        outputDirectory: URL
    ) async throws -> [StillImageClipFactory.TitleCardPreviewAsset] {
        var assets: [StillImageClipFactory.TitleCardPreviewAsset] = []
        assets.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            guard case let .file(sourceURL) = item.locator else {
                continue
            }

            do {
                let image = try await normalizedPreviewImage(
                    from: sourceURL,
                    mediaType: item.type,
                    targetDimension: targetDimension
                )
                let filename = String(format: "%02d-%@", index + 1, safeSlug(from: item.filename.isEmpty ? item.id : item.filename))
                let outputURL = outputDirectory.appendingPathComponent(filename).appendingPathExtension("png")
                try writePNG(image, to: outputURL)
                assets.append(
                    StillImageClipFactory.TitleCardPreviewAsset(
                        url: outputURL,
                        mediaType: .image,
                        filename: item.filename
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        return assets
    }

    private func normalizedPreviewImage(
        from url: URL,
        mediaType: MediaType,
        targetDimension: Int
    ) async throws -> CGImage {
        switch mediaType {
        case .image:
            return try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    throw RenderError.exportFailed("Unable to load preview source at \(url.path)")
                }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(targetDimension, 1)
                ]

                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                    ?? CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw RenderError.exportFailed("Unable to decode preview source at \(url.path)")
                }
                return image
            }

        case .video:
            let asset = AVURLAsset(url: url)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            imageGenerator.maximumSize = CGSize(width: targetDimension, height: targetDimension)
            imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            defer { imageGenerator.cancelAllCGImageGeneration() }

            do {
                return try await imageGenerator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            } catch {
                return try await imageGenerator.image(at: .zero).image
            }
        }
    }

    private func makeOutputDirectory(for config: TitleTreatmentPreviewConfiguration) throws -> URL {
        let fileManager = FileManager.default
        if let explicitDirectory = config.outputDirectoryOverride {
            try fileManager.createDirectory(at: explicitDirectory, withIntermediateDirectories: true)
            return explicitDirectory
        }

        try fileManager.createDirectory(at: config.outputRootDirectory, withIntermediateDirectories: true)
        let timestamp = Self.timestampFormatter.string(from: Date())
        let slug = safeSlug(from: config.title)
        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : "-\(attempt + 1)"
            let candidate = config.outputRootDirectory.appendingPathComponent("\(timestamp)-\(slug)\(suffix)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
                return candidate
            }
            attempt += 1
        }
    }

    private func stillCaptureTimes(durationSeconds: Double, frameRate: Int) -> [CMTime] {
        let frameDuration = max(1.0 / Double(max(frameRate, 1)), 0.001)
        let latestTime = max(durationSeconds - frameDuration, 0)
        let earlySeconds = min(durationSeconds * 0.18, latestTime)
        let lateSeconds = min(max(durationSeconds * 0.82, frameDuration), latestTime)
        return [
            CMTime(seconds: earlySeconds, preferredTimescale: 600),
            CMTime(seconds: lateSeconds, preferredTimescale: 600)
        ]
    }

    private func extractStillImages(
        from clipURL: URL,
        renderSize: CGSize,
        times: [CMTime]
    ) async throws -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clipURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = renderSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        var images: [CGImage] = []
        images.reserveCapacity(times.count)
        for time in times {
            let image = try await generator.image(at: time).image
            images.append(image)
        }
        return images
    }

    private func exportMovieWithFFmpeg(
        renderer: StillImageClipFactory.TitleCardPreviewRenderer,
        durationSeconds: Double,
        frameRate: Int,
        ffmpegURL: URL,
        outputURL: URL
    ) throws {
        let fileManager = FileManager.default
        let frameDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("TitleTreatmentPreviewFrames-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: frameDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: frameDirectory) }

        let totalFrames = max(Int(ceil(durationSeconds * Double(max(frameRate, 1)))), 1)
        let denominator = max(totalFrames - 1, 1)
        for frameIndex in 0..<totalFrames {
            let progress = CGFloat(frameIndex) / CGFloat(denominator)
            let image = try renderer.render(progress: progress)
            let frameURL = frameDirectory.appendingPathComponent(String(format: "frame-%05d", frameIndex + 1)).appendingPathExtension("png")
            try writePNG(image, to: frameURL)
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-y",
            "-framerate", "\(max(frameRate, 1))",
            "-i", frameDirectory.appendingPathComponent("frame-%05d.png").path,
            "-an",
            "-c:v", "libx264",
            "-preset", "fast",
            "-crf", "18",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            outputURL.path
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = [stdout, stderr]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")

        guard process.terminationStatus == 0, fileManager.fileExists(atPath: outputURL.path) else {
            throw RenderError.exportFailed(
                "FFmpeg preview movie export failed for \(outputURL.lastPathComponent) with status \(process.terminationStatus). Output: \(combined)"
            )
        }
    }

    private func writeContactSheet(
        entries: [TitleTreatmentBoardEntry],
        heading: String,
        outputURL: URL
    ) throws {
        #if canImport(AppKit)
        let columns = entries.count <= 1 ? 1 : 2
        let rows = Int(ceil(Double(entries.count) / Double(columns)))
        let cellWidth = 1060
        let cellHeight = 360
        let padding = 40
        let headingHeight = 120
        let width = columns * cellWidth + (padding * (columns + 1))
        let height = headingHeight + rows * cellHeight + padding * (rows + 1)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw RenderError.exportFailed("Unable to allocate contact sheet context")
        }

        context.setFillColor(CGColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawBoardText(
            heading,
            in: CGRect(x: padding, y: height - headingHeight + 24, width: width - padding * 2, height: 52),
            fontName: "AvenirNext-Bold",
            fontSize: 42,
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            context: context
        )

        for (offset, entry) in entries.enumerated() {
            let row = offset / columns
            let column = offset % columns
            let originX = padding + column * (cellWidth + padding)
            let originY = height - headingHeight - padding - ((row + 1) * cellHeight) - (row * padding)
            let cellRect = CGRect(x: originX, y: originY, width: cellWidth, height: cellHeight)
            drawBoardCell(entry: entry, rect: cellRect, context: context)
        }

        guard let image = context.makeImage() else {
            throw RenderError.exportFailed("Unable to build contact sheet image")
        }
        try writePNG(image, to: outputURL)
        #else
        throw RenderError.exportFailed("Contact sheets require AppKit support")
        #endif
    }

    private func drawBoardCell(
        entry: TitleTreatmentBoardEntry,
        rect: CGRect,
        context: CGContext
    ) {
        let backgroundPath = CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: CGColor(gray: 0, alpha: 0.22))
        context.addPath(backgroundPath)
        context.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1))
        context.fillPath()
        context.restoreGState()

        let labelRect = CGRect(x: rect.minX + 28, y: rect.maxY - 74, width: rect.width - 56, height: 48)
        drawBoardText(
            "\(entry.artifact.index). \(entry.artifact.displayName)",
            in: labelRect,
            fontName: "AvenirNext-Bold",
            fontSize: 28,
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            context: context
        )

        let descriptionRect = CGRect(x: rect.minX + 28, y: rect.maxY - 104, width: rect.width - 56, height: 28)
        drawBoardText(
            entry.artifact.description,
            in: descriptionRect,
            fontName: "AvenirNext-Regular",
            fontSize: 15,
            color: CGColor(red: 0.78, green: 0.81, blue: 0.86, alpha: 1),
            context: context
        )

        let thumbnailWidth = (rect.width - 84) / 2
        let thumbnailHeight = rect.height - 140
        let earlyRect = CGRect(x: rect.minX + 28, y: rect.minY + 24, width: thumbnailWidth, height: thumbnailHeight)
        let lateRect = CGRect(x: rect.minX + 56 + thumbnailWidth, y: rect.minY + 24, width: thumbnailWidth, height: thumbnailHeight)
        drawBoardThumbnail(entry.earlyImage, in: earlyRect, context: context)
        drawBoardThumbnail(entry.lateImage, in: lateRect, context: context)
    }

    private func drawBoardThumbnail(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        let fillRect = aspectFillRect(
            imageSize: CGSize(width: image.width, height: image.height),
            into: rect.size
        ).offsetBy(dx: rect.minX, dy: rect.minY)
        context.draw(image, in: fillRect)
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        context.setLineWidth(2)
        context.strokePath()
        context.restoreGState()
    }

    private func drawBoardText(
        _ text: String,
        in rect: CGRect,
        fontName: String,
        fontSize: CGFloat,
        color: CGColor,
        context: CGContext
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor(cgColor: color) ?? .white,
            .paragraphStyle: style
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGMutablePath()
        path.addRect(rect)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func writeHTMLIndex(
        manifest: TitleTreatmentPreviewManifest,
        standardBoardFilename: String,
        wildBoardFilename: String,
        outputURL: URL
    ) throws {
        let standardArtifacts = manifest.artifacts.filter { $0.category == OpeningTitleTreatmentCategory.standard.rawValue }
        let wildArtifacts = manifest.artifacts.filter { $0.category == OpeningTitleTreatmentCategory.wild.rawValue }
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Title Treatment Explorer</title>
          <style>
            :root { color-scheme: dark; }
            body { margin: 0; font-family: "Avenir Next", "Helvetica Neue", sans-serif; background: #0a0c10; color: #f6f7fb; }
            main { max-width: 1500px; margin: 0 auto; padding: 32px 28px 80px; }
            h1, h2 { margin: 0 0 16px; }
            p { color: #b7becc; line-height: 1.5; }
            .board { width: 100%; border-radius: 24px; border: 1px solid rgba(255,255,255,0.12); display: block; margin: 20px 0 32px; }
            .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 20px; }
            .card { background: #11151c; border: 1px solid rgba(255,255,255,0.10); border-radius: 22px; padding: 18px; box-shadow: 0 18px 44px rgba(0,0,0,0.24); }
            .card h3 { margin: 0 0 6px; font-size: 24px; }
            .card small { color: #8fd3ff; letter-spacing: 0.08em; text-transform: uppercase; }
            video { width: 100%; border-radius: 16px; margin: 14px 0 12px; background: #000; }
            .clip-note { margin: 14px 0 12px; padding: 14px 16px; border-radius: 14px; background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); color: #d6dbe6; }
            .stills { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; }
            .stills img { width: 100%; border-radius: 14px; display: block; border: 1px solid rgba(255,255,255,0.10); }
          </style>
        </head>
        <body>
          <main>
            <h1>Title Treatment Explorer</h1>
            <p>\(escapeHTML(manifest.title)) • \(escapeHTML(manifest.caption)) • \(manifest.treatmentCount) treatments • \(manifest.width)x\(manifest.height) • \(manifest.frameRate) fps • \(manifest.durationSeconds)s</p>
            <h2>Standard Treatments</h2>
            <img class="board" src="\(escapeHTML(standardBoardFilename))" alt="Standard treatment board">
            <div class="grid">
              \(htmlCards(for: standardArtifacts))
            </div>
            <h2 style="margin-top:40px;">Wild Treatments</h2>
            <img class="board" src="\(escapeHTML(wildBoardFilename))" alt="Wild treatment board">
            <div class="grid">
              \(htmlCards(for: wildArtifacts))
            </div>
          </main>
        </body>
        </html>
        """
        try html.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func htmlCards(for artifacts: [TitleTreatmentPreviewArtifact]) -> String {
        artifacts.map { artifact in
            let mediaBlock: String
            if let clipFilename = artifact.clipFilename {
                let noteBlock = artifact.clipNote.map { "<p class=\"clip-note\">\(escapeHTML($0))</p>" } ?? ""
                mediaBlock = "<video controls loop muted playsinline src=\"\(escapeHTML(clipFilename))\"></video>\(noteBlock)"
            } else {
                let note = artifact.clipNote ?? "Video preview unavailable."
                mediaBlock = "<p class=\"clip-note\">\(escapeHTML(note))</p>"
            }
            return """
            <article class="card">
              <small>\(escapeHTML(artifact.category))</small>
              <h3>\(escapeHTML(artifact.index.description)). \(escapeHTML(artifact.displayName))</h3>
              <p>\(escapeHTML(artifact.description))</p>
              \(mediaBlock)
              <div class="stills">
                <img src="\(escapeHTML(artifact.earlyStillFilename))" alt="\(escapeHTML(artifact.displayName)) early still">
                <img src="\(escapeHTML(artifact.lateStillFilename))" alt="\(escapeHTML(artifact.displayName)) late still">
              </div>
            </article>
            """
        }.joined(separator: "\n")
    }

    private func safeSlug(from value: String) -> String {
        let raw = value.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "preview-set" : trimmed
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let safeImage = try rasterizedPNGImage(from: image)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw RenderError.exportFailed("Unable to create PNG output at \(url.path)")
        }
        CGImageDestinationAddImage(destination, safeImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.exportFailed("Unable to finalize PNG output at \(url.path)")
        }
    }

    private func rasterizedPNGImage(from image: CGImage) throws -> CGImage {
        let width = max(image.width, 1)
        let height = max(image.height, 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw RenderError.exportFailed("Unable to allocate PNG rasterization context at \(width)x\(height)")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let safeImage = context.makeImage() else {
            throw RenderError.exportFailed("Unable to rasterize PNG output image at \(width)x\(height)")
        }
        return safeImage
    }

    private func aspectFillRect(imageSize: CGSize, into canvas: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let widthRatio = canvas.width / imageSize.width
        let heightRatio = canvas.height / imageSize.height
        let scale = max(widthRatio, heightRatio)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (canvas.width - width) / 2,
            y: (canvas.height - height) / 2,
            width: width,
            height: height
        )
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension Data {
    func write(to url: URL) throws {
        try write(to: url, options: .atomic)
    }
}
