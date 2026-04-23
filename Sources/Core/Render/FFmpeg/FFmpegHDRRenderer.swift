import CoreGraphics
import Darwin
import Foundation

// Despite the legacy type name, this renderer now handles both SDR and HDR
// final export paths so the app can share one FFmpeg backend.
final class FFmpegHDRRenderer {
    private final class CallbackRelay: @unchecked Sendable {
        private let diagnostics: (String) -> Void
        private let progress: (Double) -> Void
        private let status: (String) -> Void
        private let diagnosticsLock = NSLock()

        init(
            diagnostics: @escaping (String) -> Void,
            progress: @escaping (Double) -> Void,
            status: @escaping (String) -> Void
        ) {
            self.diagnostics = diagnostics
            self.progress = progress
            self.status = status
        }

        func log(_ message: String) {
            diagnosticsLock.lock()
            diagnostics(message)
            diagnosticsLock.unlock()
        }

        func report(_ value: Double) {
            // Keep progress reporting independent so verbose diagnostics logging
            // cannot stall UI updates.
            progress(value)
        }

        func updateStatus(_ message: String) {
            status(message)
        }
    }

    private struct ActivitySnapshot {
        let lastActivityAt: Date
        let latestOutTimeMicroseconds: Int64
        let latestOutputSizeBytes: UInt64
        let latestSpeed: Double?
        let latestFrameCount: Int64?
        let firstMeaningfulProgressLatencySeconds: TimeInterval?
        let firstOutputGrowthLatencySeconds: TimeInterval?
        let longestInactivityGapSeconds: TimeInterval
    }

    private struct StallContext {
        let stallDurationSeconds: TimeInterval
        let lastOutTimeMicroseconds: Int64
        let lastOutputSizeBytes: UInt64
    }

    private struct ProcessTermination {
        let status: Int32
        let reason: Process.TerminationReason
        let stallContext: StallContext?
    }

    struct FailureSnapshot: Equatable {
        let dynamicRange: DynamicRange
        let terminationSummary: String
        let selectedEncoder: String
        let binarySource: FFmpegBinarySource
        let binaryPath: String
        let renderIntent: FFmpegRenderIntent
        let outputPath: String
        let clipCount: Int
        let chapterCount: Int
        let renderSize: CGSize
        let frameRate: Int
        let elapsedSeconds: TimeInterval
        let latestOutTimeMicroseconds: Int64
        let latestOutputSizeBytes: UInt64
        let latestSpeed: Double?
        let fallbackReason: String?
        let stalledForSeconds: TimeInterval?
        let stalledOutTimeMicroseconds: Int64?
        let stalledOutputSizeBytes: UInt64?
        let stderrTail: [String]
    }

    private struct ExecutionFailure: Error {
        let snapshot: FailureSnapshot

        var renderError: RenderError {
            .exportFailed(FFmpegHDRRenderer.failureMessage(from: snapshot))
        }
    }

    struct CommandExecutionStats: Equatable, Sendable {
        let stageLabel: String
        let renderIntent: FFmpegRenderIntent
        let encoder: String
        let clipAuditBreakdown: [RenderClipAuditBreakdown]
        let expectedDurationSeconds: Double
        let elapsedSeconds: TimeInterval
        let startupLatencySeconds: TimeInterval?
        let firstOutputGrowthLatencySeconds: TimeInterval?
        let finalOutputSizeBytes: UInt64
        let latestOutTimeMicroseconds: Int64
        let latestSpeed: Double?
        let latestFrameCount: Int64?
        let effectiveRealtimeFactor: Double?
        let longestInactivityGapSeconds: TimeInterval
        let terminationSummary: String
        let outputPath: String

        init(
            stageLabel: String,
            renderIntent: FFmpegRenderIntent,
            encoder: String,
            clipAuditBreakdown: [RenderClipAuditBreakdown] = [],
            expectedDurationSeconds: Double,
            elapsedSeconds: TimeInterval,
            startupLatencySeconds: TimeInterval?,
            firstOutputGrowthLatencySeconds: TimeInterval?,
            finalOutputSizeBytes: UInt64,
            latestOutTimeMicroseconds: Int64,
            latestSpeed: Double?,
            latestFrameCount: Int64?,
            effectiveRealtimeFactor: Double?,
            longestInactivityGapSeconds: TimeInterval,
            terminationSummary: String,
            outputPath: String
        ) {
            self.stageLabel = stageLabel
            self.renderIntent = renderIntent
            self.encoder = encoder
            self.clipAuditBreakdown = clipAuditBreakdown
            self.expectedDurationSeconds = expectedDurationSeconds
            self.elapsedSeconds = elapsedSeconds
            self.startupLatencySeconds = startupLatencySeconds
            self.firstOutputGrowthLatencySeconds = firstOutputGrowthLatencySeconds
            self.finalOutputSizeBytes = finalOutputSizeBytes
            self.latestOutTimeMicroseconds = latestOutTimeMicroseconds
            self.latestSpeed = latestSpeed
            self.latestFrameCount = latestFrameCount
            self.effectiveRealtimeFactor = effectiveRealtimeFactor
            self.longestInactivityGapSeconds = longestInactivityGapSeconds
            self.terminationSummary = terminationSummary
            self.outputPath = outputPath
        }
    }

    struct CommandExecutionContext {
        let stageLabel: String
        let dynamicRange: DynamicRange
        let renderIntent: FFmpegRenderIntent
        let outputURL: URL
        let clipCount: Int
        let chapterCount: Int
        let renderSize: CGSize
        let frameRate: Int
        let bitrateMode: BitrateMode
        let videoCodec: VideoCodec
        let audioBitrate: Int?
        let audioLayout: AudioLayout
        let expectedDurationSeconds: Double
        let encoderDescription: String
        let profileSummary: String
        let requiresHDRToSDRToneMapping: Bool
        let hdrToSDRToneMapClips: [FFmpegHDRToSDRToneMapClip]
        let captureDateOverlayCount: Int
        let clipAuditBreakdown: [RenderClipAuditBreakdown]
        let summaryLine: String
        let endpointLine: String?
    }

    private struct IntermediateSoftwareFallbackAttempt {
        let resolution: FFmpegBinaryResolution
        let command: FFmpegCommand
        let context: CommandExecutionContext
    }

    private final class ActivityTracker: @unchecked Sendable {
        private let lock = NSLock()
        private let startedAt: Date
        private let initialOutputSizeBytes: UInt64
        private var lastActivityAt: Date
        private var latestOutTimeMicroseconds: Int64
        private var latestOutputSizeBytes: UInt64
        private var latestSpeed: Double?
        private var latestFrameCount: Int64?
        private var firstMeaningfulProgressAt: Date?
        private var firstOutputGrowthAt: Date?
        private var longestInactivityGapSeconds: TimeInterval

        init(initialOutputSizeBytes: UInt64, startedAt: Date) {
            self.startedAt = startedAt
            self.initialOutputSizeBytes = initialOutputSizeBytes
            self.lastActivityAt = startedAt
            self.latestOutTimeMicroseconds = 0
            self.latestOutputSizeBytes = initialOutputSizeBytes
            self.latestSpeed = nil
            self.latestFrameCount = nil
            self.firstMeaningfulProgressAt = nil
            self.firstOutputGrowthAt = nil
            self.longestInactivityGapSeconds = 0
        }

        func recordOutTime(_ outTimeMicroseconds: Int64) {
            lock.lock()
            if outTimeMicroseconds > latestOutTimeMicroseconds {
                latestOutTimeMicroseconds = outTimeMicroseconds
                let now = Date()
                if outTimeMicroseconds > 0, firstMeaningfulProgressAt == nil {
                    firstMeaningfulProgressAt = now
                }
                noteActivity(at: now)
            }
            lock.unlock()
        }

        func recordOutputSize(_ outputSizeBytes: UInt64) {
            lock.lock()
            if outputSizeBytes > latestOutputSizeBytes {
                latestOutputSizeBytes = outputSizeBytes
                let now = Date()
                if outputSizeBytes > initialOutputSizeBytes, firstOutputGrowthAt == nil {
                    firstOutputGrowthAt = now
                }
                if firstMeaningfulProgressAt == nil {
                    firstMeaningfulProgressAt = now
                }
                noteActivity(at: now)
            }
            lock.unlock()
        }

