import AVFoundation
import Core
import Foundation
import ImageIO
import Photos
import PhotosIntegration
import UniformTypeIdentifiers

typealias HEVCBakeoffProgressHandler = (@MainActor @Sendable (Double) -> Void)?
typealias HEVCBakeoffStatusHandler = (@MainActor @Sendable (String) -> Void)?

@MainActor
protocol HEVCBakeoffRunning {
    func run(
        statusHandler: HEVCBakeoffStatusHandler,
        progressHandler: HEVCBakeoffProgressHandler
    ) async throws -> HEVCBakeoffCompletionSummary
}

struct HEVCBakeoffCompletionSummary: Sendable {
    struct CandidateArtifact: Sendable {
        let label: String
        let outputURL: URL
        let reportURL: URL
        let diagnosticsLogURL: URL
    }

    let albumTitle: String
    let bundleRootURL: URL
    let manifestURL: URL
    let indexURL: URL
    let candidates: [CandidateArtifact]
}

enum HEVCBakeoffError: LocalizedError {
    case unauthorized(PHAuthorizationStatus)
    case albumResolutionFailed(matchCount: Int)
    case missingDiagnosticsLog(String)
    case missingExecutionDetails(String)
    case missingOutputFileSize(String)

    var errorDescription: String? {
        switch self {
        case let .unauthorized(status):
            return "Photos access is not authorized for the app (status: \(status.rawValue))."
        case let .albumResolutionFailed(matchCount):
            return "Expected exactly one Photos album matching Test Export, found \(matchCount)."
        case let .missingDiagnosticsLog(label):
            return "Bakeoff candidate \(label) finished without a diagnostics log."
        case let .missingExecutionDetails(label):
            return "Bakeoff candidate \(label) finished without execution details."
        case let .missingOutputFileSize(label):
            return "Bakeoff candidate \(label) finished without a measurable final file size."
        }
    }
}

@MainActor
struct HEVCBakeoffRunner {
    private struct CandidateDefinition {
        let label: String
        let preset: String
        let crf: Int
        let tuningOverride: FinalHEVCTuningOverride?
    }

    private enum ProgressiveIntermediateUsage: String, Codable {
        case notApplicable
        case hardwareOnly
        case softwareFallbackUsed
        case mixed
    }

    private struct CandidateCommandSummaryManifest: Codable {
        let stageLabel: String
        let renderIntent: String
        let encoder: String
        let elapsedSeconds: Double
        let outputFileSizeBytes: UInt64
    }

    private struct CandidateManifestEntry: Codable {
        let label: String
        let preset: String
        let crf: Int
        let finalVideoPath: String
        let runReportPath: String
        let diagnosticsLogPath: String
        let framePaths: [String]
        let outputFileSizeBytes: Int64
        let renderElapsedSeconds: Double
        let renderBackendSummary: String?
        let renderBackendInfo: RenderBackendInfo?
        let resolvedVideoInfo: ResolvedRenderVideoInfo?
        let progressiveIntermediateUsage: ProgressiveIntermediateUsage
        let intermediateEncoders: [String]
        let commandSummaries: [CandidateCommandSummaryManifest]
    }

    private struct BakeoffManifest: Codable {
        let generatedAt: Date
        let albumTitle: String
        let albumLocalIdentifier: String
        let bundleRootPath: String
        let normalizedFramePositions: [Double]
        let candidates: [CandidateManifestEntry]
    }

    private let normalizedFramePositions: [Double] = [0.05, 0.20, 0.50, 0.80, 0.95]
    private let reportService: RunReportService
    private let exportProfileManager: ExportProfileManager
    private let coordinator: RenderCoordinator
    private let photoDiscovery: PhotoKitMediaDiscoveryService
    private let photoMaterializer: PhotoKitAssetMaterializer
    private let fileManager: FileManager

    init(
        reportService: RunReportService = RunReportService(),
        exportProfileManager: ExportProfileManager = ExportProfileManager(),
        coordinator: RenderCoordinator = RenderCoordinator(),
        photoDiscovery: PhotoKitMediaDiscoveryService = PhotoKitMediaDiscoveryService(),
        photoMaterializer: PhotoKitAssetMaterializer = PhotoKitAssetMaterializer(),
        fileManager: FileManager = .default
    ) {
        self.reportService = reportService
        self.exportProfileManager = exportProfileManager
        self.coordinator = coordinator
        self.photoDiscovery = photoDiscovery
        self.photoMaterializer = photoMaterializer
        self.fileManager = fileManager
    }

