import Foundation

final class FFmpegHDRRenderer {
    private final class CallbackRelay: @unchecked Sendable {
        private let diagnostics: (String) -> Void
        private let progress: (Double) -> Void
        private let lock = NSLock()

        init(diagnostics: @escaping (String) -> Void, progress: @escaping (Double) -> Void) {
            self.diagnostics = diagnostics
            self.progress = progress
        }

        func log(_ message: String) {
            lock.lock()
            diagnostics(message)
            lock.unlock()
        }

        func report(_ value: Double) {
            lock.lock()
            progress(value)
            lock.unlock()
        }
    }

    private let resolver: FFmpegBinaryResolver
    private let commandBuilder: FFmpegCommandBuilder
    private let fileManager: FileManager

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
        plan: FFmpegHDRRenderPlan,
        binaryMode: HDRFFmpegBinaryMode,
        diagnostics: @escaping (String) -> Void,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> FFmpegBinaryResolution {
        let callbacks = CallbackRelay(diagnostics: diagnostics, progress: progressHandler)
        if fileManager.fileExists(atPath: plan.outputURL.path) {
            try fileManager.removeItem(at: plan.outputURL)
        }

        let resolution = try resolver.resolve(mode: binaryMode, diagnostics: diagnostics)
        let command = try commandBuilder.buildCommand(plan: plan, resolution: resolution)
        callbacks.log("FFmpeg version: \(resolution.selectedCapabilities.versionDescription)")
        if let systemCaps = resolution.systemCapabilities {
            callbacks.log(
                "FFmpeg system capabilities: zscale=\(systemCaps.hasZscale), xfade=\(systemCaps.hasXfade), " +
                "acrossfade=\(systemCaps.hasAcrossfade), libx265=\(systemCaps.hasLibx265), hevc_videotoolbox=\(systemCaps.hasHEVCVideoToolbox)"
            )
        }
        if let bundledCaps = resolution.bundledCapabilities {
            callbacks.log(
                "FFmpeg bundled capabilities: zscale=\(bundledCaps.hasZscale), xfade=\(bundledCaps.hasXfade), " +
                "acrossfade=\(bundledCaps.hasAcrossfade), libx265=\(bundledCaps.hasLibx265), hevc_videotoolbox=\(bundledCaps.hasHEVCVideoToolbox)"
            )
        }
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

        defer {
            clearCurrentProcess(process)
        }

        let totalDurationMicroseconds = Int64(commandBuilder.expectedDurationSeconds(for: plan) * 1_000_000)

        let stdoutTask = Task { () -> Void in
            var parser = FFmpegProgressParser()
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    parser.ingest(line: line)
                    let progress = parser.progress(totalDurationMicroseconds: totalDurationMicroseconds)
                    callbacks.report(progress)
                }
            } catch {
                callbacks.log("FFmpeg stdout stream ended with error: \(error.localizedDescription)")
            }
        }

        let stderrTask = Task { () -> [String] in
            var tail: [String] = []
            do {
                for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        continue
                    }
                    callbacks.log("FFmpeg stderr: \(trimmed)")
                    tail.append(trimmed)
                    if tail.count > 240 {
                        tail.removeFirst(tail.count - 240)
                    }
                }
            } catch {
                callbacks.log("FFmpeg stderr stream ended with error: \(error.localizedDescription)")
            }
            return tail
        }

        let termination: (status: Int32, reason: Process.TerminationReason) = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return await waitForTermination(of: process)
        } onCancel: {
            process.terminate()
        }

        let stderrTail = await stderrTask.value
        _ = await stdoutTask.value

        guard termination.status == 0 else {
            let details = failureDetails(from: stderrTail)
            let terminationSummary = terminationDescription(status: termination.status, reason: termination.reason)
            let detailSuffix = details.isEmpty ? "No additional stderr details." : details
            throw RenderError.exportFailed(
                "FFmpeg HDR render failed (\(terminationSummary)). \(detailSuffix)"
            )
        }

        callbacks.report(1.0)
        return resolution
    }

    private func waitForTermination(of process: Process) async -> (status: Int32, reason: Process.TerminationReason) {
        if !process.isRunning {
            return (process.terminationStatus, process.terminationReason)
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { completed in
                continuation.resume(returning: (completed.terminationStatus, completed.terminationReason))
            }
        }
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