        func recordSpeed(_ speed: Double?) {
            guard let speed, speed.isFinite, speed > 0 else {
                return
            }
            lock.lock()
            latestSpeed = speed
            noteActivity(at: Date())
            lock.unlock()
        }

        func recordFrameProgress(_ frameCount: Int64?) {
            guard let frameCount, frameCount > 0 else {
                return
            }
            lock.lock()
            if frameCount > (latestFrameCount ?? 0) {
                latestFrameCount = frameCount
                let now = Date()
                if firstMeaningfulProgressAt == nil {
                    firstMeaningfulProgressAt = now
                }
                noteActivity(at: now)
            }
            lock.unlock()
        }

        func recordCPUActivity() {
            lock.lock()
            noteActivity(at: Date())
            lock.unlock()
        }

        func recordHeartbeat() {
            lock.lock()
            noteActivity(at: Date())
            lock.unlock()
        }

        func snapshot() -> ActivitySnapshot {
            lock.lock()
            let snapshot = ActivitySnapshot(
                lastActivityAt: lastActivityAt,
                latestOutTimeMicroseconds: latestOutTimeMicroseconds,
                latestOutputSizeBytes: latestOutputSizeBytes,
                latestSpeed: latestSpeed,
                latestFrameCount: latestFrameCount,
                firstMeaningfulProgressLatencySeconds: firstMeaningfulProgressAt.map { $0.timeIntervalSince(startedAt) },
                firstOutputGrowthLatencySeconds: firstOutputGrowthAt.map { $0.timeIntervalSince(startedAt) },
                longestInactivityGapSeconds: longestInactivityGapSeconds
            )
            lock.unlock()
            return snapshot
        }

        private func noteActivity(at now: Date) {
            let gap = max(now.timeIntervalSince(lastActivityAt), 0)
            if gap > longestInactivityGapSeconds {
                longestInactivityGapSeconds = gap
            }
            lastActivityAt = now
        }
    }

    private final class StderrProcessingState: @unchecked Sendable {
        private let lock = NSLock()
        private var tail: [String] = []
        private var progressParser = FFmpegProgressParser()

        @discardableResult
        func consumeProgressLine(
            _ line: String,
            callbacks: CallbackRelay,
            dynamicRange: DynamicRange,
            activityTracker: ActivityTracker,
            totalDurationMicroseconds: Int64,
            estimatedOutputBytes: UInt64,
            renderStartedAt: Date
        ) -> Bool {
            lock.lock()
            let didConsume = FFmpegHDRRenderer.consumeProgressLine(
                line,
                parser: &progressParser,
                callbacks: callbacks,
                dynamicRange: dynamicRange,
                activityTracker: activityTracker,
                totalDurationMicroseconds: totalDurationMicroseconds,
                estimatedOutputBytes: estimatedOutputBytes,
                renderStartedAt: renderStartedAt
            )
            lock.unlock()
            return didConsume
        }

        func appendTailLine(_ line: String) {
            lock.lock()
            tail.append(line)
            if tail.count > 240 {
                tail.removeFirst(tail.count - 240)
            }
            lock.unlock()
        }

        func snapshotTail() -> [String] {
            lock.lock()
            let lines = tail
            lock.unlock()
            return lines
        }
    }

    private let resolver: FFmpegBinaryResolver
    private let commandBuilder: FFmpegCommandBuilder
    private let fileManager: FileManager
    private let stallTimeoutSeconds: TimeInterval = 120
    private let lateStageStallTimeoutSeconds: TimeInterval = 600
    private let lateStageProgressThreshold: Double = 0.95
    private let outputSizePollIntervalSeconds: TimeInterval = 1
    private let interruptToTerminateDelaySeconds: TimeInterval = 20
    private let terminateToKillDelaySeconds: TimeInterval = 20
    private static let minimumCPUActivityDeltaSeconds: Double = 0.01

    private let processLock = NSLock()
    private var currentProcess: Process?

    init(
        resolver: FFmpegBinaryResolver = FFmpegBinaryResolver(),
        commandBuilder: FFmpegCommandBuilder = FFmpegCommandBuilder(),
        fileManager: FileManager = .default
    ) {
        self.resolver = resolver
        self.commandBuilder = commandBuilder
        self.fileManager = fileManager
    }

    func cancelCurrentRender() {
        processLock.lock()
        let process = currentProcess
        processLock.unlock()

        process?.terminate()
    }

    func render(
        plan: FFmpegRenderPlan,
        binaryMode: HDRFFmpegBinaryMode,
        diagnostics: @escaping (String) -> Void,
        progressHandler: @escaping (Double) -> Void,
        statusHandler: @escaping (String) -> Void = { _ in },
        stageLabel: String? = nil,
        commandStatsHandler: (@Sendable (CommandExecutionStats) -> Void)? = nil,
        systemFFmpegFallbackHandler: SystemFFmpegFallbackHandler? = nil
    ) async throws -> FFmpegBinaryResolution {
        let resolution = try await resolveBinary(
            plan: plan,
            binaryMode: binaryMode,
            diagnostics: diagnostics,
            statusHandler: statusHandler,
            systemFFmpegFallbackHandler: systemFFmpegFallbackHandler
        )
        try await render(
            plan: plan,
            resolution: resolution,
            diagnostics: diagnostics,
            progressHandler: progressHandler,
            statusHandler: statusHandler,
            stageLabel: stageLabel,
            commandStatsHandler: commandStatsHandler
        )
        return resolution
    }

    func resolveBinary(
        plan: FFmpegRenderPlan,
        binaryMode: HDRFFmpegBinaryMode,
        diagnostics: @escaping (String) -> Void,
        statusHandler: @escaping (String) -> Void = { _ in },
        systemFFmpegFallbackHandler: SystemFFmpegFallbackHandler? = nil
    ) async throws -> FFmpegBinaryResolution {
        let resolution = try resolver.resolve(
            mode: binaryMode,
            plan: plan,
            diagnostics: diagnostics
        )
        return try await confirmResolvedBinary(
            resolution,
            binaryMode: binaryMode,
            statusHandler: statusHandler,
            systemFFmpegFallbackHandler: systemFFmpegFallbackHandler
        )
    }

    func resolveBinary(
        requirements: FFmpegCapabilityRequirements,
        binaryMode: HDRFFmpegBinaryMode,
        diagnostics: @escaping (String) -> Void,
        statusHandler: @escaping (String) -> Void = { _ in },
        systemFFmpegFallbackHandler: SystemFFmpegFallbackHandler? = nil
    ) async throws -> FFmpegBinaryResolution {
        let resolution = try resolver.resolve(
            mode: binaryMode,
            requirements: requirements,
            diagnostics: diagnostics
        )
        return try await confirmResolvedBinary(
            resolution,
            binaryMode: binaryMode,
            statusHandler: statusHandler,
            systemFFmpegFallbackHandler: systemFFmpegFallbackHandler
        )
    }

    private func confirmResolvedBinary(
        _ resolution: FFmpegBinaryResolution,
        binaryMode: HDRFFmpegBinaryMode,
        statusHandler: @escaping (String) -> Void,
        systemFFmpegFallbackHandler: SystemFFmpegFallbackHandler?
    ) async throws -> FFmpegBinaryResolution {
        if binaryMode == .bundledPreferred,
           resolution.selectedBinary.source == .system,
           let fallbackReason = resolution.fallbackReason,
           let systemFFmpegFallbackHandler {
            statusHandler("Awaiting system FFmpeg fallback confirmation...")
            let approved = await systemFFmpegFallbackHandler(
                SystemFFmpegFallbackRequest(reason: fallbackReason)
            )
            guard approved else {
                throw RenderError.exportFailed("Render cancelled because system FFmpeg fallback was not approved.")
            }
        }
        return resolution
    }

