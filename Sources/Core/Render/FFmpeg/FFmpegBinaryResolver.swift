import Foundation

struct FFmpegBinaryResolver {
    private let probe: FFmpegCapabilityProbe
    private let fileManager: FileManager
    private let systemBinaryOverride: FFmpegBinary?
    private let bundledBinaryOverride: FFmpegBinary?
    private let probeOverride: ((FFmpegBinary) throws -> FFmpegCapabilities)?

    init(
        probe: FFmpegCapabilityProbe = FFmpegCapabilityProbe(),
        fileManager: FileManager = .default,
        systemBinaryOverride: FFmpegBinary? = nil,
        bundledBinaryOverride: FFmpegBinary? = nil,
        probeOverride: ((FFmpegBinary) throws -> FFmpegCapabilities)? = nil
    ) {
        self.probe = probe
        self.fileManager = fileManager
        self.systemBinaryOverride = systemBinaryOverride
        self.bundledBinaryOverride = bundledBinaryOverride
        self.probeOverride = probeOverride
    }

    func resolve(
        mode: HDRFFmpegBinaryMode,
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        diagnostics: (String) -> Void
    ) throws -> FFmpegBinaryResolution {
        try resolve(
            mode: mode,
            requirements: FFmpegCapabilityRequirements(codec: codec, dynamicRange: dynamicRange),
            diagnostics: diagnostics
        )
    }

    func resolve(
        mode: HDRFFmpegBinaryMode,
        plan: FFmpegRenderPlan,
        diagnostics: (String) -> Void
    ) throws -> FFmpegBinaryResolution {
        try resolve(
            mode: mode,
            requirements: plan.capabilityRequirements,
            diagnostics: diagnostics
        )
    }

    private func resolve(
        mode: HDRFFmpegBinaryMode,
        requirements: FFmpegCapabilityRequirements,
        diagnostics: (String) -> Void
    ) throws -> FFmpegBinaryResolution {
        let systemBinary = systemBinaryOverride ?? discoverSystemBinary()
        let bundledBinary = bundledBinaryOverride ?? discoverBundledBinary()

        let probeCapabilities = probeOverride ?? { binary in
            try probe.probe(binary: binary)
        }
        let systemCapabilities = try systemBinary.map(probeCapabilities)
        let bundledCapabilities = try bundledBinary.map(probeCapabilities)

        switch mode {
        case .autoSystemThenBundled:
            if let systemBinary,
               let systemCapabilities,
               systemCapabilities.supportsRenderPipeline(requirements: requirements) {
                diagnostics("FFmpeg resolver selected system binary.")
                return FFmpegBinaryResolution(
                    selectedBinary: systemBinary,
                    selectedCapabilities: systemCapabilities,
                    systemCapabilities: systemCapabilities,
                    bundledCapabilities: bundledCapabilities,
                    fallbackReason: nil
                )
            }

            if let bundledBinary,
               let bundledCapabilities,
               bundledCapabilities.supportsRenderPipeline(requirements: requirements) {
                let fallbackReason: String
                if let systemCapabilities {
                    fallbackReason = "System FFmpeg missing required features: \(systemCapabilities.missingRequiredCapabilities(requirements: requirements).joined(separator: ", "))."
                } else {
                    fallbackReason = "System FFmpeg not found."
                }
                diagnostics("FFmpeg resolver selected bundled binary. \(fallbackReason)")
                return FFmpegBinaryResolution(
                    selectedBinary: bundledBinary,
                    selectedCapabilities: bundledCapabilities,
                    systemCapabilities: systemCapabilities,
                    bundledCapabilities: bundledCapabilities,
                    fallbackReason: fallbackReason
                )
            }

            throw RenderError.exportFailed(buildResolutionFailureMessage(
                mode: mode,
                requirements: requirements,
                systemBinary: systemBinary,
                systemCapabilities: systemCapabilities,
                bundledBinary: bundledBinary,
                bundledCapabilities: bundledCapabilities
            ))

        case .systemOnly:
            guard let systemBinary else {
                throw RenderError.exportFailed("FFmpeg engine is set to System Only, but no system ffmpeg was found in PATH/common locations.")
            }
            guard let systemCapabilities else {
                throw RenderError.exportFailed("FFmpeg engine is set to System Only, but system ffmpeg capabilities could not be probed.")
            }
            guard systemCapabilities.supportsRenderPipeline(requirements: requirements) else {
                throw RenderError.exportFailed(
                    "FFmpeg engine is set to System Only, but system ffmpeg is missing: \(systemCapabilities.missingRequiredCapabilities(requirements: requirements).joined(separator: ", "))."
                )
            }
            diagnostics("FFmpeg resolver selected system binary (System Only mode).")
            return FFmpegBinaryResolution(
                selectedBinary: systemBinary,
                selectedCapabilities: systemCapabilities,
                systemCapabilities: systemCapabilities,
                bundledCapabilities: bundledCapabilities,
                fallbackReason: nil
            )

        case .bundledOnly:
            guard let bundledBinary else {
                throw RenderError.exportFailed("FFmpeg engine is set to Bundled Only, but bundled ffmpeg was not found in app resources or third_party/ffmpeg.")
            }
            guard let bundledCapabilities else {
                throw RenderError.exportFailed("FFmpeg engine is set to Bundled Only, but bundled ffmpeg capabilities could not be probed.")
            }
            guard bundledCapabilities.supportsRenderPipeline(requirements: requirements) else {
                throw RenderError.exportFailed(
                    "FFmpeg engine is set to Bundled Only, but bundled ffmpeg is missing: \(bundledCapabilities.missingRequiredCapabilities(requirements: requirements).joined(separator: ", "))."
                )
            }
            diagnostics("FFmpeg resolver selected bundled binary (Bundled Only mode).")
            return FFmpegBinaryResolution(
                selectedBinary: bundledBinary,
                selectedCapabilities: bundledCapabilities,
                systemCapabilities: systemCapabilities,
                bundledCapabilities: bundledCapabilities,
                fallbackReason: nil
            )
        }
    }