    func run(
        statusHandler: HEVCBakeoffStatusHandler = nil,
        progressHandler: HEVCBakeoffProgressHandler = nil
    ) async throws -> HEVCBakeoffCompletionSummary {
        let authorizationStatus = await resolvedAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            throw HEVCBakeoffError.unauthorized(authorizationStatus)
        }

        statusHandler?("Resolving Photos album Test Export...")
        progressHandler?(0.01)

        let albums = try await photoDiscovery.discoverAlbums()
        let matchingAlbums = albums.filter {
            $0.title.compare("Test Export", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard matchingAlbums.count == 1, let album = matchingAlbums.first else {
            throw HEVCBakeoffError.albumResolutionFailed(matchCount: matchingAlbums.count)
        }

        let items = try await photoDiscovery.discover(albumLocalIdentifier: album.localIdentifier)
        let bundleRoot = try makeBakeoffBundleRoot(albumTitle: album.title)
        let exportResolution = exportProfileManager.resolveProfile(
            for: exportProfileManager.defaultProfile(),
            items: items
        )
        let style = StyleProfile(
            openingTitle: album.title,
            titleDurationSeconds: 10.0,
            crossfadeDurationSeconds: 1.0,
            stillImageDurationSeconds: 5.0,
            showCaptureDateOverlay: true
        )

        var candidateEntries: [CandidateManifestEntry] = []
        var candidateArtifacts: [HEVCBakeoffCompletionSummary.CandidateArtifact] = []
        let candidateDefinitions = makeCandidateDefinitions()

        for (candidateIndex, candidate) in candidateDefinitions.enumerated() {
            let candidateStartProgress = Double(candidateIndex) / Double(candidateDefinitions.count)
            let candidateEndProgress = Double(candidateIndex + 1) / Double(candidateDefinitions.count)
            statusHandler?("Rendering bakeoff candidate \(candidateIndex + 1)/\(candidateDefinitions.count): \(candidate.label)")
            progressHandler?(candidateStartProgress)

            let candidateDirectory = bundleRoot.appendingPathComponent(candidate.label, isDirectory: true)
            try fileManager.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)

            let request = RenderRequest(
                source: .photosLibrary(scope: .album(localIdentifier: album.localIdentifier, title: album.title)),
                monthYear: nil,
                ordering: .captureDateAscendingStable,
                style: style,
                export: exportResolution.effectiveProfile,
                output: OutputTarget(directory: candidateDirectory, baseFilename: candidate.label)
            )
            let preparation = coordinator.prepareFromItems(
                items,
                request: request,
                additionalWarnings: exportResolution.warnings.map(\.message)
            )
            let result = try await coordinator.render(
                preparation: preparation,
                request: request,
                photoMaterializer: photoMaterializer,
                writeDiagnosticsLog: true,
                progressHandler: { reportedProgress in
                    let clamped = min(max(reportedProgress, 0), 1)
                    let mapped = candidateStartProgress + (candidateEndProgress - candidateStartProgress) * clamped
                    Task { @MainActor in
                        progressHandler?(mapped)
                    }
                },
                statusHandler: { candidateStatus in
                    let message = "Bakeoff \(candidateIndex + 1)/\(candidateDefinitions.count): \(candidateStatus)"
                    Task { @MainActor in
                        statusHandler?(message)
                    }
                },
                executionOptions: RenderExecutionOptions(finalHEVCTuningOverride: candidate.tuningOverride)
            )

            guard let executionDetails = result.executionDetails else {
                throw HEVCBakeoffError.missingExecutionDetails(candidate.label)
            }
            guard let diagnosticsLogURL = result.diagnosticsLogURL else {
                throw HEVCBakeoffError.missingDiagnosticsLog(candidate.label)
            }

            statusHandler?("Extracting stills for \(candidate.label)...")
            let preservedDiagnosticsURL = try preserveArtifact(
                diagnosticsLogURL,
                preferredDestination: candidateDirectory.appendingPathComponent("diagnostics.log")
            )
            let frameURLs = try await extractStillFrames(
                from: result.outputURL,
                normalizedPositions: normalizedFramePositions,
                into: candidateDirectory
            )
            let outputFileSizeBytes = executionDetails.outputFileSizeBytes ?? fileSizeBytes(at: result.outputURL)
            guard let resolvedOutputFileSizeBytes = outputFileSizeBytes else {
                throw HEVCBakeoffError.missingOutputFileSize(candidate.label)
            }

            let report = reportService.makeReport(
                request: request,
                preparation: preparation,
                outputURL: result.outputURL,
                diagnosticsLogURL: preservedDiagnosticsURL,
                renderBackendSummary: result.backendSummary,
                outputFileSizeBytes: resolvedOutputFileSizeBytes,
                renderElapsedSeconds: executionDetails.elapsedSeconds,
                renderBackendInfo: result.backendInfo,
                resolvedVideoInfo: result.resolvedVideoInfo,
                finalHEVCTuningPreset: candidate.preset,
                finalHEVCTuningCRF: candidate.crf
            )
            let reportURL = candidateDirectory.appendingPathComponent("run-report.json")
            try reportService.write(report, to: reportURL)

            let commandSummaries = executionDetails.commandSummaries.map {
                CandidateCommandSummaryManifest(
                    stageLabel: $0.stageLabel,
                    renderIntent: $0.renderIntent.rawValue,
                    encoder: $0.encoder,
                    elapsedSeconds: $0.elapsedSeconds,
                    outputFileSizeBytes: $0.outputFileSizeBytes
                )
            }
            let intermediateCommandSummaries = executionDetails.commandSummaries.filter { summary in
                if summary.renderIntent == .presentationIntermediate {
                    return true
                }
                return summary.renderIntent == .intermediateChunk
            }
            let intermediateEncoders = Array(
                Set(intermediateCommandSummaries.map { commandSummary in commandSummary.encoder })
            ).sorted()
            candidateEntries.append(
                CandidateManifestEntry(
                    label: candidate.label,
                    preset: candidate.preset,
                    crf: candidate.crf,
                    finalVideoPath: relativePath(from: bundleRoot, to: result.outputURL),
                    runReportPath: relativePath(from: bundleRoot, to: reportURL),
                    diagnosticsLogPath: relativePath(from: bundleRoot, to: preservedDiagnosticsURL),
                    framePaths: frameURLs.map { relativePath(from: bundleRoot, to: $0) },
                    outputFileSizeBytes: resolvedOutputFileSizeBytes,
                    renderElapsedSeconds: executionDetails.elapsedSeconds,
                    renderBackendSummary: result.backendSummary,
                    renderBackendInfo: result.backendInfo,
                    resolvedVideoInfo: result.resolvedVideoInfo,
                    progressiveIntermediateUsage: progressiveIntermediateUsage(for: intermediateCommandSummaries),
                    intermediateEncoders: intermediateEncoders,
                    commandSummaries: commandSummaries
                )
            )
            candidateArtifacts.append(
                HEVCBakeoffCompletionSummary.CandidateArtifact(
                    label: candidate.label,
                    outputURL: result.outputURL,
                    reportURL: reportURL,
                    diagnosticsLogURL: preservedDiagnosticsURL
                )
            )
            progressHandler?(candidateEndProgress)
        }

        statusHandler?("Writing bakeoff comparison bundle...")
        let manifest = BakeoffManifest(
            generatedAt: Date(),
            albumTitle: album.title,
            albumLocalIdentifier: album.localIdentifier,
            bundleRootPath: bundleRoot.path,
            normalizedFramePositions: normalizedFramePositions,
            candidates: candidateEntries
        )
        try writeBakeoffBundleArtifacts(manifest: manifest, bundleRoot: bundleRoot)

        let manifestURL = bundleRoot.appendingPathComponent("manifest.json")
        let indexURL = bundleRoot.appendingPathComponent("index.html")
        progressHandler?(1.0)
        statusHandler?("HEVC bakeoff complete.")
        return HEVCBakeoffCompletionSummary(
            albumTitle: album.title,
            bundleRootURL: bundleRoot,
            manifestURL: manifestURL,
            indexURL: indexURL,
            candidates: candidateArtifacts
        )
    }