    func render(
        plan: FFmpegRenderPlan,
        resolution: FFmpegBinaryResolution,
        diagnostics: @escaping (String) -> Void,
        progressHandler: @escaping (Double) -> Void,
        statusHandler: @escaping (String) -> Void = { _ in },
        stageLabel: String? = nil,
        commandStatsHandler: (@Sendable (CommandExecutionStats) -> Void)? = nil
    ) async throws {
        guard let selectedEncoder = resolution.selectedCapabilities.preferredEncoder(
            for: plan.videoCodec,
            dynamicRange: plan.dynamicRange,
            hdrHEVCEncoderMode: plan.hdrHEVCEncoderMode,
            renderIntent: plan.renderIntent
        ) else {
            throw RenderError.exportFailed(
                "FFmpeg \(plan.dynamicRange == .hdr ? "HDR" : "SDR") render failed: no compatible encoder was available after capability resolution."
            )
        }
        let command = try commandBuilder.buildCommand(plan: plan, resolution: resolution)
        let context = makeExecutionContext(for: plan, selectedEncoder: selectedEncoder, stageLabel: stageLabel)
        do {
            try await runCommand(
                command: command,
                resolution: resolution,
                context: context,
                diagnostics: diagnostics,
                progressHandler: progressHandler,
                statusHandler: statusHandler,
                commandStatsHandler: commandStatsHandler
            )
        } catch let failure as ExecutionFailure {
            guard let fallback = makeIntermediateSoftwareFallbackAttempt(
                plan: plan,
                resolution: resolution,
                failedContext: context,
                failure: failure,
                diagnostics: diagnostics,
                statusHandler: statusHandler
            ) else {
                throw failure.renderError
            }

            do {
                try await runCommand(
                    command: fallback.command,
                    resolution: fallback.resolution,
                    context: fallback.context,
                    diagnostics: diagnostics,
                    progressHandler: progressHandler,
                    statusHandler: statusHandler,
                    commandStatsHandler: commandStatsHandler
                )
            } catch let retryFailure as ExecutionFailure {
                throw retryFailure.renderError
            }
        }
    }

    func execute(
        command: FFmpegCommand,
        resolution: FFmpegBinaryResolution,
        context: CommandExecutionContext,
        diagnostics: @escaping (String) -> Void,
        progressHandler: @escaping (Double) -> Void,
        statusHandler: @escaping (String) -> Void = { _ in },
        commandStatsHandler: (@Sendable (CommandExecutionStats) -> Void)? = nil
    ) async throws {
        do {
            try await runCommand(
                command: command,
                resolution: resolution,
                context: context,
                diagnostics: diagnostics,
                progressHandler: progressHandler,
                statusHandler: statusHandler,
                commandStatsHandler: commandStatsHandler
            )
        } catch let failure as ExecutionFailure {
            throw failure.renderError
        }
    }

    private func runCommand(
        command: FFmpegCommand,
        resolution: FFmpegBinaryResolution,
        context: CommandExecutionContext,
        diagnostics: @escaping (String) -> Void,
        progressHandler: @escaping (Double) -> Void,
        statusHandler: @escaping (String) -> Void = { _ in },
        commandStatsHandler: (@Sendable (CommandExecutionStats) -> Void)? = nil
    ) async throws {
        let callbacks = CallbackRelay(
            diagnostics: diagnostics,
            progress: progressHandler,
            status: statusHandler
        )
        if fileManager.fileExists(atPath: context.outputURL.path) {
            try fileManager.removeItem(at: context.outputURL)
        }

        callbacks.log("FFmpeg version: \(resolution.selectedCapabilities.versionDescription)")
        if let systemCaps = resolution.systemCapabilities {
            callbacks.log(
                "FFmpeg system capabilities: zscale=\(systemCaps.hasZscale), tonemap=\(systemCaps.hasTonemap), xfade=\(systemCaps.hasXfade), " +
                "acrossfade=\(systemCaps.hasAcrossfade), libx264=\(systemCaps.hasLibx264), h264_videotoolbox=\(systemCaps.hasH264VideoToolbox), " +
                "overlay=\(systemCaps.hasOverlay), libx265=\(systemCaps.hasLibx265), hevc_videotoolbox=\(systemCaps.hasHEVCVideoToolbox)"
            )
        }
        if let bundledCaps = resolution.bundledCapabilities {
            callbacks.log(
                "FFmpeg bundled capabilities: zscale=\(bundledCaps.hasZscale), tonemap=\(bundledCaps.hasTonemap), xfade=\(bundledCaps.hasXfade), " +
                "acrossfade=\(bundledCaps.hasAcrossfade), libx264=\(bundledCaps.hasLibx264), h264_videotoolbox=\(bundledCaps.hasH264VideoToolbox), " +
                "overlay=\(bundledCaps.hasOverlay), libx265=\(bundledCaps.hasLibx265), hevc_videotoolbox=\(bundledCaps.hasHEVCVideoToolbox)"
            )
        }
        if context.requiresHDRToSDRToneMapping {
            callbacks.log(
                "HDR-to-SDR tone mapping enabled: true (operator=mobius:desat=2, hlg_npl=\(FFmpegCommandBuilder.hlgSDRNominalPeak), clips=\(context.hdrToSDRToneMapClips.count))"
            )
            for clip in context.hdrToSDRToneMapClips {
                callbacks.log("HDR-to-SDR tone-map clip: \(clip.sourceDescription) [transfer=\(clip.transferFlavor.rawValue)]")
            }
        } else {
            callbacks.log("HDR-to-SDR tone mapping enabled: false")
        }
        callbacks.log("FFmpeg render intent: \(context.renderIntent.rawValue)")
        callbacks.log("Capture-date overlays enabled: \(context.captureDateOverlayCount > 0) (clips=\(context.captureDateOverlayCount))")
        callbacks.log(context.summaryLine)
        if let endpointLine = context.endpointLine {
            callbacks.log(endpointLine)
        }
        callbacks.log("FFmpeg selected binary: \(resolution.selectedBinary.ffmpegURL.path) [\(resolution.selectedBinary.source.rawValue)]")
        callbacks.log("FFmpeg encoder profile: \(context.profileSummary)")
        if (context.renderIntent == .intermediateChunk || context.renderIntent == .presentationIntermediate),
           context.encoderDescription != FFmpegVideoEncoder.hevcVideoToolbox.rawValue,
           resolution.selectedCapabilities.hasHEVCVideoToolbox == false {
            callbacks.log("FFmpeg intermediate encoder fallback: hevc_videotoolbox unavailable; using \(context.encoderDescription).")
        }
        callbacks.log("FFmpeg command: \(command.printableCommand)")
        if let fallbackReason = resolution.fallbackReason {
            callbacks.log("FFmpeg fallback reason: \(fallbackReason)")
        }

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        Self.closeUnusedPipeWriteEnds(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        setCurrentProcess(process)
        callbacks.report(0.01)
        callbacks.updateStatus("\(context.dynamicRange == .hdr ? "HDR" : "SDR") encode: starting...")

        defer {
            clearCurrentProcess(process)
        }

        let totalDurationMicroseconds = Int64(context.expectedDurationSeconds * 1_000_000)
        let estimatedOutputBytes = estimatedFinalOutputBytes(for: context)
        let renderStartedAt = Date()
        let activityTracker = ActivityTracker(
            initialOutputSizeBytes: currentOutputSizeBytes(at: context.outputURL) ?? 0,
            startedAt: renderStartedAt
        )

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        async let stdoutTask: Void = Self.consumeStdout(
            handle: stdoutHandle,
            callbacks: callbacks
        )
        async let stderrTask: [String] = Self.consumeStderr(
            handle: stderrHandle,
            callbacks: callbacks,
            dynamicRange: context.dynamicRange,
            activityTracker: activityTracker,
            totalDurationMicroseconds: totalDurationMicroseconds,
            estimatedOutputBytes: estimatedOutputBytes,
            renderStartedAt: renderStartedAt
        )

        let termination: ProcessTermination = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await waitForTermination(
                of: process,
                outputURL: context.outputURL,
                dynamicRange: context.dynamicRange,
                activityTracker: activityTracker,
                callbacks: callbacks,
                totalDurationMicroseconds: totalDurationMicroseconds,
                estimatedOutputBytes: estimatedOutputBytes,
                renderStartedAt: renderStartedAt
            )
        } onCancel: {
            process.terminate()
        }
        callbacks.log("FFmpeg process terminated: \(terminationDescription(status: termination.status, reason: termination.reason))")

        let stderrTail = await stderrTask
        _ = await stdoutTask
        stdoutHandle.closeFile()
        stderrHandle.closeFile()
        let activitySnapshot = activityTracker.snapshot()
        let finalOutputSizeBytes = max(
            currentOutputSizeBytes(at: context.outputURL) ?? 0,
            activitySnapshot.latestOutputSizeBytes
        )
        let terminationSummary = terminationDescription(status: termination.status, reason: termination.reason)
        if let commandStatsHandler {
            commandStatsHandler(
                Self.makeCommandExecutionStats(
                    context: context,
                    activitySnapshot: activitySnapshot,
                    elapsedSeconds: Date().timeIntervalSince(renderStartedAt),
                    finalOutputSizeBytes: finalOutputSizeBytes,
                    terminationSummary: terminationSummary
                )
            )
        }

        guard termination.status == 0 else {
            let failureSnapshot = FailureSnapshot(
                dynamicRange: context.dynamicRange,
                terminationSummary: terminationSummary,
                selectedEncoder: context.encoderDescription,
                binarySource: resolution.selectedBinary.source,
                binaryPath: resolution.selectedBinary.ffmpegURL.path,
                renderIntent: context.renderIntent,
                outputPath: context.outputURL.path,
                clipCount: context.clipCount,
                chapterCount: context.chapterCount,
                renderSize: context.renderSize,
                frameRate: context.frameRate,
                elapsedSeconds: Date().timeIntervalSince(renderStartedAt),
                latestOutTimeMicroseconds: activitySnapshot.latestOutTimeMicroseconds,
                latestOutputSizeBytes: finalOutputSizeBytes,
                latestSpeed: activitySnapshot.latestSpeed,
                fallbackReason: resolution.fallbackReason,
                stalledForSeconds: termination.stallContext?.stallDurationSeconds,
                stalledOutTimeMicroseconds: termination.stallContext?.lastOutTimeMicroseconds,
                stalledOutputSizeBytes: termination.stallContext?.lastOutputSizeBytes,
                stderrTail: stderrTail
            )
            for line in Self.failureDiagnosticLines(from: failureSnapshot) {
                callbacks.log(line)
            }
            throw ExecutionFailure(snapshot: failureSnapshot)
        }

        callbacks.report(1.0)
        let finalSnapshot = activityTracker.snapshot()
        callbacks.updateStatus(
            Self.statusLine(
                dynamicRange: context.dynamicRange,
                progress: 1.0,
                elapsed: Date().timeIntervalSince(renderStartedAt),
                outputSizeBytes: finalSnapshot.latestOutputSizeBytes,
                speed: nil
            )
        )
    }

