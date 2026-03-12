import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

public final class AVFoundationRenderEngine {
    private let stillImageClipFactory: StillImageClipFactory
    private let captureDateOverlayFactory: CaptureDateOverlayFactory
    private let ffmpegHDRRenderer: FFmpegHDRRenderer
    private let ffmpegCommandBuilder: FFmpegCommandBuilder
    private let ffmpegProgressivePipelineBuilder: FFmpegHDRProgressivePipelineBuilder
    private let ffmpegProgressiveResumeStore: FFmpegProgressiveResumeStore
    private let ffmpegProgressivePauseState: FFmpegProgressivePauseState

    public convenience init(
        stillImageClipFactory: StillImageClipFactory = StillImageClipFactory(),
        captureDateOverlayFactory: CaptureDateOverlayFactory = CaptureDateOverlayFactory()
    ) {
        self.init(
            stillImageClipFactory: stillImageClipFactory,
            captureDateOverlayFactory: captureDateOverlayFactory,
            ffmpegProgressiveResumeStore: FFmpegProgressiveResumeStore()
        )
    }

    init(
        stillImageClipFactory: StillImageClipFactory,
        captureDateOverlayFactory: CaptureDateOverlayFactory,
        ffmpegProgressiveResumeStore: FFmpegProgressiveResumeStore
    ) {
        self.stillImageClipFactory = stillImageClipFactory
        self.captureDateOverlayFactory = captureDateOverlayFactory
        self.ffmpegHDRRenderer = FFmpegHDRRenderer()
        self.ffmpegCommandBuilder = FFmpegCommandBuilder()
        self.ffmpegProgressivePipelineBuilder = FFmpegHDRProgressivePipelineBuilder()
        self.ffmpegProgressiveResumeStore = ffmpegProgressiveResumeStore
        self.ffmpegProgressivePauseState = FFmpegProgressivePauseState()
    }

    public func cancelCurrentRender() {
        ffmpegProgressivePauseState.reset()
        ffmpegHDRRenderer.cancelCurrentRender()
    }

    public func requestPauseAfterCheckpoint() {
        ffmpegProgressivePauseState.requestPause()
    }

    public func render(
        timeline: Timeline,
        style: StyleProfile,
        exportProfile: ExportProfile,
        outputTarget: OutputTarget,
        plexTVMetadata: PlexTVMetadata?,
        chapters: [RenderChapter],
        photoMaterializer: PhotoAssetMaterializing?,
        writeDiagnosticsLog: Bool,
        progressHandler: (@MainActor @Sendable (Double) -> Void)? = nil,
        statusHandler: (@MainActor @Sendable (String) -> Void)? = nil,
        systemFFmpegFallbackHandler: SystemFFmpegFallbackHandler? = nil
    ) async throws -> RenderResult {
        guard !timeline.segments.isEmpty else {
            throw RenderError.noRenderableMedia
        }

        let diagnostics = RenderDiagnostics()
        var liveDiagnosticsLogURL: URL?
        var resolvedFrameRate = 30
        var renderSize = CGSize.zero
        diagnostics.measurePhase(.renderSetup) {
            if writeDiagnosticsLog {
                liveDiagnosticsLogURL = reserveDiagnosticsFileURL(outputTarget: outputTarget)
            } else {
                liveDiagnosticsLogURL = nil
            }
            diagnostics.add("Render started")
            if let liveDiagnosticsLogURL {
                diagnostics.add("Diagnostics log path: \(liveDiagnosticsLogURL.path)")
            }
            diagnostics.add("Timeline segments: \(timeline.segments.count)")
            diagnostics.add(
                "Style: title=\(style.openingTitle ?? "none"), titleDuration=\(style.titleDurationSeconds), " +
                "crossfade=\(style.crossfadeDurationSeconds), stillDuration=\(style.stillImageDurationSeconds), " +
                "captureDateOverlay=\(style.showCaptureDateOverlay)"
            )
            diagnostics.add(
                "Export profile: container=\(exportProfile.container.rawValue), codec=\(exportProfile.videoCodec.rawValue), " +
                "frameRate=\(exportProfile.frameRate.rawValue), " +
                "resolution=\(exportProfile.resolution.normalized.rawValue), dynamicRange=\(exportProfile.dynamicRange.rawValue), " +
                "hdrFFmpegBinaryMode=\(exportProfile.hdrFFmpegBinaryMode.rawValue), " +
                "hdrHEVCEncoderMode=\(exportProfile.hdrHEVCEncoderMode.rawValue), " +
                "audioLayout=\(exportProfile.audioLayout.rawValue), bitrate=\(exportProfile.bitrateMode.rawValue)"
            )
            if let plexTVMetadata {
                diagnostics.add(
                    "Plex TV metadata: show=\(plexTVMetadata.identity.showTitle), " +
                    "episodeID=\(plexTVMetadata.identity.episodeID), title=\(plexTVMetadata.identity.episodeTitle)"
                )
            }
            if !chapters.isEmpty {
                diagnostics.add("Resolved output chapters: \(chapters.count)")
            }

            let requestedRenderSize = resolveRenderSize(from: timeline, policy: exportProfile.resolution)
            resolvedFrameRate = resolveFrameRate(from: timeline, policy: exportProfile.frameRate)
            renderSize = constrainedRenderSizeForExport(requestedSize: requestedRenderSize, profile: exportProfile)
            diagnostics.add("Render size: \(Int(renderSize.width))x\(Int(renderSize.height))")
            diagnostics.add("Resolved output frame rate: \(resolvedFrameRate) fps")
        }
        ffmpegProgressivePauseState.reset()
        if let liveDiagnosticsLogURL {
            _ = writeDiagnosticsReport(
                diagnostics.renderReport(outcome: "in_progress", error: nil),
                to: liveDiagnosticsLogURL
            )
        }
        var temporaryURLs: [URL] = []
        var progressiveResumeSession: FFmpegProgressiveResumeSession?
        var renderedOutputURL: URL?

        do {
            reportStatus("Preparing media clips...", handler: statusHandler)
            reportProgress(0.02, handler: progressHandler)
            let clips = try await diagnostics.measurePhase(.clipMaterialization) {
                try await materializeInputClips(
                    segments: timeline.segments,
                    style: style,
                    renderSize: renderSize,
                    frameRate: resolvedFrameRate,
                    exportDynamicRange: exportProfile.dynamicRange,
                    exportBinaryMode: exportProfile.hdrFFmpegBinaryMode,
                    photoMaterializer: photoMaterializer,
                    temporaryURLs: &temporaryURLs,
                    diagnostics: diagnostics,
                    progressHandler: progressHandler,
                    statusHandler: statusHandler
                )
            }

            guard !clips.isEmpty else {
                throw RenderError.noRenderableMedia
            }

            if exportProfile.dynamicRange == .hdr,
               clips.contains(where: { $0.colorInfo.usesDolbyVisionFallback }) {
                diagnostics.add(
                    "Dolby Vision source detected. Final export preserves HDR as plain HLG fallback and does not preserve Dolby Vision dynamic metadata."
                )
            }

            let transitionDuration = effectiveTransitionDuration(clips: clips, requestedSeconds: style.crossfadeDurationSeconds)
            diagnostics.add("Transition duration resolved: \(format(transitionDuration))")
            let resolvedChapters = resolveOutputChapters(
                requestedChapters: chapters,
                timeline: timeline,
                transitionDuration: transitionDuration,
                container: exportProfile.container
            )
            reportStatus("Configuring \(exportProfile.dynamicRange == .hdr ? "HDR" : "SDR") encode...", handler: statusHandler)
            diagnostics.add(
                "\(exportProfile.dynamicRange == .hdr ? "HDR" : "SDR") export selected; routing to FFmpeg backend " +
                "(mode=\(exportProfile.hdrFFmpegBinaryMode.rawValue), codec=\(exportProfile.videoCodec.rawValue))."
            )
            let candidateOutputURL = try OutputPathResolver.resolveUniqueURL(target: outputTarget, container: exportProfile.container)
            let provisionalPlan = makeFFmpegRenderPlan(
                clips: clips,
                transitionDuration: transitionDuration,
                endFadeToBlackDurationSeconds: max(style.crossfadeDurationSeconds * 2, 0),
                outputURL: candidateOutputURL,
                renderSize: renderSize,
                frameRate: resolvedFrameRate,
                exportProfile: exportProfile,
                embeddedMetadata: plexTVMetadata?.embedded,
                chapters: resolvedChapters,
                chapterMetadataURL: nil
            )

            let binaryResolution: FFmpegBinaryResolution
            if ffmpegProgressivePipelineBuilder.requiresProgressiveExecution(for: provisionalPlan) {
                ffmpegProgressiveResumeStore.pruneStaleSessions()
                let planSignature = FFmpegProgressiveResumeStore.planSignature(
                    for: provisionalPlan,
                    outputTarget: outputTarget
                )
                var resumeSession: FFmpegProgressiveResumeSession
                if let pausedSession = ffmpegProgressiveResumeStore.findResumableSession(
                    planSignature: planSignature,
                    outputTarget: outputTarget
                ) {
                    resumeSession = pausedSession
                } else {
                    resumeSession = try ffmpegProgressiveResumeStore.createSession(
                        planSignature: planSignature,
                        outputTarget: outputTarget,
                        finalOutputURL: candidateOutputURL
                    )
                }
                progressiveResumeSession = resumeSession
                renderedOutputURL = resumeSession.finalOutputURL
                diagnostics.add("Resolved output URL: \(resumeSession.finalOutputURL.path)")
                switch resumeSession.state {
                case .paused:
                    diagnostics.add(
                        "Resuming paused HDR progressive session: sessionID=\(resumeSession.sessionID.uuidString), workDirectory=\(resumeSession.workDirectoryURL.path)"
                    )
                    reportStatus("Resuming paused HDR encode...", handler: statusHandler)
                case .recoverableFailure:
                    diagnostics.add(
                        "Resuming failed HDR progressive session: sessionID=\(resumeSession.sessionID.uuidString), workDirectory=\(resumeSession.workDirectoryURL.path)"
                    )
                    reportStatus("Resuming failed HDR encode...", handler: statusHandler)
                case .active:
                    diagnostics.add(
                        "Recovering interrupted HDR progressive session: sessionID=\(resumeSession.sessionID.uuidString), workDirectory=\(resumeSession.workDirectoryURL.path)"
                    )
                    reportStatus("Recovering interrupted HDR encode...", handler: statusHandler)
                }

                let chapterMetadataURL = try makeChapterMetadataFileIfNeeded(
                    chapters: resolvedChapters,
                    temporaryURLs: &temporaryURLs,
                    diagnostics: diagnostics,
                    preferredURL: resolvedChapters.isEmpty ? nil : resumeSession.chapterMetadataURL,
                    preservePreferredURL: true
                )
                let ffmpegPlan = makeFFmpegRenderPlan(
                    clips: clips,
                    transitionDuration: transitionDuration,
                    endFadeToBlackDurationSeconds: max(style.crossfadeDurationSeconds * 2, 0),
                    outputURL: resumeSession.finalOutputURL,
                    renderSize: renderSize,
                    frameRate: resolvedFrameRate,
                    exportProfile: exportProfile,
                    embeddedMetadata: plexTVMetadata?.embedded,
                    chapters: resolvedChapters,
                    chapterMetadataURL: chapterMetadataURL
                )
                guard let progressiveExecutionPlan = ffmpegProgressivePipelineBuilder.makeExecutionPlan(
                    for: ffmpegPlan,
                    presentationOutputURL: { resumeSession.presentationOutputURL(for: $0) },
                    batchOutputURL: { resumeSession.batchOutputURL(for: $0) },
                    concatListURL: { resumeSession.concatListURL },
                    concatOutputURL: { resumeSession.concatOutputURL }
                ) else {
                    ffmpegProgressiveResumeStore.removeSession(resumeSession)
                    progressiveResumeSession = nil
                    throw RenderError.exportFailed("Progressive HDR resume session could not be reconstructed.")
                }
                diagnostics.add(
                    "HDR progressive batching enabled: true (activationChunks=\(progressiveExecutionPlan.activationChunkPlan.chunks.count), " +
                    "presentationIntermediates=\(progressiveExecutionPlan.presentationPlans.count), " +
                    "slices=\(progressiveExecutionPlan.slices.count), " +
                    "finalBatches=\(progressiveExecutionPlan.batchPlans.count), " +
                    "maxBatchClips=\(ffmpegProgressivePipelineBuilder.maxUniqueSourceClipsPerBatch), " +
                    "maxBatchDuration=\(String(format: "%.2fs", ffmpegProgressivePipelineBuilder.maxBatchDurationSeconds)))"
                )
                for batch in progressiveExecutionPlan.batchPlans {
                    diagnostics.add(
                        "HDR final batch plan: index=\(batch.sequenceIndex + 1), sourceClips=\(batch.sourceClipIndices.count), " +
                        "slices=\(batch.plan.assemblySlices?.count ?? 0), expectedDuration=\(String(format: "%.2fs", ffmpegCommandBuilder.expectedDurationSeconds(for: batch.plan))), " +
                        "output=\(batch.plan.outputURL.path)"
                    )
                }
                reportStatus("Configuring progressive HDR encode...", handler: statusHandler)
                binaryResolution = try await diagnostics.measurePhase(.progressiveHDRExecution) {
                    try await executeProgressiveFFmpegPlan(
                        ffmpegPlan,
                        executionPlan: progressiveExecutionPlan,
                        resumeSession: &resumeSession,
                        binaryMode: exportProfile.hdrFFmpegBinaryMode,
                        diagnostics: diagnostics,
                        temporaryURLs: &temporaryURLs,
                        progressHandler: progressHandler,
                        statusHandler: statusHandler,
                        systemFFmpegFallbackHandler: systemFFmpegFallbackHandler
                    )
                }
                ffmpegProgressiveResumeStore.removeSession(resumeSession)
                progressiveResumeSession = nil
            } else {
                let chapterMetadataURL = try makeChapterMetadataFileIfNeeded(
                    chapters: resolvedChapters,
                    temporaryURLs: &temporaryURLs,
                    diagnostics: diagnostics
                )
                let ffmpegPlan = makeFFmpegRenderPlan(
                    clips: clips,
                    transitionDuration: transitionDuration,
                    endFadeToBlackDurationSeconds: max(style.crossfadeDurationSeconds * 2, 0),
                    outputURL: candidateOutputURL,
                    renderSize: renderSize,
                    frameRate: resolvedFrameRate,
                    exportProfile: exportProfile,
                    embeddedMetadata: plexTVMetadata?.embedded,
                    chapters: resolvedChapters,
                    chapterMetadataURL: chapterMetadataURL
                )
                renderedOutputURL = candidateOutputURL
                diagnostics.add("Resolved output URL: \(candidateOutputURL.path)")
                let chunkingReason: String
                if ffmpegPlan.dynamicRange != .hdr || ffmpegPlan.videoCodec != .hevc {
                    chunkingReason = "not_applicable"
                } else {
                    chunkingReason = "single_pass_plan"
                }
                diagnostics.add("HDR progressive batching enabled: false (reason=\(chunkingReason))")
                binaryResolution = try await diagnostics.measurePhase(.directFFmpegExport) {
                    try await executeFFmpegPlan(
                        ffmpegPlan,
                        binaryMode: exportProfile.hdrFFmpegBinaryMode,
                        diagnostics: diagnostics,
                        progressRange: 0.30...0.98,
                        statusPrefix: nil,
                        progressHandler: progressHandler,
                        statusHandler: statusHandler,
                        systemFFmpegFallbackHandler: systemFFmpegFallbackHandler
                    )
                }
            }
            reportProgress(1.0, handler: progressHandler)
            reportStatus("Finalizing output...", handler: statusHandler)

            return diagnostics.measurePhase(.diagnosticsFinalization) {
                diagnostics.add("Render completed successfully")
                cleanupTemporaryFiles(&temporaryURLs, diagnostics: diagnostics)
                let diagnosticsLogURL: URL?
                if writeDiagnosticsLog {
                    diagnosticsLogURL = persistDiagnosticsReport(
                        diagnostics.renderReport(outcome: "success", error: nil),
                        outputTarget: outputTarget,
                        preferredURL: liveDiagnosticsLogURL
                    )
                } else {
                    diagnosticsLogURL = nil
                }
                return RenderResult(
                    outputURL: renderedOutputURL ?? candidateOutputURL,
                    diagnosticsLogURL: diagnosticsLogURL,
                    backendSummary: binaryResolution.backendSummary(
                        codec: exportProfile.videoCodec,
                        dynamicRange: exportProfile.dynamicRange,
                        hdrHEVCEncoderMode: exportProfile.hdrHEVCEncoderMode
                    ),
                    backendInfo: binaryResolution.backendInfo(
                        codec: exportProfile.videoCodec,
                        dynamicRange: exportProfile.dynamicRange,
                        hdrHEVCEncoderMode: exportProfile.hdrHEVCEncoderMode
                    ),
                    resolvedVideoInfo: ResolvedRenderVideoInfo(
                        width: Int(renderSize.width.rounded()),
                        height: Int(renderSize.height.rounded()),
                        frameRate: resolvedFrameRate
                    )
                )
            }
        } catch {
            let preservedResumableFailure: Bool
            if let progressiveResumeSession,
               case RenderError.paused = error {
                diagnostics.add(
                    "Render paused with resumable HDR session preserved: sessionID=\(progressiveResumeSession.sessionID.uuidString), " +
                        "workDirectory=\(progressiveResumeSession.workDirectoryURL.path)"
                )
                preservedResumableFailure = false
            } else if var progressiveResumeSession,
                      shouldPreserveRecoverableProgressiveFailure(session: progressiveResumeSession, error: error) {
                do {
                    try ffmpegProgressiveResumeStore.markRecoverableFailure(&progressiveResumeSession)
                    diagnostics.add(
                        "Render failed with resumable HDR session preserved: sessionID=\(progressiveResumeSession.sessionID.uuidString), " +
                            "workDirectory=\(progressiveResumeSession.workDirectoryURL.path)"
                    )
                    preservedResumableFailure = true
                } catch {
                    ffmpegProgressiveResumeStore.removeSession(progressiveResumeSession)
                    diagnostics.add(
                        "Failed to preserve resumable HDR session after error; session removed: \(describe(error))"
                    )
                    preservedResumableFailure = false
                }
            } else if let progressiveResumeSession {
                ffmpegProgressiveResumeStore.removeSession(progressiveResumeSession)
                preservedResumableFailure = false
            } else {
                preservedResumableFailure = false
            }
            let isPausedError: Bool
            if case RenderError.paused = error {
                isPausedError = true
            } else {
                isPausedError = false
            }
            let diagnosticURL: URL? = diagnostics.measurePhase(.diagnosticsFinalization) {
                diagnostics.add("Render failed with error: \(describe(error))")
                cleanupTemporaryFiles(&temporaryURLs, diagnostics: diagnostics)
                if writeDiagnosticsLog {
                    return persistDiagnosticsReport(
                        diagnostics.renderReport(outcome: isPausedError ? "paused" : "failure", error: error),
                        outputTarget: outputTarget,
                        preferredURL: liveDiagnosticsLogURL
                    )
                }
                return nil
            }
            let baseMessage = userFacingMessage(from: error)
            let recoveryTip: String
            if preservedResumableFailure {
                recoveryTip = "\nTip: Re-run the same export to resume from the last completed HDR checkpoint."
            } else {
                recoveryTip = ""
            }
            if isPausedError {
                if let diagnosticURL {
                    throw RenderError.paused("\(baseMessage)\nDiagnostics file: \(diagnosticURL.path)")
                }
                throw RenderError.paused(baseMessage)
            }
            if let diagnosticURL {
                throw RenderError.exportFailed("\(baseMessage)\(recoveryTip)\nDiagnostics file: \(diagnosticURL.path)")
            }
            let diagnosticsTip = "\nTip: Enable \"Write diagnostics log (.log)\" for a full render trace."
            throw RenderError.exportFailed("\(baseMessage)\(recoveryTip)\(diagnosticsTip)")
        }
    }

