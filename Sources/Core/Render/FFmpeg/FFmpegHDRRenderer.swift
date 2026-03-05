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
                    if tail.count > 120 {
                        tail.removeFirst(tail.count - 120)
                    }
                }
            } catch {
                callbacks.log("FFmpeg stderr stream ended with error: \(error.localizedDescription)")
            }
            return tail
        }

        let terminationStatus: Int32 = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return await waitForTermination(of: process)
        } onCancel: {
            process.terminate()
        }

        let stderrTail = await stderrTask.value
        _ = await stdoutTask.value

        guard terminationStatus == 0 else {
            let details = stderrTail.suffix(8).joined(separator: " | ")
            throw RenderError.exportFailed(
                "FFmpeg HDR render failed (exit \(terminationStatus)). \(details)"
            )
        }

        callbacks.report(1.0)
        return resolution
    }

    private func waitForTermination(of process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { completed in
                continuation.resume(returning: completed.terminationStatus)
            }
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
