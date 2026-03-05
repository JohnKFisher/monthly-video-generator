import CoreGraphics
import Foundation

struct FFmpegCommand {
    let executableURL: URL
    let arguments: [String]

    var printableCommand: String {
        ([executableURL.path] + arguments).map(Self.quoteIfNeeded).joined(separator: " ")
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        if value.contains(" ") {
            return "\"\(value)\""
        }
        return value
    }
}

struct FFmpegCommandBuilder {
    func buildCommand(plan: FFmpegHDRRenderPlan, resolution: FFmpegBinaryResolution) throws -> FFmpegCommand {
        guard !plan.clips.isEmpty else {
            throw RenderError.exportFailed("FFmpeg command build failed: no clips were provided.")
        }

        var arguments: [String] = [
            "-hide_banner",
            "-y",
            // Route progress to stderr so it travels over the same stream we
            // already drain for ffmpeg logs in GUI app runs.
            "-progress", "pipe:2",
            "-stats_period", "0.5",
            "-nostats",
            "-nostdin"
        ]

        var videoInputIndexForClip: [Int: Int] = [:]
        var audioInputIndexForClip: [Int: Int] = [:]
        var nextInputIndex = 0

        for (clipIndex, clip) in plan.clips.enumerated() {
            let videoInputIndex = nextInputIndex
            arguments.append(contentsOf: ["-i", clip.url.path])
            nextInputIndex += 1
            videoInputIndexForClip[clipIndex] = videoInputIndex

            if clip.includeAudio && clip.hasAudioTrack {
                audioInputIndexForClip[clipIndex] = videoInputIndex
            } else {
                let silentInputIndex = nextInputIndex
                arguments.append(contentsOf: [
                    "-f", "lavfi",
                    "-t", formatSeconds(clip.durationSeconds),
                    "-i", "anullsrc=r=48000:cl=stereo"
                ])
                nextInputIndex += 1
                audioInputIndexForClip[clipIndex] = silentInputIndex
            }
        }

        var filterParts: [String] = []
        for (index, clip) in plan.clips.enumerated() {
            let clipDuration = max(clip.durationSeconds, 0.01)
            let normalizeFilter = colorNormalizeFilter(for: clip.colorInfo)
            guard let videoInputIndex = videoInputIndexForClip[index] else {
                throw RenderError.exportFailed("FFmpeg command build failed: missing video input index for clip index \(index).")
            }
            // Keep conversion in a 10-bit path to avoid large float RGB intermediates at high resolutions.
            filterParts.append(
                "[\(videoInputIndex):v]trim=duration=\(formatSeconds(clipDuration)),setpts=PTS-STARTPTS,fps=\(plan.frameRate)," +
                "scale=w=\(Int(plan.renderSize.width)):h=\(Int(plan.renderSize.height)):force_original_aspect_ratio=decrease:flags=lanczos," +
                "pad=\(Int(plan.renderSize.width)):\(Int(plan.renderSize.height)):(ow-iw)/2:(oh-ih)/2:color=black," +
                "\(normalizeFilter),format=yuv420p10le[v\(index)]"
            )

            guard let audioInputIndex = audioInputIndexForClip[index] else {
                throw RenderError.exportFailed("FFmpeg command build failed: no audio input available for clip index \(index).")
            }
            filterParts.append(
                "[\(audioInputIndex):a:0]atrim=duration=\(formatSeconds(clipDuration)),asetpts=PTS-STARTPTS," +
                "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[a\(index)]"
            )
        }

        let transition = max(plan.transitionDurationSeconds, 0)
        let finalVideoLabel: String
        let finalAudioLabel: String

        if plan.clips.count == 1 || transition <= 0 {
            finalVideoLabel = "v0"
            finalAudioLabel = "a0"
        } else {
            var currentVideoLabel = "v0"
            var currentAudioLabel = "a0"
            var cumulativeDuration = max(plan.clips[0].durationSeconds, 0.01)

            for index in 1..<plan.clips.count {
                let videoLabel = "vx\(index)"
                let audioLabel = "ax\(index)"
                let offset = max(cumulativeDuration - transition * Double(index), 0)

                filterParts.append(
                    "[\(currentVideoLabel)][v\(index)]xfade=transition=fade:duration=\(formatSeconds(transition)):offset=\(formatSeconds(offset))[\(videoLabel)]"
                )
                filterParts.append(
                    "[\(currentAudioLabel)][a\(index)]acrossfade=d=\(formatSeconds(transition)):c1=tri:c2=tri[\(audioLabel)]"
                )

                currentVideoLabel = videoLabel
                currentAudioLabel = audioLabel
                cumulativeDuration += max(plan.clips[index].durationSeconds, 0.01)
            }

            finalVideoLabel = currentVideoLabel
            finalAudioLabel = currentAudioLabel
        }

        filterParts.append("[\(finalVideoLabel)]format=yuv420p10le[vfinal]")
        filterParts.append("[\(finalAudioLabel)]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[afinal]")

        arguments.append(contentsOf: [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "[vfinal]",
            "-map", "[afinal]"
        ])

        switch resolution.selectedCapabilities.preferredEncoder {
        case .libx265:
            arguments.append(contentsOf: [
                "-c:v", "libx265",
                "-preset", x265Preset(for: plan.bitrateMode),
                "-crf", x265CRF(for: plan.bitrateMode),
                "-pix_fmt", "yuv420p10le",
                "-tag:v", "hvc1",
                "-x265-params", "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:repeat-headers=1"
            ])

        case .hevcVideoToolbox:
            arguments.append(contentsOf: [
                "-c:v", "hevc_videotoolbox",
                "-profile:v", "main10",
                "-pix_fmt", "p010le",
                "-tag:v", "hvc1",
                "-b:v", estimatedBitrate(for: plan.renderSize, frameRate: plan.frameRate, bitrateMode: plan.bitrateMode)
            ])

        case .none:
            throw RenderError.exportFailed("FFmpeg command build failed: no compatible HEVC encoder is available.")
        }

        arguments.append(contentsOf: [
            "-movflags", "+write_colr",
            "-colorspace", "bt2020nc",
            "-color_primaries", "bt2020",
            "-color_trc", "arib-std-b67",
            "-c:a", "aac",
            "-ar", "48000",
            "-ac", "2",
            "-b:a", "192k",
            plan.outputURL.path
        ])

        return FFmpegCommand(executableURL: resolution.selectedBinary.ffmpegURL, arguments: arguments)
    }