    private func makeIntermediateSoftwareFallbackAttempt(
        plan: FFmpegRenderPlan,
        resolution: FFmpegBinaryResolution,
        failedContext: CommandExecutionContext,
        failure: ExecutionFailure,
        diagnostics: @escaping (String) -> Void,
        statusHandler: @escaping (String) -> Void
    ) -> IntermediateSoftwareFallbackAttempt? {
        guard Self.shouldRetryWithSoftwareIntermediateFallback(
            snapshot: failure.snapshot,
            selectedCapabilities: resolution.selectedCapabilities
        ) else {
            return nil
        }

        let retryResolution = softwareIntermediateFallbackResolution(from: resolution)
        guard let retryEncoder = retryResolution.selectedCapabilities.preferredEncoder(
            for: plan.videoCodec,
            dynamicRange: plan.dynamicRange,
            hdrHEVCEncoderMode: plan.hdrHEVCEncoderMode,
            renderIntent: plan.renderIntent
        ), retryEncoder == .libx265 else {
            return nil
        }
        guard let retryCommand = try? commandBuilder.buildCommand(plan: plan, resolution: retryResolution) else {
            return nil
        }

        diagnostics("FFmpeg intermediate encoder retry: hevc_videotoolbox failed before producing output; retrying with libx265.")
        let retrySignals = Self.videoToolboxRetryIndicators(from: failure.snapshot.stderrTail)
        if !retrySignals.isEmpty {
            diagnostics("FFmpeg intermediate encoder retry cause: \(retrySignals.joined(separator: " | "))")
        }
        statusHandler("\(failedContext.dynamicRange == .hdr ? "HDR" : "SDR") encode: retrying with software HEVC encoder...")

        return IntermediateSoftwareFallbackAttempt(
            resolution: retryResolution,
            command: retryCommand,
            context: makeExecutionContext(for: plan, selectedEncoder: retryEncoder, stageLabel: failedContext.stageLabel)
        )
    }

    private func softwareIntermediateFallbackResolution(from resolution: FFmpegBinaryResolution) -> FFmpegBinaryResolution {
        let selected = resolution.selectedCapabilities
        let fallbackCapabilities = FFmpegCapabilities(
            versionDescription: selected.versionDescription,
            hasZscale: selected.hasZscale,
            hasTonemap: selected.hasTonemap,
            hasXfade: selected.hasXfade,
            hasAcrossfade: selected.hasAcrossfade,
            hasOverlay: selected.hasOverlay,
            hasLibx264: selected.hasLibx264,
            hasH264VideoToolbox: selected.hasH264VideoToolbox,
            hasLibx265: selected.hasLibx265,
            hasHEVCVideoToolbox: false
        )
        return FFmpegBinaryResolution(
            selectedBinary: resolution.selectedBinary,
            selectedCapabilities: fallbackCapabilities,
            systemCapabilities: resolution.systemCapabilities,
            bundledCapabilities: resolution.bundledCapabilities,
            fallbackReason: resolution.fallbackReason
        )
    }

    static func shouldRetryWithSoftwareIntermediateFallback(
        snapshot: FailureSnapshot,
        selectedCapabilities: FFmpegCapabilities
    ) -> Bool {
        guard snapshot.renderIntent == .intermediateChunk || snapshot.renderIntent == .presentationIntermediate else {
            return false
        }
        guard snapshot.selectedEncoder == FFmpegVideoEncoder.hevcVideoToolbox.rawValue else {
            return false
        }
        guard selectedCapabilities.hasLibx265 else {
            return false
        }
        guard snapshot.latestOutTimeMicroseconds <= 0, snapshot.latestOutputSizeBytes == 0 else {
            return false
        }
        return !videoToolboxRetryIndicators(from: snapshot.stderrTail).isEmpty
    }

    private static func videoToolboxRetryIndicators(from stderrTail: [String]) -> [String] {
        let indicators = [
            "cannot create compression session",
            "error while opening encoder",
            "could not open encoder before eof",
            "try -allow_sw 1",
            "kvtcouldnotfindvideoencodererr"
        ]
        return stderrTail.filter { line in
            let lowered = line.lowercased()
            return indicators.contains { lowered.contains($0) }
        }
    }

    private func makeExecutionContext(
        for plan: FFmpegRenderPlan,
        selectedEncoder: FFmpegVideoEncoder,
        stageLabel: String? = nil
    ) -> CommandExecutionContext {
        let overlayCount = plan.clips.filter { $0.captureDateOverlayURL != nil }.count
        let expectedDurationSeconds = commandBuilder.expectedDurationSeconds(for: plan)
        let endpointLine: String?
        if let firstClip = plan.clips.first, let lastClip = plan.clips.last {
            endpointLine =
                "FFmpeg clip endpoints: first=\(firstClip.sourceDescription) [\(String(format: "%.2fs", firstClip.durationSeconds))], " +
                "last=\(lastClip.sourceDescription) [\(String(format: "%.2fs", lastClip.durationSeconds))]"
        } else {
            endpointLine = nil
        }

        return CommandExecutionContext(
            stageLabel: stageLabel ?? Self.defaultStageLabel(for: plan.renderIntent),
            dynamicRange: plan.dynamicRange,
            renderIntent: plan.renderIntent,
            outputURL: plan.outputURL,
            clipCount: plan.clips.count,
            chapterCount: plan.chapters.count,
            renderSize: plan.renderSize,
            frameRate: plan.frameRate,
            bitrateMode: plan.bitrateMode,
            videoCodec: plan.videoCodec,
            audioBitrate: estimatedAudioBitrate(for: plan),
            audioLayout: plan.audioLayout,
            expectedDurationSeconds: expectedDurationSeconds,
            encoderDescription: selectedEncoder.rawValue,
            profileSummary: commandBuilder.profileSummary(for: plan, encoder: selectedEncoder),
            requiresHDRToSDRToneMapping: plan.requiresHDRToSDRToneMapping,
            hdrToSDRToneMapClips: plan.hdrToSDRToneMapClips,
            captureDateOverlayCount: overlayCount,
            clipAuditBreakdown: Self.clipAuditBreakdown(for: plan.clips),
            summaryLine:
                "FFmpeg plan summary: output=\(plan.outputURL.path), clips=\(plan.clips.count), chapters=\(plan.chapters.count), " +
                "renderSize=\(Int(plan.renderSize.width.rounded()))x\(Int(plan.renderSize.height.rounded())), frameRate=\(plan.frameRate), " +
                "container=\(plan.container.rawValue), codec=\(plan.videoCodec.rawValue), dynamicRange=\(plan.dynamicRange.rawValue), " +
                "audioLayout=\(plan.audioLayout.rawValue), expectedDuration=\(String(format: "%.2fs", expectedDurationSeconds))",
            endpointLine: endpointLine
        )
    }