    private func resolvedAuthorizationStatus() async -> PHAuthorizationStatus {
        let currentStatus = photoDiscovery.authorizationStatus()
        if currentStatus == .notDetermined {
            return await photoDiscovery.requestAuthorization()
        }
        return currentStatus
    }

    private func makeCandidateDefinitions() -> [CandidateDefinition] {
        [
            CandidateDefinition(label: "baseline-crf17-medium", preset: "medium", crf: 17, tuningOverride: nil),
            CandidateDefinition(
                label: "candidate-crf18-medium",
                preset: "medium",
                crf: 18,
                tuningOverride: FinalHEVCTuningOverride(preset: "medium", crf: 18)
            ),
            CandidateDefinition(
                label: "candidate-crf19-medium",
                preset: "medium",
                crf: 19,
                tuningOverride: FinalHEVCTuningOverride(preset: "medium", crf: 19)
            ),
            CandidateDefinition(
                label: "candidate-crf18-slow",
                preset: "slow",
                crf: 18,
                tuningOverride: FinalHEVCTuningOverride(preset: "slow", crf: 18)
            )
        ]
    }

    private func makeBakeoffBundleRoot(albumTitle: String) throws -> URL {
        let bundleRoot = repositoryRootURL()
            .appendingPathComponent("tmp/export-bakeoffs", isDirectory: true)
            .appendingPathComponent("\(timestamp())-\(sanitizePathComponent(albumTitle))", isDirectory: true)
        try fileManager.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        return bundleRoot
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func preserveArtifact(_ sourceURL: URL, preferredDestination: URL) throws -> URL {
        let source = sourceURL.standardizedFileURL
        let destination = preferredDestination.standardizedFileURL
        if source == destination {
            return sourceURL
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func extractStillFrames(
        from videoURL: URL,
        normalizedPositions: [Double],
        into directory: URL
    ) async throws -> [URL] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = max(duration.seconds, 0.001)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero

        var frameURLs: [URL] = []
        for position in normalizedPositions {
            let clampedPosition = min(max(position, 0), 1)
            let seconds = min(durationSeconds * clampedPosition, max(durationSeconds - 0.001, 0))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            let frameURL = directory.appendingPathComponent(frameFilename(for: clampedPosition))
            try writePNG(image, to: frameURL)
            frameURLs.append(frameURL)
        }
        return frameURLs
    }

    private func frameFilename(for normalizedPosition: Double) -> String {
        let percentage = Int((normalizedPosition * 100).rounded())
        return String(format: "frame-%02d.png", percentage)
    }

    private func progressiveIntermediateUsage(for summaries: [RenderCommandSummary]) -> ProgressiveIntermediateUsage {
        guard !summaries.isEmpty else {
            return .notApplicable
        }
        let encoders = Set(summaries.map(\.encoder))
        if encoders.contains("libx265") {
            return encoders == Set(["libx265"]) ? .softwareFallbackUsed : .mixed
        }
        if encoders == Set(["hevc_videotoolbox"]) {
            return .hardwareOnly
        }
        return .mixed
    }

    private func writeBakeoffBundleArtifacts(manifest: BakeoffManifest, bundleRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: bundleRoot.appendingPathComponent("manifest.json"))
        try makeIndexHTML(manifest: manifest).write(
            to: bundleRoot.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeIndexHTML(manifest: BakeoffManifest) -> String {
        let candidateSections = manifest.candidates.map { candidate in
            let framesHTML = candidate.framePaths.map { framePath in
                """
                <figure class="frame">
                  <img src="\(htmlEscaped(framePath))" alt="\(htmlEscaped(candidate.label)) still" loading="lazy">
                  <figcaption>\(htmlEscaped((framePath as NSString).lastPathComponent))</figcaption>
                </figure>
                """
            }.joined(separator: "\n")

            let backendInfoSummary: String
            if let backendInfo = candidate.renderBackendInfo {
                let source = backendInfo.binarySource?.displayLabel ?? "Unknown"
                let encoder = backendInfo.encoder ?? "unknown"
                backendInfoSummary = "\(source) / \(encoder)"
            } else {
                backendInfoSummary = "Unavailable"
            }

            let resolvedVideoInfoSummary: String
            if let resolvedVideoInfo = candidate.resolvedVideoInfo {
                resolvedVideoInfoSummary =
                    "\(resolvedVideoInfo.width)x\(resolvedVideoInfo.height) @ \(resolvedVideoInfo.frameRate) fps"
            } else {
                resolvedVideoInfoSummary = "Unavailable"
            }

            return """
            <section class="candidate">
              <h2>\(htmlEscaped(candidate.label))</h2>
              <div class="meta-grid">
                <div><strong>Preset</strong><span>\(htmlEscaped(candidate.preset))</span></div>
                <div><strong>CRF</strong><span>\(candidate.crf)</span></div>
                <div><strong>Final file size</strong><span>\(htmlEscaped(formatBytes(candidate.outputFileSizeBytes)))</span></div>
                <div><strong>Total render time</strong><span>\(htmlEscaped(formatSeconds(candidate.renderElapsedSeconds)))</span></div>
                <div><strong>Backend</strong><span>\(htmlEscaped(candidate.renderBackendSummary ?? "Unavailable"))</span></div>
                <div><strong>Backend detail</strong><span>\(htmlEscaped(backendInfoSummary))</span></div>
                <div><strong>Resolved video</strong><span>\(htmlEscaped(resolvedVideoInfoSummary))</span></div>
                <div><strong>Progressive intermediates</strong><span>\(htmlEscaped(candidate.progressiveIntermediateUsage.rawValue))</span></div>
                <div><strong>Intermediate encoders</strong><span>\(htmlEscaped(candidate.intermediateEncoders.joined(separator: ", ").nonEmptyOrFallback("n/a")))</span></div>
              </div>
              <p class="links">
                <a href="\(htmlEscaped(candidate.finalVideoPath))">Full video</a>
                <a href="\(htmlEscaped(candidate.runReportPath))">Run report JSON</a>
                <a href="\(htmlEscaped(candidate.diagnosticsLogPath))">Diagnostics log</a>
              </p>
              <div class="frames">
                \(framesHTML)
              </div>
            </section>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>HEVC Bakeoff: \(htmlEscaped(manifest.albumTitle))</title>
          <style>
            :root {
              color-scheme: light dark;
              --bg: #f5f1e8;
              --card: rgba(255, 255, 255, 0.82);
              --ink: #1e1d1b;
              --line: rgba(34, 30, 24, 0.16);
              --accent: #9e3d2b;
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --bg: #181512;
                --card: rgba(34, 29, 24, 0.88);
                --ink: #f4ede2;
                --line: rgba(255, 244, 227, 0.12);
                --accent: #f09d62;
              }
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              font-family: "Avenir Next", "Helvetica Neue", sans-serif;
              background:
                radial-gradient(circle at top left, rgba(219, 142, 87, 0.14), transparent 38%),
                linear-gradient(180deg, rgba(255,255,255,0.3), transparent 25%),
                var(--bg);
              color: var(--ink);
            }
            main {
              max-width: 1280px;
              margin: 0 auto;
              padding: 32px 20px 56px;
            }
            h1, h2 { margin: 0; }
            .intro {
              margin-bottom: 24px;
              padding: 24px;
              border: 1px solid var(--line);
              border-radius: 20px;
              background: var(--card);
              backdrop-filter: blur(14px);
            }
            .intro p {
              margin: 10px 0 0;
              line-height: 1.5;
            }
            .candidate {
              margin-top: 22px;
              padding: 22px;
              border: 1px solid var(--line);
              border-radius: 22px;
              background: var(--card);
              backdrop-filter: blur(12px);
            }
            .meta-grid {
              display: grid;
              grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
              gap: 12px;
              margin: 18px 0 14px;
            }
            .meta-grid div {
              padding: 12px 14px;
              border-radius: 14px;
              border: 1px solid var(--line);
              background: rgba(255,255,255,0.34);
            }
            .meta-grid strong,
            .meta-grid span {
              display: block;
            }
            .meta-grid strong {
              font-size: 0.82rem;
              letter-spacing: 0.03em;
              text-transform: uppercase;
              opacity: 0.7;
              margin-bottom: 6px;
            }
            .links {
              display: flex;
              flex-wrap: wrap;
              gap: 14px;
              margin: 0 0 18px;
            }
            a {
              color: var(--accent);
              text-decoration-thickness: 0.08em;
              text-underline-offset: 0.16em;
            }
            .frames {
              display: grid;
              grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
              gap: 16px;
            }
            .frame {
              margin: 0;
            }
            .frame img {
              width: 100%;
              display: block;
              border-radius: 16px;
              border: 1px solid var(--line);
              background: rgba(0,0,0,0.08);
            }
            .frame figcaption {
              margin-top: 8px;
              font-size: 0.88rem;
              opacity: 0.72;
            }
          </style>
        </head>
        <body>
          <main>
            <section class="intro">
              <h1>HEVC Bakeoff: \(htmlEscaped(manifest.albumTitle))</h1>
              <p>Generated \(htmlEscaped(manifest.generatedAt.formatted(date: .abbreviated, time: .standard))) from Photos album \(htmlEscaped(manifest.albumTitle)). The full video is the source of truth for visual review; the stills are for faster side-by-side scanning.</p>
            </section>
            \(candidateSections)
          </main>
        </body>
        </html>
        """
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func formatSeconds(_ value: Double) -> String {
        String(format: "%.2f s", max(value, 0))
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func sanitizePathComponent(_ value: String) -> String {
        let lowered = value.lowercased()
        let filtered = lowered.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let collapsed = String(filtered)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "export-bakeoff" : collapsed
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func relativePath(from root: URL, to url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if targetPath.hasPrefix(prefix) {
            return String(targetPath.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }

    private func fileSizeBytes(at url: URL) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        if let size = attributes[.size] as? Int {
            return Int64(size)
        }
        return nil
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "HEVCBakeoffRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination at \(url.path)."]
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "HEVCBakeoffRunner",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG at \(url.path)."]
            )
        }
    }
}

extension HEVCBakeoffRunner: HEVCBakeoffRunning {}

private extension String {
    func nonEmptyOrFallback(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