    func expectedDurationSeconds(for plan: FFmpegHDRRenderPlan) -> Double {
        let total = plan.clips.reduce(0) { $0 + max($1.durationSeconds, 0.01) }
        let transitions = max(plan.transitionDurationSeconds, 0) * Double(max(plan.clips.count - 1, 0))
        return max(total - transitions, 0.01)
    }

    private func colorNormalizeFilter(for colorInfo: ColorInfo) -> String {
        if colorInfo.isHDR {
            let transfer = (colorInfo.transferFunction ?? "").lowercased()
            if transfer.contains("2084") || transfer.contains("pq") {
                return "zscale=transferin=smpte2084:primariesin=bt2020:matrixin=bt2020nc:transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc"
            }
            return "zscale=transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc:transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc"
        }

        let primaries = (colorInfo.colorPrimaries ?? "").lowercased()
        if primaries.contains("p3") || primaries.contains("smpte432") || primaries.contains("dci") {
            return "zscale=transferin=bt709:primariesin=smpte432:matrixin=bt709:transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc"
        }

        return "zscale=transferin=bt709:primariesin=bt709:matrixin=bt709:transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc"
    }

    private func formatSeconds(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private func x265Preset(for mode: BitrateMode) -> String {
        switch mode {
        case .qualityFirst:
            return "slow"
        case .balanced:
            return "medium"
        case .sizeFirst:
            return "faster"
        }
    }

    private func x265CRF(for mode: BitrateMode) -> String {
        switch mode {
        case .qualityFirst:
            return "14"
        case .balanced:
            return "17"
        case .sizeFirst:
            return "21"
        }
    }

    private func estimatedBitrate(for renderSize: CGSize, frameRate: Int, bitrateMode: BitrateMode) -> String {
        let bitsPerPixel: Double
        switch bitrateMode {
        case .qualityFirst:
            bitsPerPixel = 0.19
        case .balanced:
            bitsPerPixel = 0.14
        case .sizeFirst:
            bitsPerPixel = 0.10
        }

        let estimate = max(renderSize.width * renderSize.height, 1) * Double(max(frameRate, 24)) * bitsPerPixel
        return String(Int(max(estimate.rounded(), 10_000_000)))
    }
}