    private static func consumeStdout(
        handle: FileHandle,
        callbacks: CallbackRelay
    ) async {
        await consumePipeText(handle: handle) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                callbacks.log("FFmpeg stdout: \(trimmed)")
            }
        }
    }

    private static func consumeStderr(
        handle: FileHandle,
        callbacks: CallbackRelay,
        dynamicRange: DynamicRange,
        activityTracker: ActivityTracker,
        totalDurationMicroseconds: Int64,
        estimatedOutputBytes: UInt64,
        renderStartedAt: Date
    ) async -> [String] {
        let state = StderrProcessingState()
        await consumePipeText(handle: handle) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return
            }
            if state.consumeProgressLine(
                trimmed,
                callbacks: callbacks,
                dynamicRange: dynamicRange,
                activityTracker: activityTracker,
                totalDurationMicroseconds: totalDurationMicroseconds,
                estimatedOutputBytes: estimatedOutputBytes,
                renderStartedAt: renderStartedAt
            ) {
                return
            }
            callbacks.log("FFmpeg stderr: \(trimmed)")
            state.appendTailLine(trimmed)
        }
        return state.snapshotTail()
    }

    // Parent never writes to these pipes. Closing the parent-side write ends
    // lets the read side observe EOF when FFmpeg exits without racing a read-handle close.
    static func closeUnusedPipeWriteEnds(stdoutPipe: Pipe, stderrPipe: Pipe) {
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
    }

    private static func consumePipeText(
        handle: FileHandle,
        onLine: @Sendable @escaping (String) -> Void
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var lineBytes: [UInt8] = []
                lineBytes.reserveCapacity(512)

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        break
                    }

                    for byte in chunk {
                        if byte == 0x0A || byte == 0x0D {
                            if !lineBytes.isEmpty {
                                onLine(String(decoding: lineBytes, as: UTF8.self))
                                lineBytes.removeAll(keepingCapacity: true)
                            }
                            continue
                        }
                        lineBytes.append(byte)
                    }
                }

                if !lineBytes.isEmpty {
                    onLine(String(decoding: lineBytes, as: UTF8.self))
                }
                continuation.resume()
            }
        }
    }

    private static let ffmpegProgressKeys: Set<String> = [
        "frame",
        "fps",
        "stream_0_0_q",
        "bitrate",
        "total_size",
        "out_time_us",
        "out_time_ms",
        "out_time",
        "dup_frames",
        "drop_frames",
        "speed",
        "progress"
    ]

    @discardableResult
    private static func consumeProgressLine(
        _ line: String,
        parser: inout FFmpegProgressParser,
        callbacks: CallbackRelay,
        dynamicRange: DynamicRange,
        activityTracker: ActivityTracker,
        totalDurationMicroseconds: Int64,
        estimatedOutputBytes: UInt64,
        renderStartedAt: Date
    ) -> Bool {
        guard let equalsIndex = line.firstIndex(of: "=") else {
            return false
        }

        let key = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard ffmpegProgressKeys.contains(key) else {
            return false
        }

        let previousFrameCount = parser.latestFrameCount
        let previousOutTime = parser.latestOutTimeMS
        let previousTotalSizeBytes = parser.latestTotalSizeBytes
        let update = parser.ingest(line: line)

        if Self.didFrameProgressAdvance(
            previousFrameCount: previousFrameCount,
            currentFrameCount: parser.latestFrameCount
        ) {
            activityTracker.recordFrameProgress(parser.latestFrameCount)
        }
        if parser.latestOutTimeMS > previousOutTime {
            activityTracker.recordOutTime(parser.latestOutTimeMS)
        }
        if let totalSizeBytes = parser.latestTotalSizeBytes,
           totalSizeBytes > (previousTotalSizeBytes ?? 0) {
            activityTracker.recordOutputSize(UInt64(totalSizeBytes))
        }
        activityTracker.recordSpeed(parser.latestSpeed)

        let snapshot = activityTracker.snapshot()
        let timelineProgress = parser.progress(totalDurationMicroseconds: totalDurationMicroseconds)
        let sizeProgress = sizeProgress(
            outputSizeBytes: snapshot.latestOutputSizeBytes,
            estimatedOutputBytes: estimatedOutputBytes
        )
        let combinedProgress = max(
            timelineProgress,
            sizeProgress,
            warmupProgress(elapsed: Date().timeIntervalSince(renderStartedAt))
        )
        callbacks.report(combinedProgress)

        if let update {
            if update.isTerminal {
                activityTracker.recordHeartbeat()
            }
            let outputSizeBytes = UInt64(update.totalSizeBytes ?? 0)
            let preferredOutputSize = max(outputSizeBytes, snapshot.latestOutputSizeBytes)
            callbacks.updateStatus(
                statusLine(
                    dynamicRange: dynamicRange,
                    progress: combinedProgress,
                    elapsed: Date().timeIntervalSince(renderStartedAt),
                    outputSizeBytes: preferredOutputSize,
                    speed: update.speed
                )
            )
        }
        return true
    }

    private func waitForTermination(
        of process: Process,
        outputURL: URL,
        dynamicRange: DynamicRange,
        activityTracker: ActivityTracker,
        callbacks: CallbackRelay,
        totalDurationMicroseconds: Int64,
        estimatedOutputBytes: UInt64,
        renderStartedAt: Date
    ) async throws -> ProcessTermination {
        enum StallSignalStage {
            case none
            case interrupted(at: Date)
            case terminated(at: Date)
            case killed
        }

        // Polling avoids a race where the process can exit between an isRunning check and
        // assigning terminationHandler, which can otherwise leave the render task waiting forever.
        var lastOutputSizePollAt = Date.distantPast
        var stallContext: StallContext?
        var stallSignalStage: StallSignalStage = .none
        var lastCPUTimeSeconds = processCPUTimeSeconds(for: process.processIdentifier)

        while process.isRunning {
            try Task.checkCancellation()
            let now = Date()

            if now.timeIntervalSince(lastOutputSizePollAt) >= outputSizePollIntervalSeconds {
                if let outputSizeBytes = currentOutputSizeBytes(at: outputURL) {
                    activityTracker.recordOutputSize(outputSizeBytes)
                }
                if let cpuTimeSeconds = processCPUTimeSeconds(for: process.processIdentifier) {
                    if Self.didCPUTimeAdvance(
                        previousCPUTimeSeconds: lastCPUTimeSeconds,
                        currentCPUTimeSeconds: cpuTimeSeconds
                    ) {
                        activityTracker.recordCPUActivity()
                    }
                    lastCPUTimeSeconds = cpuTimeSeconds
                }
                let snapshot = activityTracker.snapshot()
                let timelineProgress = Self.timelineProgress(
                    outTimeMicroseconds: snapshot.latestOutTimeMicroseconds,
                    totalDurationMicroseconds: totalDurationMicroseconds
                )
                let sizeProgress = Self.sizeProgress(
                    outputSizeBytes: snapshot.latestOutputSizeBytes,
                    estimatedOutputBytes: estimatedOutputBytes
                )
                let fallbackWarmupProgress = Self.warmupProgress(elapsed: now.timeIntervalSince(renderStartedAt))
                let combinedProgress = max(timelineProgress, sizeProgress, fallbackWarmupProgress)
                callbacks.report(combinedProgress)
                callbacks.updateStatus(
                    Self.statusLine(
                        dynamicRange: dynamicRange,
                        progress: combinedProgress,
                        elapsed: now.timeIntervalSince(renderStartedAt),
                        outputSizeBytes: snapshot.latestOutputSizeBytes,
                        speed: snapshot.latestSpeed
                    )
                )
                lastOutputSizePollAt = now
            }

            let snapshot = activityTracker.snapshot()
            let stalledFor = now.timeIntervalSince(snapshot.lastActivityAt)
            let timeoutTimelineProgress = Self.timelineProgress(
                outTimeMicroseconds: snapshot.latestOutTimeMicroseconds,
                totalDurationMicroseconds: totalDurationMicroseconds
            )
            let timeoutSizeProgress = Self.sizeProgress(
                outputSizeBytes: snapshot.latestOutputSizeBytes,
                estimatedOutputBytes: estimatedOutputBytes
            )
            let timeoutWarmupProgress = Self.warmupProgress(elapsed: now.timeIntervalSince(renderStartedAt))
            let timeoutCombinedProgress = max(timeoutTimelineProgress, timeoutSizeProgress, timeoutWarmupProgress)
            let activeStallTimeout = timeoutCombinedProgress >= lateStageProgressThreshold
                ? lateStageStallTimeoutSeconds
                : stallTimeoutSeconds

            if stalledFor >= activeStallTimeout {
                if stallContext == nil {
                    let context = StallContext(
                        stallDurationSeconds: stalledFor,
                        lastOutTimeMicroseconds: snapshot.latestOutTimeMicroseconds,
                        lastOutputSizeBytes: snapshot.latestOutputSizeBytes
                    )
                    stallContext = context
                    callbacks.log(
                        "FFmpeg stall watchdog triggered after \(Int(stalledFor.rounded()))s without progress " +
                        "(last_out_time_us=\(context.lastOutTimeMicroseconds), output=\(context.lastOutputSizeBytes), " +
                        "threshold=\(Int(activeStallTimeout.rounded()))s, progress=\(Int((timeoutCombinedProgress * 100).rounded()))%)."
                    )
                    callbacks.log("FFmpeg stall watchdog requested graceful shutdown via SIGINT.")
                    process.interrupt()
                    stallSignalStage = .interrupted(at: now)
                } else {
                    switch stallSignalStage {
                    case .none:
                        break
                    case let .interrupted(interruptedAt)
                        where now.timeIntervalSince(interruptedAt) >= interruptToTerminateDelaySeconds:
                        callbacks.log("FFmpeg still running after SIGINT; escalating to SIGTERM.")
                        process.terminate()
                        stallSignalStage = .terminated(at: now)
                    case let .terminated(terminatedAt)
                        where now.timeIntervalSince(terminatedAt) >= terminateToKillDelaySeconds:
                        callbacks.log("FFmpeg still running after SIGTERM; escalating to SIGKILL.")
                        _ = kill(process.processIdentifier, SIGKILL)
                        stallSignalStage = .killed
                    case .killed:
                        break
                    default:
                        break
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return ProcessTermination(
            status: process.terminationStatus,
            reason: process.terminationReason,
            stallContext: stallContext
        )
    }

    static func didFrameProgressAdvance(
        previousFrameCount: Int64?,
        currentFrameCount: Int64?
    ) -> Bool {
        guard let currentFrameCount else {
            return false
        }
        guard let previousFrameCount else {
            return currentFrameCount > 0
        }
        return currentFrameCount > previousFrameCount
    }

    static func didCPUTimeAdvance(
        previousCPUTimeSeconds: Double?,
        currentCPUTimeSeconds: Double?
    ) -> Bool {
        guard let previousCPUTimeSeconds,
              let currentCPUTimeSeconds,
              currentCPUTimeSeconds.isFinite else {
            return false
        }
        return currentCPUTimeSeconds > previousCPUTimeSeconds + minimumCPUActivityDeltaSeconds
    }

    static func failureMessage(from snapshot: FailureSnapshot) -> String {
        var lines: [String] = []
        let rangeLabel = snapshot.dynamicRange == .hdr ? "HDR" : "SDR"
        if let stalledForSeconds = snapshot.stalledForSeconds,
           let stalledOutTimeMicroseconds = snapshot.stalledOutTimeMicroseconds,
           let stalledOutputSizeBytes = snapshot.stalledOutputSizeBytes {
            lines.append("FFmpeg \(rangeLabel) render stalled for \(Int(stalledForSeconds.rounded()))s and terminated with \(snapshot.terminationSummary).")
            lines.append(
                "Stall point: last_out_time \(formatFFmpegOutTime(stalledOutTimeMicroseconds)) | output \(formatByteCount(stalledOutputSizeBytes))"
            )
        } else {
            lines.append("FFmpeg \(rangeLabel) render failed (\(snapshot.terminationSummary)).")
        }

        lines.append("Encoder: \(snapshot.selectedEncoder)")
        lines.append("Binary: \(snapshot.binarySource.rawValue) (\(snapshot.binaryPath))")
        lines.append(
            "Plan: intent=\(snapshot.renderIntent.rawValue) | clips=\(snapshot.clipCount) | chapters=\(snapshot.chapterCount) | " +
            "size=\(Int(snapshot.renderSize.width.rounded()))x\(Int(snapshot.renderSize.height.rounded())) | fps=\(snapshot.frameRate)"
        )
        lines.append(
            "Progress: elapsed \(formatElapsed(snapshot.elapsedSeconds)) | last_out_time \(formatFFmpegOutTime(snapshot.latestOutTimeMicroseconds)) | " +
            "output \(formatByteCount(snapshot.latestOutputSizeBytes)) | speed \(formatSpeed(snapshot.latestSpeed))"
        )
        lines.append("Output: \(snapshot.outputPath)")
        if let fallbackReason = snapshot.fallbackReason, !fallbackReason.isEmpty {
            lines.append("Fallback reason: \(fallbackReason)")
        }

        let stderrLines = filteredFailureStderrLines(from: snapshot.stderrTail)
        if !stderrLines.isEmpty {
            lines.append("Recent stderr:")
            lines.append(contentsOf: stderrLines.map { "- \($0)" })
        } else {
            lines.append("Recent stderr: none captured")
        }

        return lines.joined(separator: "\n")
    }

    static func failureDiagnosticLines(from snapshot: FailureSnapshot) -> [String] {
        var lines: [String] = [
            "FFmpeg failure summary: encoder=\(snapshot.selectedEncoder), binary=\(snapshot.binarySource.rawValue), termination=\(snapshot.terminationSummary)",
            "FFmpeg failure plan: intent=\(snapshot.renderIntent.rawValue), clips=\(snapshot.clipCount), chapters=\(snapshot.chapterCount), " +
                "renderSize=\(Int(snapshot.renderSize.width.rounded()))x\(Int(snapshot.renderSize.height.rounded())), fps=\(snapshot.frameRate), output=\(snapshot.outputPath)",
            "FFmpeg failure progress: elapsed=\(formatElapsed(snapshot.elapsedSeconds)), last_out_time=\(formatFFmpegOutTime(snapshot.latestOutTimeMicroseconds)), " +
                "output=\(formatByteCount(snapshot.latestOutputSizeBytes)), speed=\(formatSpeed(snapshot.latestSpeed))"
        ]
        if let fallbackReason = snapshot.fallbackReason, !fallbackReason.isEmpty {
            lines.append("FFmpeg failure fallback reason: \(fallbackReason)")
        }
        if let stalledForSeconds = snapshot.stalledForSeconds,
           let stalledOutTimeMicroseconds = snapshot.stalledOutTimeMicroseconds,
           let stalledOutputSizeBytes = snapshot.stalledOutputSizeBytes {
            lines.append(
                "FFmpeg failure stall context: stalled_for=\(Int(stalledForSeconds.rounded()))s, " +
                "last_out_time=\(formatFFmpegOutTime(stalledOutTimeMicroseconds)), output=\(formatByteCount(stalledOutputSizeBytes))"
            )
        }

        let stderrLines = filteredFailureStderrLines(from: snapshot.stderrTail)
        if stderrLines.isEmpty {
            lines.append("FFmpeg failure stderr: none captured")
        } else {
            lines.append(contentsOf: stderrLines.map { "FFmpeg failure stderr: \($0)" })
        }
        return lines
    }

    static func commandSummaryLines(from commandStats: [CommandExecutionStats]) -> [String] {
        guard !commandStats.isEmpty else {
            return ["none recorded"]
        }

        var lines: [String] = ["By intent:"]
        for rollup in commandRollups(from: commandStats) {
            var line =
                "- \(rollup.renderIntent.rawValue): count=\(rollup.count), elapsed=\(formatSummarySeconds(rollup.totalElapsedSeconds)), " +
                "encoded=\(formatSummarySeconds(rollup.totalEncodedSeconds)), realtime=\(formatRatio(rollup.effectiveRealtimeFactor)), " +
                "output=\(formatByteCount(rollup.totalOutputSizeBytes))"
            if let averageSpeed = rollup.averageReportedSpeed {
                line += ", avg_speed=\(formatRatio(averageSpeed))"
            }
            lines.append(line)
        }

        lines.append("Commands:")
        lines.append(contentsOf: commandStats.map { commandSummaryLine(from: $0) })
        return lines
    }

    static func filteredFailureStderrLines(from stderrTail: [String]) -> [String] {
        let highlighted = stderrTail.filter { isNoteworthyStderrLine($0) }
        if !highlighted.isEmpty {
            return Array(highlighted.suffix(8))
        }

        let filteredTail = stderrTail.filter { !isRoutineStderrLine($0) }
        if !filteredTail.isEmpty {
            return Array(filteredTail.suffix(8))
        }

        return Array(stderrTail.suffix(8))
    }

    private static func isNoteworthyStderrLine(_ line: String) -> Bool {
        if isRoutineStderrLine(line) {
            return false
        }

        let lowered = line.lowercased()
        let keywords = [
            "error",
            "failed",
            "fatal",
            "invalid",
            "unable",
            "unsupported",
            "no such",
            "cannot",
            "could not",
            "out of memory",
            "not enough",
            "mismatch",
            "overflow",
            "killed",
            "aborted",
            "terminated"
        ]
        return keywords.contains { lowered.contains($0) }
    }

    private static func isRoutineStderrLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let trimmed = lowered.trimmingCharacters(in: .whitespaces)
        if lowered == "stream mapping:" || lowered.hasPrefix("stream mapping:") {
            return true
        }
        if lowered.hasPrefix("press [q] to stop") {
            return true
        }
        if lowered.hasPrefix("stream #"), line.contains("->") {
            return true
        }
        if lowered.contains("the \"sample_fmts\" option is deprecated") {
            return true
        }
        if lowered.contains("the \"all_channel_counts\" option is deprecated") {
            return true
        }
        if trimmed.hasPrefix("chapter #") {
            return true
        }
        if trimmed == "metadata:" {
            return true
        }
        if trimmed.hasPrefix("title           :") {
            return true
        }
        return false
    }

    private func currentOutputSizeBytes(at url: URL) -> UInt64? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if let size = attributes[.size] as? NSNumber {
            return size.uint64Value
        }
        if let size = attributes[.size] as? Int {
            return UInt64(max(size, 0))
        }
        return nil
    }

    private func processCPUTimeSeconds(for pid: Int32) -> Double? {
        Self.processCPUTimeSeconds(for: pid)
    }

    static func processCPUTimeSeconds(for pid: Int32) -> Double? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { usagePointer in
            // `proc_pid_rusage` is imported as taking a pointer to `rusage_info_t`
            // (`void *` in C), so pass the struct buffer itself via a temporary rebound.
            usagePointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(pid, Int32(RUSAGE_INFO_CURRENT), reboundPointer)
            }
        }
        guard result == 0 else {
            return nil
        }
        let totalNanoseconds = usage.ri_user_time + usage.ri_system_time
        return Double(totalNanoseconds) / 1_000_000_000
    }

    static func statusLine(
        dynamicRange: DynamicRange,
        progress: Double,
        elapsed: TimeInterval,
        outputSizeBytes: UInt64,
        speed: Double?
    ) -> String {
        let clampedProgress = min(max(progress, 0), 1)
        let percent = Int((clampedProgress * 100).rounded())
        let rangeLabel = dynamicRange == .hdr ? "HDR" : "SDR"
        return "\(rangeLabel) encode: \(percent)% | elapsed \(formatElapsed(elapsed)) | output \(formatByteCount(outputSizeBytes)) | speed \(formatSpeed(speed))"
    }

    static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let clampedSeconds = max(Int(elapsed.rounded()), 0)
        let minutes = clampedSeconds / 60
        let seconds = clampedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func formatFFmpegOutTime(_ outTimeMicroseconds: Int64) -> String {
        guard outTimeMicroseconds > 0 else {
            return "--"
        }

        let totalMilliseconds = max(outTimeMicroseconds / 1_000, 0)
        let totalSeconds = totalMilliseconds / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, milliseconds)
    }

    static func formatByteCount(_ bytes: UInt64) -> String {
        let clampedBytes = min(bytes, UInt64(Int64.max))
        return ByteCountFormatter.string(fromByteCount: Int64(clampedBytes), countStyle: .file)
    }

    static func formatSpeed(_ speed: Double?) -> String {
        guard let speed, speed.isFinite, speed > 0 else {
            return "--"
        }
        return String(format: "%.2fx", speed)
    }

    private static func timelineProgress(outTimeMicroseconds: Int64, totalDurationMicroseconds: Int64) -> Double {
        guard totalDurationMicroseconds > 0 else {
            return 0
        }
        return min(max(Double(outTimeMicroseconds) / Double(totalDurationMicroseconds), 0), 1)
    }

    private static func sizeProgress(outputSizeBytes: UInt64, estimatedOutputBytes: UInt64) -> Double {
        guard estimatedOutputBytes > 0 else {
            return 0
        }
        let ratio = Double(outputSizeBytes) / Double(estimatedOutputBytes)
        return min(max(ratio, 0), 0.97)
    }

    private static func warmupProgress(elapsed: TimeInterval) -> Double {
        guard elapsed.isFinite, elapsed > 0 else {
            return 0
        }
        // Keep UI moving slightly during heavy startup/filter graph warmup before
        // ffmpeg emits stable out_time updates.
        return min(elapsed / 240.0 * 0.05, 0.05)
    }

    private func estimatedFinalOutputBytes(for context: CommandExecutionContext) -> UInt64 {
        let durationSeconds = max(context.expectedDurationSeconds, 0.01)
        let pixelsPerFrame = max(context.renderSize.width * context.renderSize.height, 1)
        let bitsPerPixel = estimatedBitsPerPixel(
            for: context.bitrateMode,
            codec: context.videoCodec,
            dynamicRange: context.dynamicRange
        )
        let videoBits = pixelsPerFrame * Double(max(context.frameRate, 24)) * durationSeconds * bitsPerPixel
        let audioBits = Double(context.audioBitrate ?? 192_000) * durationSeconds
        let totalBytes = max((videoBits + audioBits) / 8.0, 1)
        return UInt64(totalBytes.rounded())
    }

    private func estimatedAudioBitrate(for plan: FFmpegRenderPlan) -> Int {
        let outputChannelCount = max(plan.audioLayout.outputChannelCount ?? 2, 1)
        switch plan.renderIntent {
        case .finalDelivery:
            return plan.audioLayout.aacBitrate ?? 192_000
        case .intermediateChunk, .presentationIntermediate, .finalBatch:
            return 48_000 * outputChannelCount * 16
        case .concatCopy:
            return 48_000 * outputChannelCount * 16
        case .finalPackaging:
            return plan.audioLayout.aacBitrate ?? 192_000
        }
    }

    private func estimatedBitsPerPixel(for mode: BitrateMode, codec: VideoCodec, dynamicRange: DynamicRange) -> Double {
        switch (dynamicRange, codec, mode) {
        case (.hdr, _, .qualityFirst):
            return 0.08
        case (.hdr, _, .balanced):
            return 0.06
        case (.hdr, _, .sizeFirst):
            return 0.04
        case (.sdr, .hevc, .qualityFirst):
            return 0.07
        case (.sdr, .hevc, .balanced):
            return 0.05
        case (.sdr, .hevc, .sizeFirst):
            return 0.035
        case (.sdr, .h264, .qualityFirst):
            return 0.10
        case (.sdr, .h264, .balanced):
            return 0.07
        case (.sdr, .h264, .sizeFirst):
            return 0.05
        }
    }

    private static func defaultStageLabel(for renderIntent: FFmpegRenderIntent) -> String {
        switch renderIntent {
        case .finalDelivery:
            return "Final delivery"
        case .intermediateChunk:
            return "Intermediate chunk"
        case .presentationIntermediate:
            return "Presentation intermediate"
        case .finalBatch:
            return "Final batch"
        case .concatCopy:
            return "Concat copy"
        case .finalPackaging:
            return "Final packaging"
        }
    }

    private static func makeCommandExecutionStats(
        context: CommandExecutionContext,
        activitySnapshot: ActivitySnapshot,
        elapsedSeconds: TimeInterval,
        finalOutputSizeBytes: UInt64,
        terminationSummary: String
    ) -> CommandExecutionStats {
        let encodedSeconds: Double
        if activitySnapshot.latestOutTimeMicroseconds > 0 {
            encodedSeconds = Double(activitySnapshot.latestOutTimeMicroseconds) / 1_000_000
        } else {
            encodedSeconds = max(context.expectedDurationSeconds, 0)
        }

        let effectiveRealtimeFactor: Double?
        if elapsedSeconds > 0, encodedSeconds > 0 {
            effectiveRealtimeFactor = encodedSeconds / elapsedSeconds
        } else {
            effectiveRealtimeFactor = nil
        }

        return CommandExecutionStats(
            stageLabel: context.stageLabel,
            renderIntent: context.renderIntent,
            encoder: context.encoderDescription,
            clipAuditBreakdown: context.clipAuditBreakdown,
            expectedDurationSeconds: context.expectedDurationSeconds,
            elapsedSeconds: elapsedSeconds,
            startupLatencySeconds: activitySnapshot.firstMeaningfulProgressLatencySeconds,
            firstOutputGrowthLatencySeconds: activitySnapshot.firstOutputGrowthLatencySeconds,
            finalOutputSizeBytes: finalOutputSizeBytes,
            latestOutTimeMicroseconds: activitySnapshot.latestOutTimeMicroseconds,
            latestSpeed: activitySnapshot.latestSpeed,
            latestFrameCount: activitySnapshot.latestFrameCount,
            effectiveRealtimeFactor: effectiveRealtimeFactor,
            longestInactivityGapSeconds: activitySnapshot.longestInactivityGapSeconds,
            terminationSummary: terminationSummary,
            outputPath: context.outputURL.path
        )
    }

    private struct CommandStatsRollup {
        let renderIntent: FFmpegRenderIntent
        let count: Int
        let totalElapsedSeconds: TimeInterval
        let totalEncodedSeconds: Double
        let totalOutputSizeBytes: UInt64
        let averageReportedSpeed: Double?
        let effectiveRealtimeFactor: Double?
    }

    private static func commandRollups(from commandStats: [CommandExecutionStats]) -> [CommandStatsRollup] {
        let grouped = Dictionary(grouping: commandStats, by: \.renderIntent)
        let order: [FFmpegRenderIntent] = [.presentationIntermediate, .intermediateChunk, .finalBatch, .concatCopy, .finalPackaging, .finalDelivery]
        return order.compactMap { renderIntent in
            guard let stats = grouped[renderIntent], !stats.isEmpty else {
                return nil
            }
            let totalElapsed = stats.reduce(0) { $0 + $1.elapsedSeconds }
            let totalEncoded = stats.reduce(0) { partial, stat in
                partial + (stat.latestOutTimeMicroseconds > 0 ? Double(stat.latestOutTimeMicroseconds) / 1_000_000 : stat.expectedDurationSeconds)
            }
            let totalOutput = stats.reduce(UInt64(0)) { $0 + $1.finalOutputSizeBytes }
            let reportedSpeeds = stats.compactMap(\.latestSpeed)
            let averageSpeed = reportedSpeeds.isEmpty ? nil : reportedSpeeds.reduce(0, +) / Double(reportedSpeeds.count)
            let realtimeFactor = totalElapsed > 0 && totalEncoded > 0 ? totalEncoded / totalElapsed : nil
            return CommandStatsRollup(
                renderIntent: renderIntent,
                count: stats.count,
                totalElapsedSeconds: totalElapsed,
                totalEncodedSeconds: totalEncoded,
                totalOutputSizeBytes: totalOutput,
                averageReportedSpeed: averageSpeed,
                effectiveRealtimeFactor: realtimeFactor
            )
        }
    }

    private static func commandSummaryLine(from stats: CommandExecutionStats) -> String {
        var parts = [
            "- \(stats.stageLabel)",
            "intent=\(stats.renderIntent.rawValue)",
            "encoder=\(stats.encoder)",
            "expected=\(formatSummarySeconds(stats.expectedDurationSeconds))",
            "elapsed=\(formatSummarySeconds(stats.elapsedSeconds))",
            "startup=\(formatOptionalSummarySeconds(stats.startupLatencySeconds))",
            "first_output=\(formatOptionalSummarySeconds(stats.firstOutputGrowthLatencySeconds))",
            "output=\(formatByteCount(stats.finalOutputSizeBytes))",
            "last_out_time=\(formatFFmpegOutTime(stats.latestOutTimeMicroseconds))",
            "speed=\(formatSpeed(stats.latestSpeed))",
            "frames=\(stats.latestFrameCount.map(String.init) ?? "--")",
            "realtime=\(formatRatio(stats.effectiveRealtimeFactor))",
            "max_idle=\(formatSummarySeconds(stats.longestInactivityGapSeconds))",
            "termination=\(stats.terminationSummary)"
        ]
        if !stats.clipAuditBreakdown.isEmpty {
            parts.append("clip_audit=\(formatClipAuditBreakdown(stats.clipAuditBreakdown))")
        }
        if !stats.outputPath.isEmpty {
            parts.append("output_path=\(stats.outputPath)")
        }
        return parts.joined(separator: " | ")
    }

    private static func clipAuditBreakdown(for clips: [FFmpegRenderClip]) -> [RenderClipAuditBreakdown] {
        var counts: [RenderClipAuditInfo: Int] = [:]
        for clip in clips {
            counts[clip.auditInfo, default: 0] += 1
        }
        return counts
            .map { info, count in
                RenderClipAuditBreakdown(
                    kind: info.kind,
                    hasCaptureDateOverlay: info.hasCaptureDateOverlay,
                    clipCount: count
                )
            }
            .sorted {
                if $0.kind == $1.kind {
                    if $0.hasCaptureDateOverlay == $1.hasCaptureDateOverlay {
                        return $0.clipCount > $1.clipCount
                    }
                    return $0.hasCaptureDateOverlay && !$1.hasCaptureDateOverlay
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
    }

    private static func formatClipAuditBreakdown(_ breakdown: [RenderClipAuditBreakdown]) -> String {
        breakdown
            .map { entry in
                let overlayLabel = entry.hasCaptureDateOverlay ? "overlay" : "plain"
                return "\(entry.kind.rawValue):\(overlayLabel):\(entry.clipCount)"
            }
            .joined(separator: ",")
    }

    private static func formatSummarySeconds(_ value: Double) -> String {
        String(format: "%.2fs", max(value, 0))
    }

    private static func formatOptionalSummarySeconds(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "--"
        }
        return formatSummarySeconds(value)
    }

    private static func formatRatio(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else {
            return "--"
        }
        return String(format: "%.2fx", value)
    }

    private func terminationDescription(status: Int32, reason: Process.TerminationReason) -> String {
        switch reason {
        case .exit:
            return "exit \(status)"
        case .uncaughtSignal:
            if let signalName = signalName(for: status) {
                return "signal \(status) (\(signalName))"
            }
            return "signal \(status)"
        @unknown default:
            return "status \(status)"
        }
    }

    private func signalName(for signal: Int32) -> String? {
        switch signal {
        case 2:
            return "SIGINT"
        case 6:
            return "SIGABRT"
        case 9:
            return "SIGKILL"
        case 11:
            return "SIGSEGV"
        case 15:
            return "SIGTERM"
        default:
            return nil
        }
    }

    private func setCurrentProcess(_ process: Process) {
        processLock.lock()
        currentProcess = process
        processLock.unlock()
    }

    private func clearCurrentProcess(_ process: Process) {
        processLock.lock()
        if currentProcess === process {
            currentProcess = nil
        }
        processLock.unlock()
    }
}