    private func shouldPreserveRecoverableProgressiveFailure(
        session: FFmpegProgressiveResumeSession,
        error: Error
    ) -> Bool {
        if error is CancellationError {
            return false
        }
        if case RenderError.paused = error {
            return false
        }
        return session.hasRecoverableCheckpointProgress
    }

    private func makeFFmpegRenderPlan(
        clips: [InputClip],
        transitionDuration: CMTime,
        endFadeToBlackDurationSeconds: Double,
        outputURL: URL,
        renderSize: CGSize,
        frameRate: Int,
        exportProfile: ExportProfile,
        embeddedMetadata: EmbeddedOutputMetadata?,
        chapters: [RenderChapter],
        chapterMetadataURL: URL?
    ) -> FFmpegRenderPlan {
        FFmpegRenderPlan(
            clips: clips.map {
                FFmpegRenderClip(
                    url: $0.assetURL,
                    durationSeconds: max($0.duration.seconds, 0.01),
                    includeAudio: $0.includeAudio,
                    hasAudioTrack: $0.audioTrack != nil,
                    colorInfo: $0.colorInfo,
                    sourceDescription: $0.sourceDescription,
                    captureDateOverlayURL: $0.captureDateOverlayURL
                )
            },
            transitionDurationSeconds: max(transitionDuration.seconds, 0),
            endFadeToBlackDurationSeconds: endFadeToBlackDurationSeconds,
            outputURL: outputURL,
            renderSize: renderSize,
            frameRate: frameRate,
            audioLayout: exportProfile.audioLayout,
            bitrateMode: exportProfile.bitrateMode,
            container: exportProfile.container,
            videoCodec: exportProfile.videoCodec,
            dynamicRange: exportProfile.dynamicRange,
            hdrHEVCEncoderMode: exportProfile.hdrHEVCEncoderMode,
            embeddedMetadata: embeddedMetadata,
            chapters: chapters,
            chapterMetadataURL: chapterMetadataURL,
            renderIntent: .finalDelivery
        )
    }

    private func resolveOutputChapters(
        requestedChapters: [RenderChapter],
        timeline: Timeline,
        transitionDuration: CMTime,
        container: ContainerFormat
    ) -> [RenderChapter] {
        guard container == .mp4 else {
            return []
        }
        if !requestedChapters.isEmpty {
            return requestedChapters
        }
        return MP4ChapterResolver.resolve(
            timeline: timeline,
            effectiveTransitionDurationSeconds: max(transitionDuration.seconds, 0)
        )
    }

    private func makeChapterMetadataFileIfNeeded(
        chapters: [RenderChapter],
        temporaryURLs: inout [URL],
        diagnostics: RenderDiagnostics,
        preferredURL: URL? = nil,
        preservePreferredURL: Bool = false
    ) throws -> URL? {
        guard !chapters.isEmpty else {
            return nil
        }

        let metadataURL = preferredURL ?? temporaryArtifactURL(pathExtension: "ffmeta")
        let contents = makeChapterMetadataContents(chapters: chapters)
        do {
            try contents.write(to: metadataURL, atomically: true, encoding: .utf8)
            if !(preservePreferredURL && preferredURL == metadataURL) {
                temporaryURLs.append(metadataURL)
            }
            diagnostics.add("Chapter metadata file prepared: \(metadataURL.path) (chapters=\(chapters.count))")
            return metadataURL
        } catch {
            throw RenderError.exportFailed("Unable to write chapter metadata file. \(describe(error))")
        }
    }

