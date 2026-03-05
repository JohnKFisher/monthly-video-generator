import Foundation

struct FFmpegCapabilityProbe {
    func probe(binary: FFmpegBinary) throws -> FFmpegCapabilities {
        let versionOutput = try run(binary.ffmpegURL, arguments: ["-hide_banner", "-version"])
        let filtersOutput = try run(binary.ffmpegURL, arguments: ["-hide_banner", "-filters"])
        let encodersOutput = try run(binary.ffmpegURL, arguments: ["-hide_banner", "-encoders"])
        return Self.parseCapabilities(
            versionOutput: versionOutput,
            filtersOutput: filtersOutput,
            encodersOutput: encodersOutput
        )
    }

    static func parseCapabilities(
        versionOutput: String,
        filtersOutput: String,
        encodersOutput: String
    ) -> FFmpegCapabilities {
        let normalizedFilters = filtersOutput.lowercased()
        let normalizedEncoders = encodersOutput.lowercased()

        let hasZscale = containsWord("zscale", in: normalizedFilters)
        let hasXfade = containsWord("xfade", in: normalizedFilters)
        let hasAcrossfade = containsWord("acrossfade", in: normalizedFilters)
        let hasLibx265 = containsWord("libx265", in: normalizedEncoders)
        let hasHEVCVideoToolbox = containsWord("hevc_videotoolbox", in: normalizedEncoders)

        return FFmpegCapabilities(
            versionDescription: parseVersionDescription(from: versionOutput),
            hasZscale: hasZscale,
            hasXfade: hasXfade,
            hasAcrossfade: hasAcrossfade,
            hasLibx265: hasLibx265,
            hasHEVCVideoToolbox: hasHEVCVideoToolbox
        )
    }

    static func parseVersionDescription(from versionOutput: String) -> String {
        for line in versionOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("ffmpeg version") {
                return trimmed
            }
        }
        return "ffmpeg version unknown"
    }

    private static func containsWord(_ word: String, in source: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = "\\b\(escaped)\\b"
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    private func run(_ executableURL: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let combined = stdout + "\n" + stderr

        guard process.terminationStatus == 0 else {
            throw RenderError.exportFailed(
                "FFmpeg capability probe failed for \(executableURL.path) with status \(process.terminationStatus). Output: \(combined)"
            )
        }

        return combined
    }
}
