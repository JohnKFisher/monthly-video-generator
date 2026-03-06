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
    func buildCommand(plan: FFmpegRenderPlan, resolution: FFmpegBinaryResolution) throws -> FFmpegCommand {
        guard !plan.clips.isEmpty else {
            throw RenderError.exportFailed("FFmpeg command build failed: no clips were provided.")
        }
        if plan.requiresHDRToSDRToneMapping && !resolution.selectedCapabilities.hasTonemap {
            throw RenderError.exportFailed(
                "FFmpeg command build failed: selected binary does not support the tonemap filter required for SDR export with HDR source clips."
            )
        }
        guard let selectedEncoder = resolution.selectedCapabilities.preferredEncoder(
            for: plan.videoCodec,
            dynamicRange: plan.dynamicRange
        ) else {
            throw RenderError.exportFailed(
                "FFmpeg command build failed: no compatible encoder is available for \(plan.dynamicRange.rawValue.uppercased()) \(plan.videoCodec.rawValue.uppercased())."
            )
        }

        var arguments: [String] = [
            "-hide_banner",
            "-y",
            // Route progress to stderr so it travels over the same stream we
            // already drain for ffmpeg logs in GUI app runs.
            "-progress", "pipe:2",
            "-stats_period", "0.5",
            "-nostats",
            "-nostdin",
            "-ignore_unknown",
            "-dn"
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
            let normalizeFilter = colorNormalizeFilter(for: clip.colorInfo, outputDynamicRange: plan.dynamicRange)
            guard let videoInputIndex = videoInputIndexForClip[index] else {
                throw RenderError.exportFailed("FFmpeg command build failed: missing video input index for clip index \(index).")
            }
            filterParts.append(
                "[\(videoInputIndex):v]trim=duration=\(formatSeconds(clipDuration)),setpts=PTS-STARTPTS,fps=\(plan.frameRate)," +
                "scale=w=\(Int(plan.renderSize.width)):h=\(Int(plan.renderSize.height)):force_original_aspect_ratio=decrease:flags=lanczos," +
                "pad=\(Int(plan.renderSize.width)):\(Int(plan.renderSize.height)):(ow-iw)/2:(oh-ih)/2:color=black," +
                "\(normalizeFilter),format=\(intermediatePixelFormat(for: plan.dynamicRange))[v\(index)]"
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

        filterParts.append("[\(finalVideoLabel)]format=\(finalPixelFormat(for: plan.dynamicRange, encoder: selectedEncoder))[vfinal]")
        filterParts.append("[\(finalAudioLabel)]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[afinal]")

        arguments.append(contentsOf: [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "[vfinal]",
            "-map", "[afinal]"
        ])

        appendEncoderArguments(for: selectedEncoder, plan: plan, arguments: &arguments)

        arguments.append(contentsOf: [
            "-movflags", "+write_colr",
            "-colorspace", outputColorspace(for: plan.dynamicRange),
            "-color_primaries", outputColorPrimaries(for: plan.dynamicRange),
            "-color_trc", outputColorTransfer(for: plan.dynamicRange),
            "-c:a", "aac",
            "-ar", "48000",
            "-ac", "2",
            "-b:a", "192k",
            plan.outputURL.path
        ])

        return FFmpegCommand(executableURL: resolution.selectedBinary.ffmpegURL, arguments: arguments)
    }

    func expectedDurationSeconds(for plan: FFmpegRenderPlan) -> Double {
        let total = plan.clips.reduce(0) { $0 + max($1.durationSeconds, 0.01) }
        let transitions = max(plan.transitionDurationSeconds, 0) * Double(max(plan.clips.count - 1, 0))
        return max(total - transitions, 0.01)
    }

    private func colorNormalizeFilter(for colorInfo: ColorInfo, outputDynamicRange: DynamicRange) -> String {
        switch outputDynamicRange {
        case .hdr:
            return hdrColorNormalizeFilter(for: colorInfo)
        case .sdr:
            return sdrColorNormalizeFilter(for: colorInfo)
        }
    }

    private func hdrColorNormalizeFilter(for colorInfo: ColorInfo) -> String {
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

    private func sdrColorNormalizeFilter(for colorInfo: ColorInfo) -> String {
        if let transferFlavor = hdrTransferFlavor(for: colorInfo) {
            return hdrToSDRToneMapFilter(for: transferFlavor)
        }

        let primaries = (colorInfo.colorPrimaries ?? "").lowercased()
        if primaries.contains("p3") || primaries.contains("smpte432") || primaries.contains("dci") {
            return "zscale=transferin=bt709:primariesin=smpte432:matrixin=bt709:transfer=bt709:primaries=bt709:matrix=bt709"
        }

        return "zscale=transferin=bt709:primariesin=bt709:matrixin=bt709:transfer=bt709:primaries=bt709:matrix=bt709"
    }

    private func hdrTransferFlavor(for colorInfo: ColorInfo) -> FFmpegHDRTransferFlavor? {
        guard colorInfo.isHDR else {
            return nil
        }
        let transfer = (colorInfo.transferFunction ?? "").lowercased()
        if transfer.contains("2084") || transfer.contains("pq") {
            return .pq
        }
        return .hlg
    }

    // SDR output needs explicit HDR-to-SDR tone mapping for video clips with HDR
    // source transfers; a colorspace remap alone clips highlights badly.
    private func hdrToSDRToneMapFilter(for transferFlavor: FFmpegHDRTransferFlavor) -> String {
        let inputTransfer: String
        switch transferFlavor {
        case .pq:
            inputTransfer = "smpte2084"
        case .hlg:
            inputTransfer = "arib-std-b67"
        }
        return "zscale=transferin=\(inputTransfer):primariesin=bt2020:matrixin=bt2020nc:transfer=linear," +
            "format=gbrpf32le," +
            "tonemap=mobius:desat=2," +
            "zscale=transfer=bt709:primaries=bt709:matrix=bt709"
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

    private func x264Preset(for mode: BitrateMode) -> String {
        switch mode {
        case .qualityFirst:
            return "slow"
        case .balanced:
            return "medium"
        case .sizeFirst:
            return "faster"
        }
    }

    private func x264CRF(for mode: BitrateMode) -> String {
        switch mode {
        case .qualityFirst:
            return "14"
        case .balanced:
            return "18"
        case .sizeFirst:
            return "22"
        }
    }

    private func x265CRF(for mode: BitrateMode, dynamicRange: DynamicRange) -> String {
        switch (dynamicRange, mode) {
        case (.hdr, .qualityFirst):
            return "14"
        case (.hdr, .balanced):
            return "17"
        case (.hdr, .sizeFirst):
            return "21"
        case (.sdr, .qualityFirst):
            return "16"
        case (.sdr, .balanced):
            return "19"
        case (.sdr, .sizeFirst):
            return "23"
        }
    }

    private func estimatedBitrate(
        for renderSize: CGSize,
        frameRate: Int,
        bitrateMode: BitrateMode,
        encoder: FFmpegVideoEncoder,
        dynamicRange: DynamicRange
    ) -> String {
        let bitsPerPixel: Double
        switch (dynamicRange, encoder.codec, bitrateMode) {
        case (.hdr, _, .qualityFirst):
            bitsPerPixel = 0.19
        case (.hdr, _, .balanced):
            bitsPerPixel = 0.14
        case (.hdr, _, .sizeFirst):
            bitsPerPixel = 0.10
        case (.sdr, .hevc, .qualityFirst):
            bitsPerPixel = 0.16
        case (.sdr, .hevc, .balanced):
            bitsPerPixel = 0.11
        case (.sdr, .hevc, .sizeFirst):
            bitsPerPixel = 0.08
        case (.sdr, .h264, .qualityFirst):
            bitsPerPixel = 0.22
        case (.sdr, .h264, .balanced):
            bitsPerPixel = 0.16
        case (.sdr, .h264, .sizeFirst):
            bitsPerPixel = 0.12
        }

        let estimate = max(renderSize.width * renderSize.height, 1) * Double(max(frameRate, 24)) * bitsPerPixel
        return String(Int(max(estimate.rounded(), 10_000_000)))
    }

    private func appendEncoderArguments(for encoder: FFmpegVideoEncoder, plan: FFmpegRenderPlan, arguments: inout [String]) {
        switch encoder {
        case .libx264:
            arguments.append(contentsOf: [
                "-c:v", "libx264",
                "-preset", x264Preset(for: plan.bitrateMode),
                "-crf", x264CRF(for: plan.bitrateMode),
                "-pix_fmt", "yuv420p",
                "-profile:v", "high",
                "-tag:v", "avc1"
            ])

        case .h264VideoToolbox:
            arguments.append(contentsOf: [
                "-c:v", "h264_videotoolbox",
                "-pix_fmt", "yuv420p",
                "-profile:v", "high",
                "-tag:v", "avc1",
                "-b:v", estimatedBitrate(
                    for: plan.renderSize,
                    frameRate: plan.frameRate,
                    bitrateMode: plan.bitrateMode,
                    encoder: encoder,
                    dynamicRange: plan.dynamicRange
                )
            ])

        case .libx265:
            var values = [
                "-c:v", "libx265",
                "-preset", x265Preset(for: plan.bitrateMode),
                "-crf", x265CRF(for: plan.bitrateMode, dynamicRange: plan.dynamicRange),
                "-pix_fmt", plan.dynamicRange == .hdr ? "yuv420p10le" : "yuv420p",
                "-tag:v", "hvc1"
            ]
            if plan.dynamicRange == .hdr {
                values.append(contentsOf: [
                    "-x265-params", "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:repeat-headers=1"
                ])
            } else {
                values.append(contentsOf: [
                    "-x265-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709:repeat-headers=1"
                ])
            }
            arguments.append(contentsOf: values)

        case .hevcVideoToolbox:
            arguments.append(contentsOf: [
                "-c:v", "hevc_videotoolbox",
                "-profile:v", plan.dynamicRange == .hdr ? "main10" : "main",
                "-pix_fmt", plan.dynamicRange == .hdr ? "p010le" : "yuv420p",
                "-tag:v", "hvc1",
                "-b:v", estimatedBitrate(
                    for: plan.renderSize,
                    frameRate: plan.frameRate,
                    bitrateMode: plan.bitrateMode,
                    encoder: encoder,
                    dynamicRange: plan.dynamicRange
                )
            ])
        }
    }

    private func intermediatePixelFormat(for dynamicRange: DynamicRange) -> String {
        switch dynamicRange {
        case .hdr:
            return "yuv420p10le"
        case .sdr:
            return "yuv420p"
        }
    }

    private func finalPixelFormat(for dynamicRange: DynamicRange, encoder: FFmpegVideoEncoder) -> String {
        switch (dynamicRange, encoder) {
        case (.hdr, .hevcVideoToolbox):
            return "p010le"
        case (.hdr, _):
            return "yuv420p10le"
        case (.sdr, _):
            return "yuv420p"
        }
    }

    private func outputColorspace(for dynamicRange: DynamicRange) -> String {
        switch dynamicRange {
        case .hdr:
            return "bt2020nc"
        case .sdr:
            return "bt709"
        }
    }

    private func outputColorPrimaries(for dynamicRange: DynamicRange) -> String {
        switch dynamicRange {
        case .hdr:
            return "bt2020"
        case .sdr:
            return "bt709"
        }
    }

    private func outputColorTransfer(for dynamicRange: DynamicRange) -> String {
        switch dynamicRange {
        case .hdr:
            return "arib-std-b67"
        case .sdr:
            return "bt709"
        }
    }
}