    private func makeChapterMetadataContents(chapters: [RenderChapter]) -> String {
        var lines = [";FFMETADATA1"]
        for chapter in chapters {
            lines.append("[CHAPTER]")
            lines.append("TIMEBASE=1/1000")
            let startMilliseconds = max(Int((chapter.startTimeSeconds * 1000).rounded()), 0)
            let endMilliseconds = max(Int((chapter.endTimeSeconds * 1000).rounded()), startMilliseconds + 1)
            lines.append("START=\(startMilliseconds)")
            lines.append("END=\(endMilliseconds)")
            lines.append("title=\(escapeFFMetadataText(chapter.title))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func escapeFFMetadataText(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "=", with: "\\=")
        escaped = escaped.replacingOccurrences(of: ";", with: "\\;")
        escaped = escaped.replacingOccurrences(of: "#", with: "\\#")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\\n")
        return escaped
    }

    private func executeFFmpegPlan(
        _ plan: FFmpegRenderPlan,
        binaryMode: HDRFFmpegBinaryMode,
        diagnostics: RenderDiagnostics,
        progressRange: ClosedRange<Double>,
        statusPrefix: String?,
        progressHandler: (@MainActor @Sendable (Double) -> Void)?,
        statusHandler: (@MainActor @Sendable (String) -> Void)?,
        systemFFmpegFallbackHandler: SystemFFmpegFallbackHandler?
    ) async throws -> FFmpegBinaryResolution {
        try await ffmpegHDRRenderer.render(
            plan: plan,
            binaryMode: binaryMode,
            diagnostics: { diagnostics.add($0) },
            progressHandler: { ffmpegProgress in
                let mapped = progressRange.lowerBound + min(max(ffmpegProgress, 0), 1) * (progressRange.upperBound - progressRange.lowerBound)
                self.reportProgress(mapped, handler: progressHandler)
            },
            statusHandler: { ffmpegStatus in
                let status = statusPrefix.map { "\($0): \(ffmpegStatus)" } ?? ffmpegStatus
                self.reportStatus(status, handler: statusHandler)
            },
            stageLabel: statusPrefix,
            commandStatsHandler: { diagnostics.recordFFmpegCommandSummary($0) },
            systemFFmpegFallbackHandler: systemFFmpegFallbackHandler
        )
    }

    private func executeFFmpegPlan(
        _ plan: FFmpegRenderPlan,
        resolution: FFmpegBinaryResolution,
        diagnostics: RenderDiagnostics,
        progressRange: ClosedRange<Double>,
        statusPrefix: String?,
        progressHandler: (@MainActor @Sendable (Double) -> Void)?,
        statusHandler: (@MainActor @Sendable (String) -> Void)?
    ) async throws {
        try await ffmpegHDRRenderer.render(
            plan: plan,
            resolution: resolution,
            diagnostics: { diagnostics.add($0) },
            progressHandler: { ffmpegProgress in
                let mapped = progressRange.lowerBound + min(max(ffmpegProgress, 0), 1) * (progressRange.upperBound - progressRange.lowerBound)
                self.reportProgress(mapped, handler: progressHandler)
            },
            statusHandler: { ffmpegStatus in
                let status = statusPrefix.map { "\($0): \(ffmpegStatus)" } ?? ffmpegStatus
                self.reportStatus(status, handler: statusHandler)
            },
            stageLabel: statusPrefix,
            commandStatsHandler: { diagnostics.recordFFmpegCommandSummary($0) }
        )
    }

    private func executeFFmpegCommand(
        _ command: FFmpegCommand,
        context: FFmpegHDRRenderer.CommandExecutionContext,
        resolution: FFmpegBinaryResolution,
        diagnostics: RenderDiagnostics,
        progressRange: ClosedRange<Double>,
        statusPrefix: String?,
        progressHandler: (@MainActor @Sendable (Double) -> Void)?,
        statusHandler: (@MainActor @Sendable (String) -> Void)?
    ) async throws {
        try await ffmpegHDRRenderer.execute(
            command: command,
            resolution: resolution,
            context: context,
            diagnostics: { diagnostics.add($0) },
            progressHandler: { ffmpegProgress in
                let mapped = progressRange.lowerBound + min(max(ffmpegProgress, 0), 1) * (progressRange.upperBound - progressRange.lowerBound)
                self.reportProgress(mapped, handler: progressHandler)
            },
            statusHandler: { ffmpegStatus in
                let status = statusPrefix.map { "\($0): \(ffmpegStatus)" } ?? ffmpegStatus
                self.reportStatus(status, handler: statusHandler)
            },
            commandStatsHandler: { diagnostics.recordFFmpegCommandSummary($0) }
        )
    }

    private func executeProgressiveFFmpegPlan(
        _ finalPlan: FFmpegRenderPlan,
        executionPlan: FFmpegHDRProgressiveExecutionPlan,
        resumeSession: inout FFmpegProgressiveResumeSession,
        binaryMode: HDRFFmpegBinaryMode,
        diagnostics: RenderDiagnostics,
        temporaryURLs: inout [URL],
        progressHandler: (@MainActor @Sendable (Double) -> Void)?,
        statusHandler: (@MainActor @Sendable (String) -> Void)?,
        systemFFmpegFallbackHandler: SystemFFmpegFallbackHandler?
    ) async throws -> FFmpegBinaryResolution {
        try ffmpegProgressiveResumeStore.markActive(&resumeSession)
        let resolution = try await ffmpegHDRRenderer.resolveBinary(
            requirements: progressiveCapabilityRequirements(for: finalPlan),
            binaryMode: binaryMode,
            diagnostics: { diagnostics.add($0) },
            statusHandler: { status in
                self.reportStatus(status, handler: statusHandler)
            },
            systemFFmpegFallbackHandler: systemFFmpegFallbackHandler
        )

        let finalDuration = ffmpegCommandBuilder.expectedDurationSeconds(for: finalPlan)
        let presentationWeights = executionPlan.presentationPlans.map { ffmpegCommandBuilder.expectedDurationSeconds(for: $0) }
        let batchWeights = executionPlan.batchPlans.map { ffmpegCommandBuilder.expectedDurationSeconds(for: $0.plan) }
        let concatWeight = max(finalDuration * 0.02, 5)
        let packagingWeight = max(finalDuration * 0.05, 5)
        let totalWeight = max(
            presentationWeights.reduce(0, +) +
                batchWeights.reduce(0, +) +
                concatWeight +
                packagingWeight,
            0.01
        )
        let completedPresentationIndices = Set(
            resumeSession.completedPresentationIndices.filter {
                executionPlan.presentationPlans.indices.contains($0) &&
                    FileManager.default.fileExists(atPath: executionPlan.presentationPlans[$0].outputURL.path)
            }
        )
        let completedBatchIndices = Set(
            resumeSession.completedBatchIndices.filter {
                executionPlan.batchPlans.indices.contains($0) &&
                    FileManager.default.fileExists(atPath: executionPlan.batchPlans[$0].plan.outputURL.path)
            }
        )
        let concatAlreadyCompleted = resumeSession.concatCompleted &&
            FileManager.default.fileExists(atPath: executionPlan.concatOutputURL.path)
        var completedWeight = completedPresentationIndices.reduce(0) { partialResult, index in
            partialResult + presentationWeights[index]
        }
        completedWeight += completedBatchIndices.reduce(0) { partialResult, index in
            partialResult + batchWeights[index]
        }
        if concatAlreadyCompleted {
            completedWeight += concatWeight
        }

        diagnostics.add(
            "HDR progressive execution started: presentationIntermediates=\(executionPlan.presentationPlans.count), " +
            "finalBatches=\(executionPlan.batchPlans.count), concatList=\(executionPlan.concatListURL.path), concatOutput=\(executionPlan.concatOutputURL.path), " +
            "completedPresentations=\(completedPresentationIndices.count), completedBatches=\(completedBatchIndices.count), concatCompleted=\(concatAlreadyCompleted)"
        )

        for (index, plan) in executionPlan.presentationPlans.enumerated() {
            let stageWeight = presentationWeights[index]
            if completedPresentationIndices.contains(index) {
                diagnostics.add(
                    "HDR presentation intermediate skipped: index=\(index + 1)/\(executionPlan.presentationPlans.count), output=\(plan.outputURL.path)"
                )
                continue
            }
            diagnostics.add(
                "HDR presentation intermediate started: index=\(index + 1)/\(executionPlan.presentationPlans.count), output=\(plan.outputURL.path)"
            )
            try await executeFFmpegPlan(
                plan,
                resolution: resolution,
                diagnostics: diagnostics,
                progressRange: progressRangeForFFmpegStage(
                    completedWeight: completedWeight,
                    stageWeight: stageWeight,
                    totalWeight: totalWeight
                ),
                statusPrefix: "HDR prep \(index + 1)/\(executionPlan.presentationPlans.count)",
                progressHandler: progressHandler,
                statusHandler: statusHandler
            )
            diagnostics.add(
                "HDR presentation intermediate completed: index=\(index + 1)/\(executionPlan.presentationPlans.count), output=\(plan.outputURL.path)"
            )
            try ffmpegProgressiveResumeStore.markPresentationCompleted(index, session: &resumeSession)
            completedWeight += stageWeight
            try pauseProgressiveRenderIfRequested(session: &resumeSession, diagnostics: diagnostics)
        }

        for batch in executionPlan.batchPlans {
            let stageWeight = batchWeights[batch.sequenceIndex]
            if completedBatchIndices.contains(batch.sequenceIndex) {
                diagnostics.add(
                    "HDR final batch skipped: index=\(batch.sequenceIndex + 1)/\(executionPlan.batchPlans.count), output=\(batch.plan.outputURL.path)"
                )
                for sourceClipIndex in batch.sourceClipIndices
                    where executionPlan.lastBatchIndexBySourceClip[sourceClipIndex] == batch.sequenceIndex {
                    let presentationURL = executionPlan.presentationPlans[sourceClipIndex].outputURL
                    removePersistentArtifact(presentationURL, diagnostics: diagnostics)
                }
                continue
            }
            diagnostics.add(
                "HDR final batch started: index=\(batch.sequenceIndex + 1)/\(executionPlan.batchPlans.count), " +
                "sourceClips=\(batch.sourceClipIndices.count), output=\(batch.plan.outputURL.path)"
            )
            try await executeFFmpegPlan(
                batch.plan,
                resolution: resolution,
                diagnostics: diagnostics,
                progressRange: progressRangeForFFmpegStage(
                    completedWeight: completedWeight,
                    stageWeight: stageWeight,
                    totalWeight: totalWeight
                ),
                statusPrefix: "HDR final batch \(batch.sequenceIndex + 1)/\(executionPlan.batchPlans.count)",
                progressHandler: progressHandler,
                statusHandler: statusHandler
            )
            diagnostics.add(
                "HDR final batch completed: index=\(batch.sequenceIndex + 1)/\(executionPlan.batchPlans.count), output=\(batch.plan.outputURL.path)"
            )
            try ffmpegProgressiveResumeStore.markBatchCompleted(batch.sequenceIndex, session: &resumeSession)
            completedWeight += stageWeight

            for sourceClipIndex in batch.sourceClipIndices
                where executionPlan.lastBatchIndexBySourceClip[sourceClipIndex] == batch.sequenceIndex {
                let presentationURL = executionPlan.presentationPlans[sourceClipIndex].outputURL
                removePersistentArtifact(presentationURL, diagnostics: diagnostics)
            }
            try pauseProgressiveRenderIfRequested(session: &resumeSession, diagnostics: diagnostics)
        }

        if concatAlreadyCompleted {
            diagnostics.add("HDR concat copy skipped: output=\(executionPlan.concatOutputURL.path)")
        } else {
            try writeConcatFileList(
                batchPlans: executionPlan.batchPlans,
                to: executionPlan.concatListURL
            )
            diagnostics.add("HDR concat list prepared: \(executionPlan.concatListURL.path) (batches=\(executionPlan.batchPlans.count))")

            let concatCommand = ffmpegCommandBuilder.buildConcatCommand(
                executableURL: resolution.selectedBinary.ffmpegURL,
                concatListURL: executionPlan.concatListURL,
                outputURL: executionPlan.concatOutputURL
            )
            try await executeFFmpegCommand(
                concatCommand,
                context: FFmpegHDRRenderer.CommandExecutionContext(
                    stageLabel: "HDR concat copy",
                    dynamicRange: finalPlan.dynamicRange,
                    renderIntent: .concatCopy,
                    outputURL: executionPlan.concatOutputURL,
                    clipCount: executionPlan.batchPlans.count,
                    chapterCount: 0,
                    renderSize: finalPlan.renderSize,
                    frameRate: finalPlan.frameRate,
                    bitrateMode: finalPlan.bitrateMode,
                    videoCodec: finalPlan.videoCodec,
                    audioBitrate: 48_000 * max(finalPlan.audioLayout.outputChannelCount ?? 2, 1) * 16,
                    audioLayout: finalPlan.audioLayout,
                    expectedDurationSeconds: finalDuration,
                    encoderDescription: "copy",
                    profileSummary: "intent=concatCopy encoder=copy audio=copy",
                    requiresHDRToSDRToneMapping: false,
                    hdrToSDRToneMapClips: [],
                    captureDateOverlayCount: 0,
                    summaryLine:
                        "FFmpeg concat summary: output=\(executionPlan.concatOutputURL.path), clips=\(executionPlan.batchPlans.count), chapters=0, " +
                        "renderSize=\(Int(finalPlan.renderSize.width.rounded()))x\(Int(finalPlan.renderSize.height.rounded())), frameRate=\(finalPlan.frameRate), " +
                        "container=mov, codec=\(finalPlan.videoCodec.rawValue), dynamicRange=\(finalPlan.dynamicRange.rawValue), " +
                        "audioLayout=\(finalPlan.audioLayout.rawValue), expectedDuration=\(String(format: "%.2fs", finalDuration))",
                    endpointLine: nil
                ),
                resolution: resolution,
                diagnostics: diagnostics,
                progressRange: progressRangeForFFmpegStage(
                    completedWeight: completedWeight,
                    stageWeight: concatWeight,
                    totalWeight: totalWeight
                ),
                statusPrefix: "HDR concat copy",
                progressHandler: progressHandler,
                statusHandler: statusHandler
            )
            try ffmpegProgressiveResumeStore.markConcatCompleted(&resumeSession)
            completedWeight += concatWeight
            for batch in executionPlan.batchPlans {
                removePersistentArtifact(batch.plan.outputURL, diagnostics: diagnostics)
            }
            removePersistentArtifact(executionPlan.concatListURL, diagnostics: diagnostics)
            try pauseProgressiveRenderIfRequested(session: &resumeSession, diagnostics: diagnostics)
        }

        let packagingCommand = try ffmpegCommandBuilder.buildPackagingCommand(
            executableURL: resolution.selectedBinary.ffmpegURL,
            concatenatedURL: executionPlan.concatOutputURL,
            finalPlan: finalPlan
        )
        try await executeFFmpegCommand(
            packagingCommand,
            context: FFmpegHDRRenderer.CommandExecutionContext(
                stageLabel: "HDR final package",
                dynamicRange: finalPlan.dynamicRange,
                renderIntent: .finalPackaging,
                outputURL: finalPlan.outputURL,
                clipCount: 1,
                chapterCount: finalPlan.chapters.count,
                renderSize: finalPlan.renderSize,
                frameRate: finalPlan.frameRate,
                bitrateMode: finalPlan.bitrateMode,
                videoCodec: finalPlan.videoCodec,
                audioBitrate: finalPlan.audioLayout.aacBitrate ?? 192_000,
                audioLayout: finalPlan.audioLayout,
                expectedDurationSeconds: finalDuration,
                encoderDescription: "copy",
                profileSummary: "intent=finalPackaging encoder=copy audio=aac",
                requiresHDRToSDRToneMapping: false,
                hdrToSDRToneMapClips: [],
                captureDateOverlayCount: 0,
                summaryLine:
                    "FFmpeg packaging summary: output=\(finalPlan.outputURL.path), clips=1, chapters=\(finalPlan.chapters.count), " +
                    "renderSize=\(Int(finalPlan.renderSize.width.rounded()))x\(Int(finalPlan.renderSize.height.rounded())), frameRate=\(finalPlan.frameRate), " +
                    "container=\(finalPlan.container.rawValue), codec=\(finalPlan.videoCodec.rawValue), dynamicRange=\(finalPlan.dynamicRange.rawValue), " +
                    "audioLayout=\(finalPlan.audioLayout.rawValue), expectedDuration=\(String(format: "%.2fs", finalDuration))",
                endpointLine: nil
            ),
            resolution: resolution,
            diagnostics: diagnostics,
            progressRange: progressRangeForFFmpegStage(
                completedWeight: completedWeight,
                stageWeight: packagingWeight,
                totalWeight: totalWeight
            ),
            statusPrefix: "HDR final package",
            progressHandler: progressHandler,
            statusHandler: statusHandler
        )
        removePersistentArtifact(executionPlan.concatOutputURL, diagnostics: diagnostics)
        diagnostics.add("HDR progressive execution completed: output=\(finalPlan.outputURL.path)")
        return resolution
    }

    private func progressiveCapabilityRequirements(for finalPlan: FFmpegRenderPlan) -> FFmpegCapabilityRequirements {
        FFmpegCapabilityRequirements(
            codec: finalPlan.videoCodec,
            dynamicRange: finalPlan.dynamicRange,
            hdrHEVCEncoderMode: finalPlan.hdrHEVCEncoderMode,
            renderIntent: .finalBatch,
            requiresHDRToSDRToneMapping: finalPlan.requiresHDRToSDRToneMapping,
            requiresOverlay: true
        )
    }

    private func writeConcatFileList(
        batchPlans: [FFmpegProgressiveBatchPlan],
        to url: URL
    ) throws {
        let contents = batchPlans
            .map { "file '\(escapeConcatFilePath($0.plan.outputURL.path))'" }
            .joined(separator: "\n") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func escapeConcatFilePath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private func removeTemporaryFile(
        _ url: URL,
        temporaryURLs: inout [URL],
        diagnostics: RenderDiagnostics
    ) {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                diagnostics.add("Removed temporary artifact: \(url.path)")
            }
        } catch {
            diagnostics.add("Temporary artifact cleanup skipped for \(url.path): \(describe(error))")
        }

        temporaryURLs.removeAll { $0 == url }
    }

    private func removePersistentArtifact(
        _ url: URL,
        diagnostics: RenderDiagnostics
    ) {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                diagnostics.add("Removed persistent artifact: \(url.path)")
            }
        } catch {
            diagnostics.add("Persistent artifact cleanup skipped for \(url.path): \(describe(error))")
        }
    }

    private func pauseProgressiveRenderIfRequested(
        session: inout FFmpegProgressiveResumeSession,
        diagnostics: RenderDiagnostics
    ) throws {
        guard ffmpegProgressivePauseState.isPauseRequested else {
            return
        }
        try ffmpegProgressiveResumeStore.markPaused(&session)
        diagnostics.add(
            "HDR progressive pause checkpoint reached: sessionID=\(session.sessionID.uuidString), workDirectory=\(session.workDirectoryURL.path)"
        )
        throw RenderError.paused(
            "Render paused after a safe HDR checkpoint. Reopen the app and start the same render again to resume."
        )
    }

    private func progressRangeForFFmpegStage(
        completedWeight: Double,
        stageWeight: Double,
        totalWeight: Double
    ) -> ClosedRange<Double> {
        let lower = 0.30 + 0.68 * (completedWeight / max(totalWeight, 0.01))
        let upper = 0.30 + 0.68 * ((completedWeight + stageWeight) / max(totalWeight, 0.01))
        return lower...max(lower, upper)
    }

    private func buildInstructions(
        clips: [InputClip],
        clipStartTimes: [CMTime],
        transitionDuration: CMTime,
        renderSize: CGSize,
        compositionTracks: [AVCompositionTrack]
    ) -> [AVVideoCompositionInstructionProtocol] {
        var instructions: [AVMutableVideoCompositionInstruction] = []
        let blackBackground = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        for index in clips.indices {
            let clip = clips[index]
            var passStart = clipStartTimes[index]
            var passDuration = clip.duration

            if transitionDuration > .zero {
                if index > 0 {
                    passStart = add(passStart, transitionDuration)
                    passDuration = subtract(passDuration, transitionDuration)
                }
                if index < clips.count - 1 {
                    passDuration = subtract(passDuration, transitionDuration)
                }
            }

            if passDuration > .zero {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: passStart, duration: passDuration)
                instruction.backgroundColor = blackBackground

                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTracks[index % 2])
                let transform = RenderSizing.aspectFitTransform(
                    naturalSize: clip.naturalSize,
                    preferredTransform: clip.preferredTransform,
                    renderSize: renderSize
                )
                layerInstruction.setTransform(transform, at: passStart)
                instruction.layerInstructions = [layerInstruction]
                instructions.append(instruction)
            }

            if index < clips.count - 1, transitionDuration > .zero {
                let transitionStart = subtract(add(clipStartTimes[index], clip.duration), transitionDuration)
                let transitionInstruction = AVMutableVideoCompositionInstruction()
                transitionInstruction.timeRange = CMTimeRange(start: transitionStart, duration: transitionDuration)
                transitionInstruction.backgroundColor = blackBackground

                let fromTrack = compositionTracks[index % 2]
                let toTrack = compositionTracks[(index + 1) % 2]

                let fromLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: fromTrack)
                let fromTransform = RenderSizing.aspectFitTransform(
                    naturalSize: clips[index].naturalSize,
                    preferredTransform: clips[index].preferredTransform,
                    renderSize: renderSize
                )
                fromLayer.setTransform(fromTransform, at: transitionStart)
                fromLayer.setOpacityRamp(
                    fromStartOpacity: 1.0,
                    toEndOpacity: 0.0,
                    timeRange: transitionInstruction.timeRange
                )

                let toLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: toTrack)
                let toTransform = RenderSizing.aspectFitTransform(
                    naturalSize: clips[index + 1].naturalSize,
                    preferredTransform: clips[index + 1].preferredTransform,
                    renderSize: renderSize
                )
                toLayer.setTransform(toTransform, at: transitionStart)
                toLayer.setOpacityRamp(
                    fromStartOpacity: 0.0,
                    toEndOpacity: 1.0,
                    timeRange: transitionInstruction.timeRange
                )

                transitionInstruction.layerInstructions = [toLayer, fromLayer]
                instructions.append(transitionInstruction)
            }
        }

        return instructions.sorted {
            $0.timeRange.start < $1.timeRange.start
        }
    }

    private func materializeInputClips(
        segments: [TimelineSegment],
        style: StyleProfile,
        renderSize: CGSize,
        frameRate: Int,
        exportDynamicRange: DynamicRange,
        exportBinaryMode: HDRFFmpegBinaryMode,
        photoMaterializer: PhotoAssetMaterializing?,
        temporaryURLs: inout [URL],
        diagnostics: RenderDiagnostics,
        progressHandler: (@MainActor @Sendable (Double) -> Void)?,
        statusHandler: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> [InputClip] {
        var clips: [InputClip] = []
        let totalSegments = max(segments.count, 1)

        for (index, segment) in segments.enumerated() {
            reportStatus("Preparing clip \(index + 1) of \(segments.count)...", handler: statusHandler)
            let segmentProgress = 0.05 + (Double(index) / Double(totalSegments)) * 0.18
            reportProgress(segmentProgress, handler: progressHandler)
            switch segment.asset {
            case let .titleCard(descriptor):
                let previewAssets = try await resolveTitleCardPreviewAssets(
                    from: descriptor.previewItems,
                    photoMaterializer: photoMaterializer,
                    diagnostics: diagnostics
                )
                let titleURL = try await diagnostics.measurePreparationOperation(
                    .titleCardGeneration,
                    detail: "title card '\(descriptor.resolvedTitle)'"
                ) {
                    try await stillImageClipFactory.makeTitleCardClip(
                        descriptor: descriptor,
                        previewAssets: previewAssets,
                        duration: segment.duration,
                        renderSize: renderSize,
                        frameRate: frameRate,
                        dynamicRange: exportDynamicRange
                    )
                }
                temporaryURLs.append(titleURL)
                diagnostics.add(
                    "Materialized title card clip at \(titleURL.path) for title '\(descriptor.resolvedTitle)' " +
                    "(previews=\(previewAssets.count), seed=\(descriptor.variationSeed))"
                )
                let titleClip = try await diagnostics.measurePreparationOperation(
                    .clipProbe,
                    detail: "title card '\(descriptor.resolvedTitle)'"
                ) {
                    try await makeClip(
                        assetURL: titleURL,
                        fallbackDuration: segment.duration,
                        includeAudio: false,
                        sourceDescription: "title card '\(descriptor.resolvedTitle)'",
                        sourceColorInfo: .unknown,
                        captureDateOverlayText: nil,
                        captureDateOverlayURL: nil,
                        diagnostics: diagnostics,
                        isTemporary: true,
                        exportDynamicRange: exportDynamicRange,
                        exportBinaryMode: exportBinaryMode
                    )
                }
                if let titleClip {
                    clips.append(titleClip)
                }

            case let .media(item):
                switch item.type {
                case .image:
                    let sourceURL = try await diagnostics.measurePreparationOperation(
                        .stillImageSourceResolution,
                        detail: item.filename
                    ) {
                        try await resolveURL(for: item, photoMaterializer: photoMaterializer)
                    }
                    let sourceColorInfo = try stillImageClipFactory.sourceColorInfo(
                        forImageURL: sourceURL,
                        dynamicRange: exportDynamicRange
                    )
                    let captureDateOverlayText = formattedCaptureDateOverlayText(for: item, style: style)
                    let captureDateOverlayURL: URL?
                    if let captureDateOverlayText {
                        captureDateOverlayURL = diagnostics.measurePreparationOperation(
                            .captureDateOverlayGeneration,
                            detail: item.filename
                        ) {
                            makeCaptureDateOverlayIfNeeded(
                                overlayText: captureDateOverlayText,
                                renderSize: renderSize,
                                diagnostics: diagnostics
                            )
                        }
                    } else {
                        captureDateOverlayURL = nil
                    }
                    if let captureDateOverlayURL {
                        temporaryURLs.append(captureDateOverlayURL)
                    }
                    let imageClipURL = try await diagnostics.measurePreparationOperation(
                        .stillClipGeneration,
                        detail: item.filename
                    ) {
                        try await stillImageClipFactory.makeVideoClip(
                            fromImageURL: sourceURL,
                            duration: segment.duration,
                            renderSize: renderSize,
                            frameRate: frameRate,
                            dynamicRange: exportDynamicRange
                        )
                    }
                    temporaryURLs.append(imageClipURL)
                    diagnostics.add("Materialized still image clip for \(item.filename) at \(imageClipURL.path)")
                    let imageClip = try await diagnostics.measurePreparationOperation(
                        .clipProbe,
                        detail: "image \(item.filename)"
                    ) {
                        try await makeClip(
                            assetURL: imageClipURL,
                            fallbackDuration: segment.duration,
                            includeAudio: false,
                            sourceDescription: "image \(item.filename)",
                            sourceColorInfo: sourceColorInfo,
                            captureDateOverlayText: captureDateOverlayText,
                            captureDateOverlayURL: captureDateOverlayURL,
                            diagnostics: diagnostics,
                            isTemporary: true,
                            exportDynamicRange: exportDynamicRange,
                            exportBinaryMode: exportBinaryMode
                        )
                    }
                    if let imageClip {
                        clips.append(imageClip)
                    }

                case .video:
                    let sourceURL = try await diagnostics.measurePreparationOperation(
                        .videoSourceResolution,
                        detail: item.filename
                    ) {
                        try await resolveURL(for: item, photoMaterializer: photoMaterializer)
                    }
                    let captureDateOverlayText = formattedCaptureDateOverlayText(for: item, style: style)
                    let captureDateOverlayURL: URL?
                    if let captureDateOverlayText {
                        captureDateOverlayURL = diagnostics.measurePreparationOperation(
                            .captureDateOverlayGeneration,
                            detail: item.filename
                        ) {
                            makeCaptureDateOverlayIfNeeded(
                                overlayText: captureDateOverlayText,
                                renderSize: renderSize,
                                diagnostics: diagnostics
                            )
                        }
                    } else {
                        captureDateOverlayURL = nil
                    }
                    if let captureDateOverlayURL {
                        temporaryURLs.append(captureDateOverlayURL)
                    }
                    diagnostics.add("Using source video clip \(sourceURL.path) for \(item.filename)")
                    let videoClip = try await diagnostics.measurePreparationOperation(
                        .clipProbe,
                        detail: "video \(item.filename)"
                    ) {
                        try await makeClip(
                            assetURL: sourceURL,
                            fallbackDuration: segment.duration,
                            includeAudio: true,
                            sourceDescription: "video \(item.filename)",
                            sourceColorInfo: item.colorInfo,
                            captureDateOverlayText: captureDateOverlayText,
                            captureDateOverlayURL: captureDateOverlayURL,
                            diagnostics: diagnostics,
                            isTemporary: false,
                            exportDynamicRange: exportDynamicRange,
                            exportBinaryMode: exportBinaryMode
                        )
                    }
                    if let videoClip {
                        clips.append(videoClip)
                    }
                }
            }

            let completedProgress = 0.05 + (Double(index + 1) / Double(totalSegments)) * 0.18
            reportProgress(completedProgress, handler: progressHandler)
        }

        return clips
    }

    private func resolveTitleCardPreviewAssets(
        from items: [MediaItem],
        photoMaterializer: PhotoAssetMaterializing?,
        diagnostics: RenderDiagnostics
    ) async throws -> [StillImageClipFactory.TitleCardPreviewAsset] {
        var previewAssets: [StillImageClipFactory.TitleCardPreviewAsset] = []
        previewAssets.reserveCapacity(items.count)

        for item in items {
            do {
                let url = try await diagnostics.measurePreparationOperation(
                    .titlePreviewAssetResolution,
                    detail: item.filename
                ) {
                    try await resolveURL(for: item, photoMaterializer: photoMaterializer)
                }
                previewAssets.append(
                    StillImageClipFactory.TitleCardPreviewAsset(
                        url: url,
                        mediaType: item.type,
                        filename: item.filename
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                diagnostics.add("Title preview skipped for \(item.filename): \(describe(error))")
            }
        }

        return previewAssets
    }

    private func formattedCaptureDateOverlayText(for item: MediaItem, style: StyleProfile) -> String? {
        guard style.showCaptureDateOverlay, let captureDate = item.captureDate else {
            return nil
        }
        return CaptureDateOverlayFormatter.string(from: captureDate)
    }

    private func makeCaptureDateOverlayIfNeeded(
        overlayText: String?,
        renderSize: CGSize,
        diagnostics: RenderDiagnostics
    ) -> URL? {
        guard let overlayText else {
            return nil
        }

        do {
            return try captureDateOverlayFactory.makeOverlayPlate(text: overlayText, renderSize: renderSize)
        } catch {
            diagnostics.add("Capture-date overlay skipped: \(describe(error))")
            return nil
        }
    }

    private func resolveURL(for item: MediaItem, photoMaterializer: PhotoAssetMaterializing?) async throws -> URL {
        switch item.locator {
        case let .file(url):
            return url
        case let .photoAsset(localIdentifier):
            guard let photoMaterializer else {
                throw RenderError.unsupportedPhotoAssetWithoutMaterializer(localIdentifier)
            }
            return try await photoMaterializer.materializePhotoAsset(localIdentifier: localIdentifier, preferredFilename: item.filename)
        }
    }

    private func makeClip(
        assetURL: URL,
        fallbackDuration: CMTime,
        includeAudio: Bool,
        sourceDescription: String,
        sourceColorInfo: ColorInfo,
        captureDateOverlayText: String?,
        captureDateOverlayURL: URL?,
        diagnostics: RenderDiagnostics,
        isTemporary: Bool,
        exportDynamicRange: DynamicRange,
        exportBinaryMode: HDRFFmpegBinaryMode
    ) async throws -> InputClip? {
        let asset = AVURLAsset(url: assetURL)
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw RenderError.exportFailed("Unable to load video tracks for \(sourceDescription). \(describe(error))")
        }

        guard let videoTrack = videoTracks.first else {
            throw RenderError.exportFailed("No video tracks found for \(sourceDescription).")
        }

        let assetDuration: CMTime
        do {
            assetDuration = (try await asset.load(.duration))
        } catch {
            throw RenderError.exportFailed("Unable to load duration for \(sourceDescription). \(describe(error))")
        }

        let videoTrackRange = (try? await videoTrack.load(.timeRange))
        let videoTrackDuration = videoTrackRange?.duration
        let clipDuration = smallestPositiveDuration([fallbackDuration, assetDuration, videoTrackDuration]) ?? fallbackDuration
        guard clipDuration > .zero else {
            throw RenderError.exportFailed("Clip duration is invalid for \(sourceDescription).")
        }
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity

        let audioTrack = includeAudio ? (try? await asset.loadTracks(withMediaType: .audio).first) : nil
        let audioTrackDuration: CMTime?
        let audioTrackTimeRange: CMTimeRange?
        if let audioTrack {
            let timeRange = try? await audioTrack.load(.timeRange)
            audioTrackDuration = timeRange?.duration
            audioTrackTimeRange = timeRange
        } else {
            audioTrackDuration = nil
            audioTrackTimeRange = nil
        }

        let codecDescription = await videoCodecDescription(for: videoTrack)
        let resolvedColorInfo = await resolvedColorInfo(
            for: videoTrack,
            assetURL: assetURL,
            fallback: sourceColorInfo,
            exportDynamicRange: exportDynamicRange,
            exportBinaryMode: exportBinaryMode,
            diagnostics: diagnostics,
            isTemporary: isTemporary
        )

        diagnostics.add(
            "Clip ready: source=\(sourceDescription), asset=\(assetURL.path), clipDuration=\(format(clipDuration)), " +
            "assetDuration=\(format(assetDuration)), videoTrackRange=\(format(videoTrackRange)), " +
            "audioTrackRange=\(format(audioTrackTimeRange)), codec=\(codecDescription), " +
            "colorPrimaries=\(resolvedColorInfo.colorPrimaries ?? "nil"), transfer=\(resolvedColorInfo.transferFunction ?? "nil"), " +
            "transferFlavor=\(resolvedColorInfo.transferFlavor.rawValue), hdrMetadata=\(resolvedColorInfo.hdrMetadataFlavor.rawValue), " +
            "isHDR=\(resolvedColorInfo.isHDR), temp=\(isTemporary), " +
            "captureDateOverlay=\(captureDateOverlayText ?? "none")"
        )

        return InputClip(
            sourceAsset: asset,
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            assetURL: assetURL,
            videoTrackTimeRange: videoTrackRange,
            audioTrackTimeRange: audioTrackTimeRange,
            videoTrackDuration: videoTrackDuration,
            audioTrackDuration: audioTrackDuration,
            duration: clipDuration,
            preferredTransform: preferredTransform,
            naturalSize: naturalSize,
            sourceDescription: sourceDescription,
            isTemporary: isTemporary,
            includeAudio: includeAudio,
            colorInfo: resolvedColorInfo,
            captureDateOverlayText: captureDateOverlayText,
            captureDateOverlayURL: captureDateOverlayURL
        )
    }

    private func effectiveTransitionDuration(clips: [InputClip], requestedSeconds: Double) -> CMTime {
        guard clips.count > 1, requestedSeconds > 0 else {
            return .zero
        }

        let requested = CMTime(seconds: requestedSeconds, preferredTimescale: 600)
        let halfOfShortest = clips
            .map { CMTime(seconds: max($0.duration.seconds / 2.0, 0), preferredTimescale: 600) }
            .min() ?? .zero

        return minTime(requested, halfOfShortest)
    }

    private func resolveRenderSize(from timeline: Timeline, policy: ResolutionPolicy) -> CGSize {
        RenderSizing.renderSize(for: timeline, policy: policy)
    }

    private func resolveFrameRate(from timeline: Timeline, policy: FrameRatePolicy) -> Int {
        RenderSizing.frameRate(for: timeline, policy: policy)
    }

    func constrainedRenderSizeForExport(requestedSize: CGSize, profile: ExportProfile) -> CGSize {
        _ = profile
        return normalizedRenderSize(requestedSize)
    }

    struct VideoColorConfiguration: Equatable {
        let colorPrimaries: String
        let colorTransferFunction: String
        let colorYCbCrMatrix: String
    }

    enum HDRMetadataPolicy: Equatable {
        case autoRecomputeDynamicMetadata
        case hlgWithoutDynamicMetadata(reason: String)

        var insertionMode: String {
            switch self {
            case .autoRecomputeDynamicMetadata:
                return kVTHDRMetadataInsertionMode_Auto as String
            case .hlgWithoutDynamicMetadata:
                return kVTHDRMetadataInsertionMode_None as String
            }
        }

        var insertionModeLabel: String {
            switch self {
            case .autoRecomputeDynamicMetadata:
                return "Auto"
            case .hlgWithoutDynamicMetadata:
                return "None"
            }
        }

        var preserveDynamicHDRMetadata: Bool {
            // Reader/writer frame modification path should regenerate dynamic metadata.
            false
        }

        var fallbackReason: String? {
            switch self {
            case .autoRecomputeDynamicMetadata:
                return nil
            case let .hlgWithoutDynamicMetadata(reason):
                return reason
            }
        }
    }

    func colorConfiguration(for dynamicRange: DynamicRange) -> VideoColorConfiguration {
        switch dynamicRange {
        case .sdr:
            return VideoColorConfiguration(
                colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
                colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
                colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2
            )
        case .hdr:
            return VideoColorConfiguration(
                colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
                colorTransferFunction: AVVideoTransferFunction_ITU_R_2100_HLG,
                colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020
            )
        }
    }

    func shouldApplyHDRToneMapping(for profile: ExportProfile) -> Bool {
        profile.dynamicRange == .hdr
    }

    private struct ToneMapAudioPipeline {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
    }

    private struct ToneMapAudioPipelineState {
        let pipeline: ToneMapAudioPipeline
        var isExhausted: Bool = false
        var appendedSamples: Int = 0
    }

    private func applyHDRToneMapping(
        from inputURL: URL,
        to outputURL: URL,
        container: ContainerFormat,
        diagnostics: RenderDiagnostics,
        progressHandler: (@MainActor @Sendable (Double) -> Void)?
    ) async throws {
        do {
            let sourceAsset = AVURLAsset(url: inputURL)
            let videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw RenderError.exportFailed("HDR tone-mapping requires a video track in intermediate export.")
            }

            let sourceDuration = try await sourceAsset.load(.duration)
            let sourceNaturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
            let outputSize = CGSize(
                width: evenDimension(max(2, Int(sourceNaturalSize.width.rounded()))),
                height: evenDimension(max(2, Int(sourceNaturalSize.height.rounded())))
            )
            let nominalFrameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
            let frameRate = max(Double(nominalFrameRate), 30.0)
            let estimatedFrames = max(Int(ceil(max(sourceDuration.seconds, 0.01) * frameRate)), 1)

            let reader = try AVAssetReader(asset: sourceAsset)
            let readerPixelFormat = hdrToneMapPixelFormat()
            let videoOutputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(readerPixelFormat)
            ]
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else {
                throw RenderError.exportFailed("Unable to configure HDR tone-map reader video output.")
            }
            reader.add(videoOutput)

            let fileType = fileType(for: container)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
            let hdrColorConfiguration = colorConfiguration(for: .hdr)
            var hdrMetadataPolicy: HDRMetadataPolicy = .autoRecomputeDynamicMetadata
            let writerProfileLevel = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            var videoWriterSettings = hdrToneMappedVideoSettings(
                renderSize: outputSize,
                frameRate: frameRate,
                colorConfiguration: hdrColorConfiguration,
                metadataPolicy: hdrMetadataPolicy
            )
            if !writer.canApply(outputSettings: videoWriterSettings, forMediaType: .video) {
                hdrMetadataPolicy = .hlgWithoutDynamicMetadata(
                    reason: "Encoder rejected HDR metadata insertion mode Auto; falling back to insertion mode None."
                )
                videoWriterSettings = hdrToneMappedVideoSettings(
                    renderSize: outputSize,
                    frameRate: frameRate,
                    colorConfiguration: hdrColorConfiguration,
                    metadataPolicy: hdrMetadataPolicy
                )
            }
            guard writer.canApply(outputSettings: videoWriterSettings, forMediaType: .video) else {
                throw RenderError.exportFailed("Unable to apply HDR writer settings for tone-mapping pass.")
            }

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoWriterSettings)
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else {
                throw RenderError.exportFailed("Unable to add HDR tone-map writer video input.")
            }
            writer.add(videoInput)

            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(readerPixelFormat),
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )

            let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
            var audioPipelines: [ToneMapAudioPipelineState] = []
            for audioTrack in audioTracks {
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    continue
                }
                reader.add(output)

                let sourceFormatHint = (try? await audioTrack.load(.formatDescriptions))?.first
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: sourceFormatHint)
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else {
                    continue
                }
                writer.add(input)
                audioPipelines.append(ToneMapAudioPipelineState(pipeline: ToneMapAudioPipeline(output: output, input: input)))
            }

            guard writer.startWriting() else {
                throw RenderError.exportFailed(writer.error?.localizedDescription ?? "Failed to start HDR tone-map writer.")
            }
            guard reader.startReading() else {
                throw RenderError.exportFailed(reader.error?.localizedDescription ?? "Failed to start HDR tone-map reader.")
            }
            writer.startSession(atSourceTime: .zero)

            diagnostics.add(
                "HDR tone-map pass started: source=\(inputURL.path), output=\(outputURL.path), " +
                "size=\(Int(outputSize.width))x\(Int(outputSize.height)), frameRate=\(String(format: "%.2f", frameRate)), estimatedFrames=\(estimatedFrames)"
            )
            diagnostics.add("HDR tone-map reader pixel format: \(describePixelFormat(readerPixelFormat))")
            diagnostics.add("HDR tone-map writer profile: \(writerProfileLevel)")
            diagnostics.add("HDR tone-map writer metadata insertion mode: \(hdrMetadataPolicy.insertionModeLabel)")
            diagnostics.add("HDR tone-map writer preserve dynamic metadata: \(hdrMetadataPolicy.preserveDynamicHDRMetadata)")
            if let fallbackReason = hdrMetadataPolicy.fallbackReason {
                diagnostics.add("HDR tone-map writer fallback: \(fallbackReason)")
            }

            let ciContext = CIContext(options: [CIContextOption.cacheIntermediates: false])
            guard let hdrColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG) else {
                throw RenderError.exportFailed("Unable to initialize HDR color space for tone-map pass.")
            }
            var frameCount = 0
            var sourceColorSpaceCache: [String: CGColorSpace] = [:]
            var loggedSourceColorSpace = false

            while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()

                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    continue
                }

                try await waitForWriterInputReadiness(
                    videoInput,
                    writer: writer,
                    context: "video frame \(frameCount + 1)"
                )
                guard let pool = adaptor.pixelBufferPool else {
                    throw RenderError.exportFailed("HDR tone-map writer pixel buffer pool unavailable.")
                }

                var destinationBuffer: CVPixelBuffer?
                let creationStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationBuffer)
                guard creationStatus == kCVReturnSuccess, let destinationBuffer else {
                    throw RenderError.exportFailed("Unable to allocate destination pixel buffer for HDR tone-map pass.")
                }

                let sourceImage = CIImage(
                    cvImageBuffer: imageBuffer,
                    options: [.colorSpace: toneMapSourceColorSpace(for: imageBuffer, cache: &sourceColorSpaceCache)]
                )
                let mappedImage = toneMappedHDRImage(sourceImage)
                let renderBounds = CGRect(origin: .zero, size: outputSize)
                ciContext.render(mappedImage, to: destinationBuffer, bounds: renderBounds, colorSpace: hdrColorSpace)

                if !loggedSourceColorSpace {
                    let colorPrimaries = cvAttachmentString(for: imageBuffer, key: kCVImageBufferColorPrimariesKey) ?? "nil"
                    let transfer = cvAttachmentString(for: imageBuffer, key: kCVImageBufferTransferFunctionKey) ?? "nil"
                    let matrix = cvAttachmentString(for: imageBuffer, key: kCVImageBufferYCbCrMatrixKey) ?? "nil"
                    let sourceName = toneMapSourceColorSpaceName(
                        colorPrimaries: cvAttachmentString(for: imageBuffer, key: kCVImageBufferColorPrimariesKey),
                        transferFunction: cvAttachmentString(for: imageBuffer, key: kCVImageBufferTransferFunctionKey)
                    ) as String
                    diagnostics.add(
                        "HDR tone-map source frame color tags: primaries=\(colorPrimaries), transfer=\(transfer), matrix=\(matrix), resolvedSourceSpace=\(sourceName)"
                    )
                    loggedSourceColorSpace = true
                }

                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard adaptor.append(destinationBuffer, withPresentationTime: presentationTime) else {
                    throw RenderError.exportFailed(writer.error?.localizedDescription ?? "Failed to append HDR tone-mapped frame.")
                }
                _ = try appendReadyAudioSamples(
                    from: &audioPipelines,
                    writer: writer,
                    perTrackLimit: 4
                )

                frameCount += 1
                if frameCount == 1 || frameCount.isMultiple(of: 12) {
                    let toneMapProgress = min(Double(frameCount) / Double(estimatedFrames), 1.0)
                    reportProgress(0.55 + toneMapProgress * 0.44, handler: progressHandler)
                }
            }
            videoInput.markAsFinished()

            if reader.status == .failed {
                throw RenderError.exportFailed(reader.error?.localizedDescription ?? "HDR tone-map video read failed.")
            }

            while audioPipelines.contains(where: { !$0.isExhausted }) {
                var appendedInPass = 0
                for index in audioPipelines.indices {
                    if audioPipelines[index].isExhausted {
                        continue
                    }

                    let pipeline = audioPipelines[index].pipeline
                    try await waitForWriterInputReadiness(
                        pipeline.input,
                        writer: writer,
                        context: "audio track \(index + 1)"
                    )
                    guard let sampleBuffer = pipeline.output.copyNextSampleBuffer() else {
                        pipeline.input.markAsFinished()
                        audioPipelines[index].isExhausted = true
                        continue
                    }
                    guard pipeline.input.append(sampleBuffer) else {
                        throw RenderError.exportFailed(writer.error?.localizedDescription ?? "Failed to append audio during HDR tone-map pass.")
                    }
                    audioPipelines[index].appendedSamples += 1
                    appendedInPass += 1

                    let burstAppended = try appendReadyAudioSamples(
                        from: &audioPipelines,
                        writer: writer,
                        trackIndex: index,
                        perTrackLimit: 8
                    )
                    appendedInPass += burstAppended
                }

                if appendedInPass == 0 {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            }

            if reader.status == .failed {
                throw RenderError.exportFailed(reader.error?.localizedDescription ?? "HDR tone-map read failed.")
            }

            try await finish(writer: writer)
            let appendedAudioSamples = audioPipelines.reduce(0) { $0 + $1.appendedSamples }
            diagnostics.add(
                "HDR tone-map pass completed: renderedFrames=\(frameCount), audioTracks=\(audioPipelines.count), audioSamples=\(appendedAudioSamples)"
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw RenderError.exportFailed("HDR tone-mapping failed. \(describe(error))")
        }
    }

    func hdrToneMappedVideoSettings(
        renderSize: CGSize,
        frameRate: Double,
        colorConfiguration: VideoColorConfiguration,
        metadataPolicy: HDRMetadataPolicy
    ) -> [String: Any] {
        let width = Int(renderSize.width.rounded())
        let height = Int(renderSize.height.rounded())
        let bitrate = estimatedHDRBitrate(renderSize: renderSize, frameRate: frameRate)

        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: colorConfiguration.colorPrimaries,
                AVVideoTransferFunctionKey: colorConfiguration.colorTransferFunction,
                AVVideoYCbCrMatrixKey: colorConfiguration.colorYCbCrMatrix
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                kVTCompressionPropertyKey_HDRMetadataInsertionMode as String: metadataPolicy.insertionMode,
                kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String: metadataPolicy.preserveDynamicHDRMetadata
            ]
        ]
    }

    private func toneMappedHDRImage(_ sourceImage: CIImage) -> CIImage {
        // Keep HDR pass visually identity-based; writer metadata policy handles HDR signaling.
        sourceImage
    }

    func toneMapSourceColorSpaceName(colorPrimaries: String?, transferFunction: String?) -> CFString {
        if transferFunction == AVVideoTransferFunction_ITU_R_2100_HLG ||
            transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            return CGColorSpace.itur_2100_HLG
        }

        if transferFunction == AVVideoTransferFunction_SMPTE_ST_2084_PQ ||
            transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
            return CGColorSpace.itur_2100_PQ
        }

        if colorPrimaries == AVVideoColorPrimaries_P3_D65 ||
            colorPrimaries == kCVImageBufferColorPrimaries_P3_D65 as String ||
            colorPrimaries == kCVImageBufferColorPrimaries_DCI_P3 as String {
            return CGColorSpace.displayP3
        }

        if colorPrimaries == AVVideoColorPrimaries_ITU_R_2020 ||
            colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String {
            // BT.2020 content without explicit HDR transfer can safely map as HDR HLG working space.
            return CGColorSpace.itur_2100_HLG
        }

        return CGColorSpace.itur_709
    }

    private func toneMapSourceColorSpace(
        for imageBuffer: CVImageBuffer,
        cache: inout [String: CGColorSpace]
    ) -> CGColorSpace {
        let colorPrimaries = cvAttachmentString(for: imageBuffer, key: kCVImageBufferColorPrimariesKey)
        let transfer = cvAttachmentString(for: imageBuffer, key: kCVImageBufferTransferFunctionKey)
        let resolvedName = toneMapSourceColorSpaceName(colorPrimaries: colorPrimaries, transferFunction: transfer) as String

        if let cached = cache[resolvedName] {
            return cached
        }

        let resolved = CGColorSpace(name: resolvedName as CFString) ?? CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        cache[resolvedName] = resolved
        return resolved
    }

    private func cvAttachmentString(for imageBuffer: CVImageBuffer, key: CFString) -> String? {
        guard let value = CVBufferCopyAttachment(imageBuffer, key, nil) else {
            return nil
        }
        return value as? String
    }

    private func hdrToneMapPixelFormat() -> OSType {
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    private func describePixelFormat(_ pixelFormat: OSType) -> String {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return "kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange"
        case kCVPixelFormatType_32BGRA:
            return "kCVPixelFormatType_32BGRA"
        default:
            return String(format: "0x%08X", pixelFormat)
        }
    }

    private func waitForWriterInputReadiness(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter,
        context: String
    ) async throws {
        let stallTimeoutSeconds: TimeInterval = 120
        let startedAt = Date()

        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            switch writer.status {
            case .failed:
                throw RenderError.exportFailed(
                    writer.error?.localizedDescription ?? "HDR tone-map writer failed while waiting for \(context)."
                )
            case .cancelled:
                throw RenderError.exportFailed("HDR tone-map writer was cancelled while waiting for \(context).")
            case .completed:
                throw RenderError.exportFailed("HDR tone-map writer completed unexpectedly while waiting for \(context).")
            default:
                break
            }

            if Date().timeIntervalSince(startedAt) >= stallTimeoutSeconds {
                throw RenderError.exportFailed(
                    "Timed out after \(Int(stallTimeoutSeconds))s waiting for writer readiness (\(context)); writer status \(writer.status.rawValue)."
                )
            }

            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func appendReadyAudioSamples(
        from pipelines: inout [ToneMapAudioPipelineState],
        writer: AVAssetWriter,
        trackIndex: Int? = nil,
        perTrackLimit: Int
    ) throws -> Int {
        let indices: [Int]
        if let trackIndex {
            indices = [trackIndex]
        } else {
            indices = Array(pipelines.indices)
        }

        var appended = 0
        for index in indices {
            guard pipelines.indices.contains(index), !pipelines[index].isExhausted else {
                continue
            }

            let pipeline = pipelines[index].pipeline
            var appendedForTrack = 0
            while appendedForTrack < perTrackLimit, pipeline.input.isReadyForMoreMediaData {
                guard let sampleBuffer = pipeline.output.copyNextSampleBuffer() else {
                    pipeline.input.markAsFinished()
                    pipelines[index].isExhausted = true
                    break
                }

                guard pipeline.input.append(sampleBuffer) else {
                    throw RenderError.exportFailed(writer.error?.localizedDescription ?? "Failed to append audio during HDR tone-map pass.")
                }

                pipelines[index].appendedSamples += 1
                appendedForTrack += 1
                appended += 1
            }
        }

        return appended
    }

    private func finish(writer: AVAssetWriter) async throws {
        let writerReference = UncheckedSendableReference(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                let writer = writerReference.value
                if writer.status == .completed {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: RenderError.exportFailed(
                            writer.error?.localizedDescription ?? "HDR tone-map writer failed with status \(writer.status.rawValue)"
                        )
                    )
                }
            }
        }
    }

    private func fileType(for container: ContainerFormat) -> AVFileType {
        container == .mp4 ? .mp4 : .mov
    }

    private func temporaryRenderURL(fileType: AVFileType) -> URL {
        temporaryArtifactURL(pathExtension: fileType == .mp4 ? "mp4" : "mov")
    }

    private func temporaryArtifactURL(pathExtension: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MonthlyVideoGenerator", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension)
    }

    private func cleanupTemporaryFiles(_ urls: inout [URL], diagnostics: RenderDiagnostics) {
        guard !urls.isEmpty else {
            return
        }

        let fileManager = FileManager.default
        for url in urls {
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                    diagnostics.add("Removed temporary artifact: \(url.path)")
                }
            } catch {
                diagnostics.add("Temporary artifact cleanup skipped for \(url.path): \(describe(error))")
            }
        }
        urls.removeAll(keepingCapacity: false)
    }

    private func estimatedHDRBitrate(renderSize: CGSize, frameRate: Double) -> Int {
        let pixelsPerFrame = max(renderSize.width * renderSize.height, 1)
        let bitsPerPixel: Double = 0.11
        let estimate = pixelsPerFrame * frameRate * bitsPerPixel
        return max(Int(estimate.rounded()), 12_000_000)
    }

    private func evenDimension(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value + 1
    }

    private func normalizedRenderSize(_ size: CGSize) -> CGSize {
        let width = evenDimension(max(2, Int(size.width.rounded())))
        let height = evenDimension(max(2, Int(size.height.rounded())))
        return CGSize(width: width, height: height)
    }

    private func reportProgress(_ value: Double, handler: (@MainActor @Sendable (Double) -> Void)?) {
        let clamped = min(max(value, 0), 1)
        guard let handler else { return }
        Task { @MainActor in
            handler(clamped)
        }
    }

    private func reportStatus(_ value: String, handler: (@MainActor @Sendable (String) -> Void)?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let handler else { return }
        Task { @MainActor in
            handler(trimmed)
        }
    }

    private func add(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeAdd(lhs, rhs)
    }

    private func subtract(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeSubtract(lhs, rhs)
    }

    private func minTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }

    private struct InputClip {
        // Keep a strong reference to the backing asset for track lifetime safety.
        let sourceAsset: AVAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let assetURL: URL
        let videoTrackTimeRange: CMTimeRange?
        let audioTrackTimeRange: CMTimeRange?
        let videoTrackDuration: CMTime?
        let audioTrackDuration: CMTime?
        let duration: CMTime
        let preferredTransform: CGAffineTransform
        let naturalSize: CGSize
        let sourceDescription: String
        let isTemporary: Bool
        let includeAudio: Bool
        let colorInfo: ColorInfo
        let captureDateOverlayText: String?
        let captureDateOverlayURL: URL?
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

    private func videoCodecDescription(for track: AVAssetTrack) async -> String {
        guard let formatDescriptions = try? await track.load(.formatDescriptions) else {
            return "unknown"
        }
        guard let firstDescription = formatDescriptions.first else {
            return "unknown"
        }
        let mediaSubType = CMFormatDescriptionGetMediaSubType(firstDescription)
        let fourcc = fourCCString(mediaSubType)
        return "\(fourcc) (\(mediaSubType))"
    }

    private func resolvedColorInfo(
        for track: AVAssetTrack,
        assetURL: URL,
        fallback: ColorInfo,
        exportDynamicRange: DynamicRange,
        exportBinaryMode: HDRFFmpegBinaryMode,
        diagnostics: RenderDiagnostics,
        isTemporary: Bool
    ) async -> ColorInfo {
        guard let formatDescriptions = try? await track.load(.formatDescriptions),
              let firstDescription = formatDescriptions.first else {
            return fallback
        }

        let cmFormatDescription = firstDescription as CMFormatDescription
        let extensions = CMFormatDescriptionGetExtensions(cmFormatDescription) as NSDictionary?
        let primaries = extensions?[kCMFormatDescriptionExtension_ColorPrimaries] as? String ?? fallback.colorPrimaries
        let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction] as? String ?? fallback.transferFunction
        let transferFlavor = ColorTransferFlavor.inferred(
            isHDR: fallback.isHDR,
            transferFunction: transfer
        )
        var hdrMetadataFlavor = fallback.hdrMetadataFlavor

        if exportDynamicRange == .hdr,
           !isTemporary,
           hdrMetadataFlavor == .none,
           transferFlavor == .hlg {
            hdrMetadataFlavor = probedHDRMetadataFlavor(
                for: assetURL,
                binaryMode: exportBinaryMode,
                diagnostics: diagnostics
            )
        }

        return ColorInfo(
            isHDR: fallback.isHDR || transferFlavor != .sdr || hdrMetadataFlavor != .none,
            colorPrimaries: primaries,
            transferFunction: transfer,
            transferFlavor: transferFlavor,
            hdrMetadataFlavor: hdrMetadataFlavor
        )
    }

    private func probedHDRMetadataFlavor(
        for assetURL: URL,
        binaryMode: HDRFFmpegBinaryMode,
        diagnostics: RenderDiagnostics
    ) -> HDRMetadataFlavor {
        do {
            let binary = try FFmpegBinaryResolver().resolveProbeBinary(mode: binaryMode)
            let metadata = try FFprobeSourceMetadataProbe().probeVideoSourceMetadata(
                at: assetURL,
                ffprobeURL: binary.ffprobeURL
            )
            if metadata.hdrMetadataFlavor == .dolbyVision {
                diagnostics.add("HDR source metadata probe: \(assetURL.lastPathComponent) includes Dolby Vision side data.")
            }
            return metadata.hdrMetadataFlavor
        } catch {
            diagnostics.add("HDR source metadata probe skipped for \(assetURL.lastPathComponent): \(describe(error))")
            return .none
        }
    }

    private func fourCCString(_ value: FourCharCode) -> String {
        let bigEndian = value.bigEndian
        let bytes: [UInt8] = [
            UInt8((bigEndian >> 24) & 0xff),
            UInt8((bigEndian >> 16) & 0xff),
            UInt8((bigEndian >> 8) & 0xff),
            UInt8(bigEndian & 0xff)
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 <= 126 }
        if printable, let text = String(bytes: bytes, encoding: .ascii) {
            return text
        }
        return "0x" + bytes.map { String(format: "%02X", $0) }.joined()
    }

    private func smallestPositiveDuration(_ values: [CMTime?]) -> CMTime? {
        values
            .compactMap { $0 }
            .filter { isPositiveFiniteTime($0) }
            .min { CMTimeCompare($0, $1) < 0 }
    }

    private func minPositiveDuration(_ values: CMTime?...) -> CMTime? {
        smallestPositiveDuration(values)
    }

    private func isPositiveFiniteTime(_ value: CMTime) -> Bool {
        value.isValid && value.isNumeric && value.seconds.isFinite && value > .zero
    }

    private func validStartTime(_ time: CMTime?) -> CMTime {
        guard let time else { return .zero }
        guard time.isValid, time.isNumeric, time.seconds.isFinite else { return .zero }
        return time
    }

    private func format(_ time: CMTime) -> String {
        guard time.isValid else { return "invalid" }
        guard time.isNumeric else { return "non-numeric" }
        return String(format: "%.6fs", time.seconds)
    }

    private func format(_ timeRange: CMTimeRange?) -> String {
        guard let timeRange else { return "nil" }
        return "[start=\(format(timeRange.start)), duration=\(format(timeRange.duration)), end=\(format(timeRange.end))]"
    }

    private func userFacingMessage(from error: Error) -> String {
        if let renderError = error as? RenderError {
            switch renderError {
            case .exportFailed(let message):
                return message
            default:
                return renderError.errorDescription ?? describe(error)
            }
        }
        return describe(error)
    }

    private func reserveDiagnosticsFileURL(outputTarget: OutputTarget) -> URL? {
        let fileManager = FileManager.default
        let filename = diagnosticsFilename()
        let preferredDirectory = outputTarget.directory
        let fallbackDirectory = fileManager.temporaryDirectory.appendingPathComponent("MonthlyVideoGenerator/Diagnostics", isDirectory: true)

        for directory in [preferredDirectory, fallbackDirectory] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let fileURL = directory.appendingPathComponent(filename)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    try Data().write(to: fileURL, options: .atomic)
                    return fileURL
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func persistDiagnosticsReport(_ report: String, outputTarget: OutputTarget, preferredURL: URL?) -> URL? {
        if let preferredURL, writeDiagnosticsReport(report, to: preferredURL) {
            return preferredURL
        }
        return writeDiagnosticsFile(report, outputTarget: outputTarget)
    }

    private func writeDiagnosticsFile(_ report: String, outputTarget: OutputTarget) -> URL? {
        let fileManager = FileManager.default
        let filename = diagnosticsFilename()
        let preferredDirectory = outputTarget.directory
        let fallbackDirectory = fileManager.temporaryDirectory.appendingPathComponent("MonthlyVideoGenerator/Diagnostics", isDirectory: true)

        for directory in [preferredDirectory, fallbackDirectory] {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let fileURL = directory.appendingPathComponent(filename)
                if writeDiagnosticsReport(report, to: fileURL) {
                    return fileURL
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func diagnosticsFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.timeZone = .current
        return "export-diagnostics-\(formatter.string(from: Date())).log"
    }

    private func writeDiagnosticsReport(_ report: String, to fileURL: URL) -> Bool {
        guard let data = report.data(using: .utf8) else {
            return false
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    final class RenderDiagnostics: @unchecked Sendable {
        enum Phase: String, CaseIterable, Hashable {
            case renderSetup
            case clipMaterialization
            case directFFmpegExport
            case progressiveHDRExecution
            case diagnosticsFinalization

            var label: String {
                switch self {
                case .renderSetup:
                    return "Render setup"
                case .clipMaterialization:
                    return "Clip materialization"
                case .directFFmpegExport:
                    return "FFmpeg/direct export"
                case .progressiveHDRExecution:
                    return "Progressive HDR execution"
                case .diagnosticsFinalization:
                    return "Diagnostics finalization / cleanup"
                }
            }
        }

        enum PreparationOperationKind: String, CaseIterable, Hashable {
            case titlePreviewAssetResolution
            case titleCardGeneration
            case stillImageSourceResolution
            case stillClipGeneration
            case videoSourceResolution
            case captureDateOverlayGeneration
            case clipProbe

            var label: String {
                switch self {
                case .titlePreviewAssetResolution:
                    return "Title preview asset resolution"
                case .titleCardGeneration:
                    return "Title card generation"
                case .stillImageSourceResolution:
                    return "Still-image source resolution"
                case .stillClipGeneration:
                    return "Still clip generation"
                case .videoSourceResolution:
                    return "Video source resolution / Photos materialization"
                case .captureDateOverlayGeneration:
                    return "Capture-date overlay generation"
                case .clipProbe:
                    return "Clip probe / makeClip"
                }
            }
        }

        private struct PhaseSummary {
            var count: Int
            var totalDurationSeconds: TimeInterval
        }

        private struct PreparationSummary {
            var count: Int
            var totalDurationSeconds: TimeInterval
            var maxDurationSeconds: TimeInterval
        }

        private struct PreparationOperationRecord {
            let kind: PreparationOperationKind
            let detail: String
            let elapsedSeconds: TimeInterval
        }

        private let startedAt = Date()
        private let runID = UUID().uuidString
        private let lock = NSLock()
        private var lines: [String] = []
        private var phaseSummaries: [Phase: PhaseSummary] = [:]
        private var preparationSummaries: [PreparationOperationKind: PreparationSummary] = [:]
        private var slowestPreparationOperations: [PreparationOperationRecord] = []
        private var ffmpegCommandSummaries: [FFmpegHDRRenderer.CommandExecutionStats] = []

        func add(_ line: String) {
            lock.lock()
            lines.append("[\(timestamp())] \(line)")
            lock.unlock()
        }

        @discardableResult
        func measurePhase<T>(_ phase: Phase, _ operation: () throws -> T) rethrows -> T {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            do {
                let result = try operation()
                recordPhase(phase, elapsedSeconds: elapsedSeconds(since: startedAt))
                return result
            } catch {
                recordPhase(phase, elapsedSeconds: elapsedSeconds(since: startedAt))
                throw error
            }
        }

        @discardableResult
        func measurePhase<T>(_ phase: Phase, _ operation: () async throws -> T) async rethrows -> T {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            do {
                let result = try await operation()
                recordPhase(phase, elapsedSeconds: elapsedSeconds(since: startedAt))
                return result
            } catch {
                recordPhase(phase, elapsedSeconds: elapsedSeconds(since: startedAt))
                throw error
            }
        }

        @discardableResult
        func measurePreparationOperation<T>(
            _ kind: PreparationOperationKind,
            detail: String,
            _ operation: () throws -> T
        ) rethrows -> T {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            do {
                let result = try operation()
                recordPreparationOperation(kind, detail: detail, elapsedSeconds: elapsedSeconds(since: startedAt))
                return result
            } catch {
                recordPreparationOperation(kind, detail: detail, elapsedSeconds: elapsedSeconds(since: startedAt))
                throw error
            }
        }

        @discardableResult
        func measurePreparationOperation<T>(
            _ kind: PreparationOperationKind,
            detail: String,
            _ operation: () async throws -> T
        ) async rethrows -> T {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            do {
                let result = try await operation()
                recordPreparationOperation(kind, detail: detail, elapsedSeconds: elapsedSeconds(since: startedAt))
                return result
            } catch {
                recordPreparationOperation(kind, detail: detail, elapsedSeconds: elapsedSeconds(since: startedAt))
                throw error
            }
        }

        func recordPhase(_ phase: Phase, elapsedSeconds: TimeInterval) {
            lock.lock()
            var summary = phaseSummaries[phase] ?? PhaseSummary(count: 0, totalDurationSeconds: 0)
            summary.count += 1
            summary.totalDurationSeconds += elapsedSeconds
            phaseSummaries[phase] = summary
            lock.unlock()
        }

        func recordPreparationOperation(
            _ kind: PreparationOperationKind,
            detail: String,
            elapsedSeconds: TimeInterval
        ) {
            lock.lock()
            var summary = preparationSummaries[kind] ?? PreparationSummary(count: 0, totalDurationSeconds: 0, maxDurationSeconds: 0)
            summary.count += 1
            summary.totalDurationSeconds += elapsedSeconds
            summary.maxDurationSeconds = max(summary.maxDurationSeconds, elapsedSeconds)
            preparationSummaries[kind] = summary

            slowestPreparationOperations.append(
                PreparationOperationRecord(kind: kind, detail: detail, elapsedSeconds: elapsedSeconds)
            )
            slowestPreparationOperations.sort {
                if $0.elapsedSeconds == $1.elapsedSeconds {
                    return $0.detail < $1.detail
                }
                return $0.elapsedSeconds > $1.elapsedSeconds
            }
            if slowestPreparationOperations.count > 5 {
                slowestPreparationOperations.removeLast(slowestPreparationOperations.count - 5)
            }
            lock.unlock()
        }

        func recordFFmpegCommandSummary(_ summary: FFmpegHDRRenderer.CommandExecutionStats) {
            lock.lock()
            ffmpegCommandSummaries.append(summary)
            lock.unlock()
        }

        func renderReport(outcome: String, error: Error?) -> String {
            let snapshot = snapshotState()

            var reportLines: [String] = []
            reportLines.append("MonthlyVideoGenerator export diagnostics")
            reportLines.append("run_id=\(runID)")
            reportLines.append("started_at=\(startedAt.ISO8601Format())")
            reportLines.append("ended_at=\(Date().ISO8601Format())")
            reportLines.append("outcome=\(outcome)")
            reportLines.append("event_count=\(snapshot.lines.count)")
            if let error {
                let nsError = error as NSError
                reportLines.append("error=\(sanitizeHeaderValue(String(describing: error)))")
                reportLines.append("error_domain=\(nsError.domain)")
                reportLines.append("error_code=\(nsError.code)")
                reportLines.append("error_description=\(sanitizeHeaderValue(nsError.localizedDescription))")
                if let reason = nsError.localizedFailureReason, !reason.isEmpty {
                    reportLines.append("error_reason=\(sanitizeHeaderValue(reason))")
                }
                if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
                    reportLines.append("error_suggestion=\(sanitizeHeaderValue(suggestion))")
                }
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    reportLines.append(
                        "underlying_error=\(underlying.domain):\(underlying.code):\(sanitizeHeaderValue(underlying.localizedDescription))"
                    )
                }
            } else {
                reportLines.append("error=none")
                reportLines.append("error_domain=none")
                reportLines.append("error_code=none")
            }

            reportLines.append("")
            reportLines.append("Timing Summary")
            reportLines.append(contentsOf: timingSummaryLines(from: snapshot.phaseSummaries))
            reportLines.append("")
            reportLines.append("Clip Preparation Breakdown")
            reportLines.append(contentsOf: preparationBreakdownLines(from: snapshot.preparationSummaries))
            reportLines.append("")
            reportLines.append("Slowest Preparation Operations")
            reportLines.append(contentsOf: slowPreparationLines(from: snapshot.slowestPreparationOperations))
            reportLines.append("")
            reportLines.append("FFmpeg Command Summary")
            reportLines.append(contentsOf: FFmpegHDRRenderer.commandSummaryLines(from: snapshot.ffmpegCommandSummaries))
            reportLines.append("")
            reportLines.append(contentsOf: snapshot.lines)
            reportLines.append("")
            reportLines.append("end_of_report")
            return reportLines.joined(separator: "\n")
        }

        private func snapshotState() -> (
            lines: [String],
            phaseSummaries: [Phase: PhaseSummary],
            preparationSummaries: [PreparationOperationKind: PreparationSummary],
            slowestPreparationOperations: [PreparationOperationRecord],
            ffmpegCommandSummaries: [FFmpegHDRRenderer.CommandExecutionStats]
        ) {
            lock.lock()
            let snapshot = (
                lines: lines,
                phaseSummaries: phaseSummaries,
                preparationSummaries: preparationSummaries,
                slowestPreparationOperations: slowestPreparationOperations,
                ffmpegCommandSummaries: ffmpegCommandSummaries
            )
            lock.unlock()
            return snapshot
        }

        private func timingSummaryLines(from summaries: [Phase: PhaseSummary]) -> [String] {
            var lines = ["- Total render elapsed: \(formatSeconds(Date().timeIntervalSince(startedAt)))"]
            let phaseLines = Phase.allCases.compactMap { phase -> String? in
                guard let summary = summaries[phase] else {
                    return nil
                }
                let average = summary.totalDurationSeconds / Double(max(summary.count, 1))
                return "- \(phase.label): count=\(summary.count) | total=\(formatSeconds(summary.totalDurationSeconds)) | avg=\(formatSeconds(average))"
            }
            if phaseLines.isEmpty {
                lines.append("- none recorded")
            } else {
                lines.append(contentsOf: phaseLines)
            }
            return lines
        }

        private func preparationBreakdownLines(from summaries: [PreparationOperationKind: PreparationSummary]) -> [String] {
            let lines = PreparationOperationKind.allCases.compactMap { kind -> String? in
                guard let summary = summaries[kind] else {
                    return nil
                }
                let average = summary.totalDurationSeconds / Double(max(summary.count, 1))
                return "- \(kind.label): count=\(summary.count) | total=\(formatSeconds(summary.totalDurationSeconds)) | avg=\(formatSeconds(average)) | max=\(formatSeconds(summary.maxDurationSeconds))"
            }
            return lines.isEmpty ? ["- none recorded"] : lines
        }

        private func slowPreparationLines(from operations: [PreparationOperationRecord]) -> [String] {
            guard !operations.isEmpty else {
                return ["- none recorded"]
            }
            return operations.enumerated().map { index, operation in
                "- \(index + 1). \(operation.kind.label): \(operation.detail) | elapsed=\(formatSeconds(operation.elapsedSeconds))"
            }
        }

        private func sanitizeHeaderValue(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
        }

        private func formatSeconds(_ value: TimeInterval) -> String {
            String(format: "%.2fs", max(value, 0))
        }

        private func elapsedSeconds(since startedAtNanoseconds: UInt64) -> TimeInterval {
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAtNanoseconds
            return Double(elapsedNanoseconds) / 1_000_000_000
        }

        private func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            formatter.timeZone = .current
            return formatter.string(from: Date())
        }
    }
}