    private func buildResolutionFailureMessage(
        mode: HDRFFmpegBinaryMode,
        requirements: FFmpegCapabilityRequirements,
        systemBinary: FFmpegBinary?,
        systemCapabilities: FFmpegCapabilities?,
        bundledBinary: FFmpegBinary?,
        bundledCapabilities: FFmpegCapabilities?
    ) -> String {
        var lines: [String] = []
        lines.append("Unable to resolve FFmpeg for \(requirements.dynamicRange.rawValue.uppercased()) \(requirements.codec.rawValue.uppercased()) export mode \(mode.rawValue).")
        if requirements.requiresHDRToSDRToneMapping {
            lines.append("This render also requires HDR-to-SDR tone mapping support.")
        }

        if let systemBinary {
            if let systemCapabilities {
                lines.append("System: \(systemBinary.ffmpegURL.path) missing [\(systemCapabilities.missingRequiredCapabilities(requirements: requirements).joined(separator: ", "))]")
            } else {
                lines.append("System: \(systemBinary.ffmpegURL.path) probe unavailable")
            }
        } else {
            lines.append("System: not found")
        }

        if let bundledBinary {
            if let bundledCapabilities {
                lines.append("Bundled: \(bundledBinary.ffmpegURL.path) missing [\(bundledCapabilities.missingRequiredCapabilities(requirements: requirements).joined(separator: ", "))]")
            } else {
                lines.append("Bundled: \(bundledBinary.ffmpegURL.path) probe unavailable")
            }
        } else {
            lines.append("Bundled: not found")
        }

        return lines.joined(separator: " ")
    }

    private func discoverSystemBinary() -> FFmpegBinary? {
        let candidates = systemCandidateDirectories().map { $0.appendingPathComponent("ffmpeg") }
        for ffmpegURL in candidates {
            let ffprobeURL = ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe")
            if isExecutable(ffmpegURL), isExecutable(ffprobeURL) {
                return FFmpegBinary(ffmpegURL: ffmpegURL, ffprobeURL: ffprobeURL, source: .system)
            }
        }
        return nil
    }

    private func discoverBundledBinary() -> FFmpegBinary? {
        for root in bundledCandidateRoots() {
            if let binary = binaryPair(root: root, source: .bundled) {
                return binary
            }
            let binRoot = root.appendingPathComponent("bin", isDirectory: true)
            if let binary = binaryPair(root: binRoot, source: .bundled) {
                return binary
            }
        }
        return nil
    }

    private func binaryPair(root: URL, source: FFmpegBinarySource) -> FFmpegBinary? {
        let ffmpegURL = root.appendingPathComponent("ffmpeg")
        let ffprobeURL = root.appendingPathComponent("ffprobe")
        guard isExecutable(ffmpegURL), isExecutable(ffprobeURL) else {
            return nil
        }
        return FFmpegBinary(ffmpegURL: ffmpegURL, ffprobeURL: ffprobeURL, source: source)
    }

    private func systemCandidateDirectories() -> [URL] {
        var directories: [URL] = []

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for raw in pathValue.split(separator: ":") {
            let path = String(raw)
            if path.isEmpty {
                continue
            }
            directories.append(URL(fileURLWithPath: path, isDirectory: true))
        }

        let defaults = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]
        for path in defaults {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if !directories.contains(url) {
                directories.append(url)
            }
        }

        return directories
    }

    private func bundledCandidateRoots() -> [URL] {
        var roots: [URL] = []

        if let env = ProcessInfo.processInfo.environment["MVG_BUNDLED_FFMPEG_ROOT"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env, isDirectory: true))
        }

        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL.appendingPathComponent("FFmpeg", isDirectory: true))
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        roots.append(cwd.appendingPathComponent("third_party/ffmpeg", isDirectory: true))

        return roots
    }

    private func isExecutable(_ url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }
}
