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

    private final class ActivityTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivityAt: Date
        private var latestOutTimeMicroseconds: Int64
        private var latestOutputSizeBytes: UInt64
        private var latestSpeed: Double?

        init(initialOutputSizeBytes: UInt64) {
            self.lastActivityAt = Date()
            self.latestOutTimeMicroseconds = 0
            self.latestOutputSizeBytes = initialOutputSizeBytes
            self.latestSpeed = nil
        }

        func recordOutTime(_ outTimeMicroseconds: Int64) {
            lock.lock()
            if outTimeMicroseconds > latestOutTimeMicroseconds {
                latestOutTimeMicroseconds = outTimeMicroseconds
                lastActivityAt = Date()
            }
            lock.unlock()
        }

        func recordOutputSize(_ outputSizeBytes: UInt64) {
            lock.lock()
            if outputSizeBytes > latestOutputSizeBytes {
                latestOutputSizeBytes = outputSizeBytes
                lastActivityAt = Date()
            }
            lock.unlock()
        }

        func recordSpeed(_ speed: Double?) {
            guard let speed, speed.isFinite, speed > 0 else {
                return
            }
            lock.lock()
            latestSpeed = speed
            lastActivityAt = Date()
            lock.unlock()
        }

        func recordCPUActivity() {
            lock.lock()
            lastActivityAt = Date()
            lock.unlock()
        }

        func snapshot() -> ActivitySnapshot {
            lock.lock()
            let snapshot = ActivitySnapshot(
                lastActivityAt: lastActivityAt,
                latestOutTimeMicroseconds: latestOutTimeMicroseconds,
                latestOutputSizeBytes: latestOutputSizeBytes,
                latestSpeed: latestSpeed
            )
            lock.unlock()
            return snapshot
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
        statusHandler: @escaping (String) -> Void = { _ in }
    ) async throws -> FFmpegBinaryResolution {
        let callbacks = CallbackRelay(
            diagnostics: diagnostics,
            progress: progressHandler,
            status: statusHandler
        )
        if fileManager.fileExists(atPath: plan.outputURL.path) {
            try fileManager.removeItem(at: plan.outputURL)
        }

        let resolution = try resolver.resolve(
            mode: binaryMode,
            plan: plan,
            diagnostics: diagnostics
        )
        let command = try commandBuilder.buildCommand(plan: plan, resolution: resolution)
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
        if plan.requiresHDRToSDRToneMapping {
            callbacks.log(
                "HDR-to-SDR tone mapping enabled: true (operator=mobius:desat=2, hlg_npl=\(FFmpegCommandBuilder.hlgSDRNominalPeak), clips=\(plan.hdrToSDRToneMapClips.count))"
            )
            for clip in plan.hdrToSDRToneMapClips {
                callbacks.log("HDR-to-SDR tone-map clip: \(clip.sourceDescription) [transfer=\(clip.transferFlavor.rawValue)]")
            }
        } else {
            callbacks.log("HDR-to-SDR tone mapping enabled: false")
        }
        callbacks.log("Capture-date overlays enabled: \(plan.requiresCaptureDateOverlay) (clips=\(plan.clips.filter { $0.captureDateOverlayURL != nil }.count))")
        callbacks.log("FFmpeg selected binary: \(resolution.selectedBinary.ffmpegURL.path) [\(resolution.selectedBinary.source.rawValue)]")
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
        setCurrentProcess(process)
        callbacks.report(0.01)
        callbacks.updateStatus("\(plan.dynamicRange == .hdr ? "HDR" : "SDR") encode: starting...")

        defer {
            clearCurrentProcess(process)
        }

        let totalDurationMicroseconds = Int64(commandBuilder.expectedDurationSeconds(for: plan) * 1_000_000)
        let estimatedOutputBytes = estimatedFinalOutputBytes(for: plan)
        let renderStartedAt = Date()
        let activityTracker = ActivityTracker(initialOutputSizeBytes: currentOutputSizeBytes(at: plan.outputURL) ?? 0)

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        async let stdoutTask: Void = Self.consumeStdout(
            handle: stdoutHandle,
            callbacks: callbacks
        )
        async let stderrTask: [String] = Self.consumeStderr(
            handle: stderrHandle,
            callbacks: callbacks,
            activityTracker: activityTracker,
            totalDurationMicroseconds: totalDurationMicroseconds,
            estimatedOutputBytes: estimatedOutputBytes,
            renderStartedAt: renderStartedAt
        )

        let termination: ProcessTermination = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await waitForTermination(
                of: process,
                outputURL: plan.outputURL,
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

        // Force-close pipes after termination so line readers cannot hang waiting for EOF.
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()

        let stderrTail = await stderrTask
        _ = await stdoutTask

        guard termination.status == 0 else {
            let details = failureDetails(from: stderrTail)
            let terminationSummary = terminationDescription(status: termination.status, reason: termination.reason)
            let detailSuffix = details.isEmpty ? "No additional stderr details." : details
            if let stallContext = termination.stallContext {
                throw RenderError.exportFailed(
                    "FFmpeg \(plan.dynamicRange == .hdr ? "HDR" : "SDR") render stalled for \(Int(stallContext.stallDurationSeconds.rounded()))s " +
                    "(last_out_time_us=\(stallContext.lastOutTimeMicroseconds), output=\(Self.formatByteCount(stallContext.lastOutputSizeBytes))). " +
                    "Terminated with \(terminationSummary). \(detailSuffix)"
                )
            }
            throw RenderError.exportFailed(
                "FFmpeg \(plan.dynamicRange == .hdr ? "HDR" : "SDR") render failed (\(terminationSummary)). \(detailSuffix)"
            )
        }

        callbacks.report(1.0)
        let finalSnapshot = activityTracker.snapshot()
        callbacks.updateStatus(
            Self.statusLine(
                progress: 1.0,
                elapsed: Date().timeIntervalSince(renderStartedAt),
                outputSizeBytes: finalSnapshot.latestOutputSizeBytes,
                speed: nil
            )
        )
        return resolution
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
        activityTracker: ActivityTracker,
        totalDurationMicroseconds: Int64,
        estimatedOutputBytes: UInt64,
        renderStartedAt: Date
    ) async -> [String] {
        var tail: [String] = []
        var progressParser = FFmpegProgressParser()
        await consumePipeText(handle: handle) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return
            }
            if consumeProgressLine(
                trimmed,
                parser: &progressParser,
                callbacks: callbacks,
                activityTracker: activityTracker,
                totalDurationMicroseconds: totalDurationMicroseconds,
                estimatedOutputBytes: estimatedOutputBytes,
                renderStartedAt: renderStartedAt
            ) {
                return
            }
            callbacks.log("FFmpeg stderr: \(trimmed)")
            tail.append(trimmed)
            if tail.count > 240 {
                tail.removeFirst(tail.count - 240)
            }
        }
        return tail
    }

    private static func consumePipeText(
        handle: FileHandle,
        onLine: @escaping (String) -> Void
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

        let previousOutTime = parser.latestOutTimeMS
        let previousTotalSizeBytes = parser.latestTotalSizeBytes
        let update = parser.ingest(line: line)

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
            let outputSizeBytes = UInt64(update.totalSizeBytes ?? 0)
            let preferredOutputSize = max(outputSizeBytes, snapshot.latestOutputSizeBytes)
            callbacks.updateStatus(
                statusLine(
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
                    if let previousCPUTimeSeconds = lastCPUTimeSeconds,
                       cpuTimeSeconds > previousCPUTimeSeconds + 0.10 {
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

    private func failureDetails(from stderrTail: [String]) -> String {
        let highlighted = stderrTail.filter { Self.isNoteworthyStderrLine($0) }
        if !highlighted.isEmpty {
            return highlighted.suffix(8).joined(separator: " | ")
        }

        let filteredTail = stderrTail.filter { !Self.isRoutineStderrLine($0) }
        if !filteredTail.isEmpty {
            return filteredTail.suffix(8).joined(separator: " | ")
        }

        return stderrTail.suffix(8).joined(separator: " | ")
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
        var usage = rusage_info_current()
        var usagePointer: rusage_info_t? = withUnsafeMutablePointer(to: &usage) { pointer in
            UnsafeMutableRawPointer(pointer)
        }
        let result = withUnsafeMutablePointer(to: &usagePointer) { pointer in
            proc_pid_rusage(pid, Int32(RUSAGE_INFO_CURRENT), pointer)
        }
        guard result == 0 else {
            return nil
        }
        let totalNanoseconds = usage.ri_user_time + usage.ri_system_time
        return Double(totalNanoseconds) / 1_000_000_000
    }

    private static func statusLine(
        progress: Double,
        elapsed: TimeInterval,
        outputSizeBytes: UInt64,
        speed: Double?
    ) -> String {
        let clampedProgress = min(max(progress, 0), 1)
        let percent = Int((clampedProgress * 100).rounded())
        return "HDR encode: \(percent)% | elapsed \(formatElapsed(elapsed)) | output \(formatByteCount(outputSizeBytes)) | speed \(formatSpeed(speed))"
    }

    private static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let clampedSeconds = max(Int(elapsed.rounded()), 0)
        let minutes = clampedSeconds / 60
        let seconds = clampedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func formatByteCount(_ bytes: UInt64) -> String {
        let clampedBytes = min(bytes, UInt64(Int64.max))
        return ByteCountFormatter.string(fromByteCount: Int64(clampedBytes), countStyle: .file)
    }

    private static func formatSpeed(_ speed: Double?) -> String {
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

    private func estimatedFinalOutputBytes(for plan: FFmpegRenderPlan) -> UInt64 {
        let durationSeconds = max(commandBuilder.expectedDurationSeconds(for: plan), 0.01)
        let pixelsPerFrame = max(plan.renderSize.width * plan.renderSize.height, 1)
        let bitsPerPixel = estimatedBitsPerPixel(
            for: plan.bitrateMode,
            codec: plan.videoCodec,
            dynamicRange: plan.dynamicRange
        )
        let videoBits = pixelsPerFrame * Double(max(plan.frameRate, 24)) * durationSeconds * bitsPerPixel
        let audioBits = Double(plan.audioLayout.aacBitrate ?? 192_000) * durationSeconds
        let totalBytes = max((videoBits + audioBits) / 8.0, 1)
        return UInt64(totalBytes.rounded())
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
