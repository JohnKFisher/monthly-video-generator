import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Photos
import PhotosIntegration
import UniformTypeIdentifiers
import XCTest
@testable import Core

final class ManualExportBakeoffTests: XCTestCase {
    private enum TestError: Error, Equatable {
        case duplicateRequestedCandidateLabel(String)
        case unknownCandidateLabel(String)
    }

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

    private struct CandidateCommandSummaryManifest: Codable, Equatable {
        let stageLabel: String
        let renderIntent: String
        let encoder: String
        let elapsedSeconds: Double
        let outputFileSizeBytes: UInt64
    }

    private struct CandidateManifestEntry: Codable, Equatable {
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
        let presentationTimingAudits: [ProgressivePresentationTimingAudit]
    }

    private struct BakeoffManifest: Codable, Equatable {
        let generatedAt: Date
        let albumTitle: String
        let albumLocalIdentifier: String
        let bundleRootPath: String
        let normalizedFramePositions: [Double]
        let candidates: [CandidateManifestEntry]
    }

    private let normalizedFramePositions: [Double] = [0.05, 0.20, 0.50, 0.80, 0.95]
    private let reportService = RunReportService()

    func testBakeoffBundleWriterProducesIndexAndManifest() throws {
        let bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualExportBakeoffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleRoot) }

        let candidateDirectory = bundleRoot.appendingPathComponent("baseline-crf17-medium", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)

        let finalVideoURL = candidateDirectory.appendingPathComponent("baseline-crf17-medium.mp4")
        let reportURL = candidateDirectory.appendingPathComponent("run-report.json")
        let diagnosticsURL = candidateDirectory.appendingPathComponent("diagnostics.log")
        try Data("video".utf8).write(to: finalVideoURL)
        try Data("{}".utf8).write(to: reportURL)
        try Data("diagnostics".utf8).write(to: diagnosticsURL)

        let frameURLs = [
            candidateDirectory.appendingPathComponent("frame-05.png"),
            candidateDirectory.appendingPathComponent("frame-20.png"),
            candidateDirectory.appendingPathComponent("frame-50.png"),
            candidateDirectory.appendingPathComponent("frame-80.png"),
            candidateDirectory.appendingPathComponent("frame-95.png")
        ]
        for (index, frameURL) in frameURLs.enumerated() {
            try writeSolidPNG(
                color: CGColor(
                    red: CGFloat(index) / 5.0,
                    green: 0.4,
                    blue: 0.8,
                    alpha: 1
                ),
                to: frameURL
            )
        }

        let manifest = BakeoffManifest(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            albumTitle: "Test Export",
            albumLocalIdentifier: "album-123",
            bundleRootPath: bundleRoot.path,
            normalizedFramePositions: normalizedFramePositions,
            candidates: [
                CandidateManifestEntry(
                    label: "baseline-crf17-medium",
                    preset: "medium",
                    crf: 17,
                    finalVideoPath: relativePath(from: bundleRoot, to: finalVideoURL),
                    runReportPath: relativePath(from: bundleRoot, to: reportURL),
                    diagnosticsLogPath: relativePath(from: bundleRoot, to: diagnosticsURL),
                    framePaths: frameURLs.map { relativePath(from: bundleRoot, to: $0) },
                    outputFileSizeBytes: 12_345_678,
                    renderElapsedSeconds: 42.5,
                    renderBackendSummary: "FFmpeg HDR backend: bundled ffmpeg + libx265",
                    renderBackendInfo: RenderBackendInfo(binarySource: .bundled, encoder: "libx265"),
                    resolvedVideoInfo: ResolvedRenderVideoInfo(width: 3840, height: 2160, frameRate: 60),
                    progressiveIntermediateUsage: .hardwareOnly,
                    intermediateEncoders: ["hevc_videotoolbox"],
                    commandSummaries: [
                        CandidateCommandSummaryManifest(
                            stageLabel: "HDR prep 1/2",
                            renderIntent: FFmpegRenderIntent.presentationIntermediate.rawValue,
                            encoder: "hevc_videotoolbox",
                            elapsedSeconds: 8.5,
                            outputFileSizeBytes: 1_500_000
                        ),
                        CandidateCommandSummaryManifest(
                            stageLabel: "HDR batch 1/1",
                            renderIntent: FFmpegRenderIntent.finalBatch.rawValue,
                            encoder: "libx265",
                            elapsedSeconds: 22.0,
                            outputFileSizeBytes: 10_000_000
                        )
                    ],
                    presentationTimingAudits: [
                        ProgressivePresentationTimingAudit(
                            clipKind: .still,
                            hasCaptureDateOverlay: false,
                            commandCount: 1,
                            clipCount: 1,
                            totalElapsedSeconds: 8.5
                        )
                    ]
                )
            ]
        )

        try writeBakeoffBundleArtifacts(manifest: manifest, bundleRoot: bundleRoot)

        let manifestURL = bundleRoot.appendingPathComponent("manifest.json")
        let indexURL = bundleRoot.appendingPathComponent("index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))

        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedManifest = try decoder.decode(BakeoffManifest.self, from: manifestData)
        XCTAssertEqual(decodedManifest.albumTitle, "Test Export")
        XCTAssertEqual(decodedManifest.candidates.count, 1)
        XCTAssertEqual(decodedManifest.candidates.first?.label, "baseline-crf17-medium")

        let indexHTML = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(indexHTML.contains("baseline-crf17-medium"))
        XCTAssertTrue(indexHTML.contains("run-report.json"))
        XCTAssertTrue(indexHTML.contains("frame-50.png"))
    }

    func testCandidateCatalogResolvesRequestedLabelsInOrderIncludingCRF21Fast() throws {
        let definitions = try resolveCandidateDefinitions(
            for: ["baseline-crf17-medium", "candidate-crf20-fast", "candidate-crf21-fast"]
        )

        XCTAssertEqual(definitions.map(\.label), ["baseline-crf17-medium", "candidate-crf20-fast", "candidate-crf21-fast"])
        XCTAssertEqual(definitions.map(\.preset), ["medium", "fast", "fast"])
        XCTAssertEqual(definitions.map(\.crf), [17, 20, 21])
    }

    func testResolveCandidateDefinitionsRejectsDuplicateAndUnknownLabels() throws {
        XCTAssertThrowsError(
            try resolveCandidateDefinitions(
                for: ["baseline-crf17-medium", "baseline-crf17-medium"]
            )
        ) { error in
            XCTAssertEqual(
                error as? TestError,
                .duplicateRequestedCandidateLabel("baseline-crf17-medium")
            )
        }

        XCTAssertThrowsError(
            try resolveCandidateDefinitions(
                for: ["candidate-crf99-medium"]
            )
        ) { error in
            XCTAssertEqual(
                error as? TestError,
                .unknownCandidateLabel("candidate-crf99-medium")
            )
        }
    }

    func testReusableCandidateImportCopiesSelfContainedDirectoryAndPreservesOrder() throws {
        let sourceBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualExportBakeoffReuseSource-\(UUID().uuidString)", isDirectory: true)
        let destinationBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualExportBakeoffReuseDest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationBundle, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceBundle)
            try? FileManager.default.removeItem(at: destinationBundle)
        }

        let baselineEntry = try makeFixtureCandidateEntry(
            bundleRoot: sourceBundle,
            label: "baseline-crf17-medium",
            preset: "medium",
            crf: 17
        )
        let fastEntry = try makeFixtureCandidateEntry(
            bundleRoot: sourceBundle,
            label: "candidate-crf20-fast",
            preset: "fast",
            crf: 20
        )

        try importReusableCandidate(baselineEntry, from: sourceBundle, into: destinationBundle)
        try importReusableCandidate(fastEntry, from: sourceBundle, into: destinationBundle)

        let manifest = BakeoffManifest(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            albumTitle: "Test Export",
            albumLocalIdentifier: "album-123",
            bundleRootPath: destinationBundle.path,
            normalizedFramePositions: normalizedFramePositions,
            candidates: [baselineEntry, fastEntry]
        )

        try writeBakeoffBundleArtifacts(manifest: manifest, bundleRoot: destinationBundle)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destinationBundle.appendingPathComponent(baselineEntry.finalVideoPath).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destinationBundle.appendingPathComponent(fastEntry.finalVideoPath).path
            )
        )

        let indexHTML = try String(
            contentsOf: destinationBundle.appendingPathComponent("index.html"),
            encoding: .utf8
        )
        let baselineIndex = try XCTUnwrap(indexHTML.range(of: "baseline-crf17-medium")?.lowerBound)
        let fastIndex = try XCTUnwrap(indexHTML.range(of: "candidate-crf20-fast")?.lowerBound)
        XCTAssertLessThan(
            indexHTML.distance(from: indexHTML.startIndex, to: baselineIndex),
            indexHTML.distance(from: indexHTML.startIndex, to: fastIndex)
        )
    }

    func testBakeoffFromTestExportAlbum() async throws {
        guard ProcessInfo.processInfo.environment["RUN_EXPORT_BAKEOFF"] == "1" else {
            throw XCTSkip("Set RUN_EXPORT_BAKEOFF=1 to run the Test Export HEVC bakeoff.")
        }

        let discovery = PhotoKitMediaDiscoveryService()
        let authorizationStatus = await resolvedAuthorizationStatus(for: discovery)
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            throw XCTSkip("Photos access is not granted to the test runner. Grant Photos access and rerun the bakeoff command.")
        }

        let albums = try await discovery.discoverAlbums()
        let matchingAlbums = albums.filter {
            $0.title.compare("Test Export", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }

        XCTAssertEqual(
            matchingAlbums.count,
            1,
            "Expected exactly one Photos album matching Test Export."
        )
        let album = try XCTUnwrap(matchingAlbums.first)
        let items = try await discovery.discover(albumLocalIdentifier: album.localIdentifier)
        XCTAssertFalse(items.isEmpty, "Expected Test Export album to contain media items.")

        let bundleRoot = try makeBakeoffBundleRoot(albumTitle: album.title)
        let exportProfileManager = ExportProfileManager()
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
        let materializer = PhotoKitAssetMaterializer()
        defer { materializer.cancelPendingRequests() }

        var candidateEntries: [CandidateManifestEntry] = []
        let candidateDefinitions = makeCandidateDefinitions()

        for candidate in candidateDefinitions {
            let candidateDirectory = bundleRoot.appendingPathComponent(candidate.label, isDirectory: true)
            try FileManager.default.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)

            let request = RenderRequest(
                source: .photosLibrary(
                    scope: .album(localIdentifier: album.localIdentifier, title: album.title)
                ),
                monthYear: nil,
                ordering: .captureDateAscendingStable,
                style: style,
                export: exportResolution.effectiveProfile,
                output: OutputTarget(directory: candidateDirectory, baseFilename: candidate.label)
            )
            let coordinator = RenderCoordinator()
            let preparation = coordinator.prepareFromItems(
                items,
                request: request,
                additionalWarnings: exportResolution.warnings.map(\.message)
            )
            let result = try await coordinator.render(
                preparation: preparation,
                request: request,
                photoMaterializer: materializer,
                writeDiagnosticsLog: true,
                progressHandler: nil,
                executionOptions: RenderExecutionOptions(finalHEVCTuningOverride: candidate.tuningOverride)
            )

            let executionDetails = try XCTUnwrap(result.executionDetails)
            let diagnosticsLogURL = try XCTUnwrap(result.diagnosticsLogURL)
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
            XCTAssertNotNil(outputFileSizeBytes, "Expected a measurable final file size for \(candidate.label).")
            let resolvedOutputFileSizeBytes = try XCTUnwrap(outputFileSizeBytes)

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
                finalHEVCTuningCRF: candidate.crf,
                presentationTimingAudits: executionDetails.presentationTimingAudits
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
            let intermediateCommandSummaries = executionDetails.commandSummaries.filter {
                $0.renderIntent == .presentationIntermediate || $0.renderIntent == .intermediateChunk
            }
            let manifestEntry = CandidateManifestEntry(
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
                intermediateEncoders: Array(Set(intermediateCommandSummaries.map(\.encoder))).sorted(),
                commandSummaries: commandSummaries,
                presentationTimingAudits: executionDetails.presentationTimingAudits
            )
            candidateEntries.append(manifestEntry)

            print("export_bakeoff_candidate=\(candidate.label)")
            print("export_bakeoff_video=\(result.outputURL.path)")
            print("export_bakeoff_report=\(reportURL.path)")
            print("export_bakeoff_diagnostics=\(preservedDiagnosticsURL.path)")
        }

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
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))

        print("export_bakeoff_bundle=\(bundleRoot.path)")
        print("export_bakeoff_index=\(indexURL.path)")
    }

    private func makeCandidateDefinitions() -> [CandidateDefinition] {
        [
            CandidateDefinition(
                label: "baseline-crf17-medium",
                preset: "medium",
                crf: 17,
                tuningOverride: nil
            ),
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
                label: "candidate-crf20-medium",
                preset: "medium",
                crf: 20,
                tuningOverride: FinalHEVCTuningOverride(preset: "medium", crf: 20)
            ),
            CandidateDefinition(
                label: "candidate-crf21-medium",
                preset: "medium",
                crf: 21,
                tuningOverride: FinalHEVCTuningOverride(preset: "medium", crf: 21)
            ),
            CandidateDefinition(
                label: "candidate-crf20-fast",
                preset: "fast",
                crf: 20,
                tuningOverride: FinalHEVCTuningOverride(preset: "fast", crf: 20)
            ),
            CandidateDefinition(
                label: "candidate-crf21-fast",
                preset: "fast",
                crf: 21,
                tuningOverride: FinalHEVCTuningOverride(preset: "fast", crf: 21)
            )
        ]
    }

    private func resolveCandidateDefinitions(for labels: [String]) throws -> [CandidateDefinition] {
        let catalog = Dictionary(uniqueKeysWithValues: makeCandidateDefinitions().map { ($0.label, $0) })
        var seenLabels: Set<String> = []

        return try labels.map { label in
            guard seenLabels.insert(label).inserted else {
                throw TestError.duplicateRequestedCandidateLabel(label)
            }
            guard let definition = catalog[label] else {
                throw TestError.unknownCandidateLabel(label)
            }
            return definition
        }
    }

    private func importReusableCandidate(
        _ entry: CandidateManifestEntry,
        from sourceBundleRoot: URL,
        into destinationBundleRoot: URL
    ) throws {
        let sourceDirectory = sourceBundleRoot.appendingPathComponent(entry.label, isDirectory: true)
        let destinationDirectory = destinationBundleRoot.appendingPathComponent(entry.label, isDirectory: true)
        if FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try FileManager.default.removeItem(at: destinationDirectory)
        }
        try FileManager.default.copyItem(at: sourceDirectory, to: destinationDirectory)
    }

    private func makeFixtureCandidateEntry(
        bundleRoot: URL,
        label: String,
        preset: String,
        crf: Int
    ) throws -> CandidateManifestEntry {
        let candidateDirectory = bundleRoot.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)

        let finalVideoURL = candidateDirectory.appendingPathComponent("\(label).mp4")
        let reportURL = candidateDirectory.appendingPathComponent("run-report.json")
        let diagnosticsURL = candidateDirectory.appendingPathComponent("diagnostics.log")
        try Data("video".utf8).write(to: finalVideoURL)
        try Data("{}".utf8).write(to: reportURL)
        try Data("diagnostics".utf8).write(to: diagnosticsURL)

        let frameURLs = [
            candidateDirectory.appendingPathComponent("frame-05.png"),
            candidateDirectory.appendingPathComponent("frame-20.png"),
            candidateDirectory.appendingPathComponent("frame-50.png"),
            candidateDirectory.appendingPathComponent("frame-80.png"),
            candidateDirectory.appendingPathComponent("frame-95.png")
        ]
        for (index, frameURL) in frameURLs.enumerated() {
            try writeSolidPNG(
                color: CGColor(
                    red: CGFloat(index) / 5.0,
                    green: 0.4,
                    blue: 0.8,
                    alpha: 1
                ),
                to: frameURL
            )
        }

        return CandidateManifestEntry(
            label: label,
            preset: preset,
            crf: crf,
            finalVideoPath: relativePath(from: bundleRoot, to: finalVideoURL),
            runReportPath: relativePath(from: bundleRoot, to: reportURL),
            diagnosticsLogPath: relativePath(from: bundleRoot, to: diagnosticsURL),
            framePaths: frameURLs.map { relativePath(from: bundleRoot, to: $0) },
            outputFileSizeBytes: 12_345_678,
            renderElapsedSeconds: 42.5,
            renderBackendSummary: "FFmpeg HDR backend: bundled ffmpeg + libx265",
            renderBackendInfo: RenderBackendInfo(binarySource: .bundled, encoder: "libx265"),
            resolvedVideoInfo: ResolvedRenderVideoInfo(width: 3840, height: 2160, frameRate: 30),
            progressiveIntermediateUsage: .hardwareOnly,
            intermediateEncoders: ["hevc_videotoolbox"],
            commandSummaries: [
                CandidateCommandSummaryManifest(
                    stageLabel: "HDR prep 1/2",
                    renderIntent: FFmpegRenderIntent.presentationIntermediate.rawValue,
                    encoder: "hevc_videotoolbox",
                    elapsedSeconds: 8.5,
                    outputFileSizeBytes: 1_500_000
                ),
                CandidateCommandSummaryManifest(
                    stageLabel: "HDR batch 1/1",
                    renderIntent: FFmpegRenderIntent.finalBatch.rawValue,
                    encoder: "libx265",
                    elapsedSeconds: 22.0,
                    outputFileSizeBytes: 10_000_000
                )
            ],
            presentationTimingAudits: [
                ProgressivePresentationTimingAudit(
                    clipKind: .still,
                    hasCaptureDateOverlay: false,
                    commandCount: 1,
                    clipCount: 1,
                    totalElapsedSeconds: 8.5
                )
            ]
        )
    }

    private func resolvedAuthorizationStatus(for discovery: PhotoKitMediaDiscoveryService) async -> PHAuthorizationStatus {
        let currentStatus = discovery.authorizationStatus()
        if currentStatus == .notDetermined {
            return await discovery.requestAuthorization()
        }
        return currentStatus
    }

    private func makeBakeoffBundleRoot(albumTitle: String) throws -> URL {
        let bundleRoot = repositoryRootURL()
            .appendingPathComponent("tmp/export-bakeoffs", isDirectory: true)
            .appendingPathComponent("\(timestamp())-\(sanitizePathComponent(albumTitle))", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        return bundleRoot
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
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

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
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

    private func progressiveIntermediateUsage(
        for summaries: [RenderCommandSummary]
    ) -> ProgressiveIntermediateUsage {
        guard !summaries.isEmpty else {
            return .notApplicable
        }
        let encoders = Set(summaries.map(\.encoder))
        if encoders.contains(FFmpegVideoEncoder.libx265.rawValue) {
            return encoders == Set([FFmpegVideoEncoder.libx265.rawValue]) ? .softwareFallbackUsed : .mixed
        }
        if encoders == Set([FFmpegVideoEncoder.hevcVideoToolbox.rawValue]) {
            return .hardwareOnly
        }
        return .mixed
    }

    private func writeBakeoffBundleArtifacts(
        manifest: BakeoffManifest,
        bundleRoot: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: bundleRoot.appendingPathComponent("manifest.json"))

        let html = makeIndexHTML(manifest: manifest)
        try html.write(
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
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

    private func writeSolidPNG(color: CGColor, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(
                domain: "ManualExportBakeoffTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate solid-color PNG context."]
            )
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage() else {
            throw NSError(
                domain: "ManualExportBakeoffTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create solid-color PNG image."]
            )
        }
        try writePNG(image, to: url)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "ManualExportBakeoffTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination at \(url.path)."]
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "ManualExportBakeoffTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG at \(url.path)."]
            )
        }
    }
}

private extension String {
    func nonEmptyOrFallback(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
