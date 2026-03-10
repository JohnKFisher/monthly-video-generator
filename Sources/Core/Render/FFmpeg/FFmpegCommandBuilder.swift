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
    static let hlgSDRNominalPeak = 1400
    static let hdrSDRNominalPeak = 225

    func buildCommand(plan: FFmpegRenderPlan, resolution: FFmpegBinaryResolution) throws -> FFmpegCommand {
        guard !plan.clips.isEmpty else {
            throw RenderError.exportFailed("FFmpeg command build failed: no clips were provided.")
        }
        guard let outputChannelLayout = plan.audioLayout.ffmpegChannelLayout,
              let outputChannelCount = plan.audioLayout.outputChannelCount else {
            throw RenderError.exportFailed("FFmpeg command build failed: audio layout must be resolved before command generation.")
        }
        let audioBitrate = plan.renderIntent == .finalDelivery ? plan.audioLayout.aacBitrate : nil
        if plan.renderIntent == .finalDelivery, audioBitrate == nil {
            throw RenderError.exportFailed("FFmpeg command build failed: audio layout must be resolved before command generation.")
        }
        if plan.requiresHDRToSDRToneMapping && !resolution.selectedCapabilities.hasTonemap {
            throw RenderError.exportFailed(
                "FFmpeg command build failed: selected binary does not support the tonemap filter required for SDR export with HDR source clips."
            )
        }
        if plan.capabilityRequirements.requiresOverlay && !resolution.selectedCapabilities.hasOverlay {
            throw RenderError.exportFailed(
                "FFmpeg command build failed: selected binary does not support the overlay filter required for media-derived backgrounds."
            )
        }
        guard let selectedEncoder = resolution.selectedCapabilities.preferredEncoder(
            for: plan.videoCodec,
            dynamicRange: plan.dynamicRange,
            hdrHEVCEncoderMode: plan.hdrHEVCEncoderMode,
            renderIntent: plan.renderIntent
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

        if let threadLimit = ffmpegThreadLimit(for: selectedEncoder, plan: plan) {
            arguments.append(contentsOf: ["-threads", String(threadLimit)])
        }

        var videoInputIndexForClip: [Int: Int] = [:]
        var overlayInputIndexForClip: [Int: Int] = [:]
        var audioInputIndexForClip: [Int: Int] = [:]
        var nextInputIndex = 0

        for (clipIndex, clip) in plan.clips.enumerated() {
            let videoInputIndex = nextInputIndex
            arguments.append(contentsOf: ["-i", clip.url.path])
            nextInputIndex += 1
            videoInputIndexForClip[clipIndex] = videoInputIndex

            if let overlayURL = clip.captureDateOverlayURL {
                let overlayInputIndex = nextInputIndex
                arguments.append(contentsOf: [
                    "-framerate", String(plan.frameRate),
                    "-loop", "1",
                    "-i", overlayURL.path
                ])
                nextInputIndex += 1
                overlayInputIndexForClip[clipIndex] = overlayInputIndex
            }

            if clip.includeAudio && clip.hasAudioTrack {
                audioInputIndexForClip[clipIndex] = videoInputIndex
            } else {
                let silentInputIndex = nextInputIndex
                arguments.append(contentsOf: [
                    "-f", "lavfi",
                    "-t", formatSeconds(clip.durationSeconds),
                    "-i", "anullsrc=r=48000:cl=\(outputChannelLayout)"
                ])
                nextInputIndex += 1
                audioInputIndexForClip[clipIndex] = silentInputIndex
            }
        }

        var chapterInputIndex: Int?
        if plan.renderIntent == .finalDelivery,
           plan.container == .mp4,
           !plan.chapters.isEmpty,
           let chapterMetadataURL = plan.chapterMetadataURL {
            chapterInputIndex = nextInputIndex
            arguments.append(contentsOf: [
                "-f", "ffmetadata",
                "-i", chapterMetadataURL.path
            ])
            nextInputIndex += 1
        }

        var filterParts: [String] = []
        let renderWidth = Int(plan.renderSize.width.rounded())
        let renderHeight = Int(plan.renderSize.height.rounded())
        let backgroundMetrics = MediaDerivedBackgroundStyle.metrics(for: plan.renderSize)
        let zoomedBackgroundWidth = Int(backgroundMetrics.zoomedRenderSize.width.rounded())
        let zoomedBackgroundHeight = Int(backgroundMetrics.zoomedRenderSize.height.rounded())
        let downsampledBackgroundWidth = Int(backgroundMetrics.downsampledSize.width.rounded())
        let downsampledBackgroundHeight = Int(backgroundMetrics.downsampledSize.height.rounded())
        for (index, clip) in plan.clips.enumerated() {
            let clipDuration = max(clip.durationSeconds, 0.01)
            let normalizeFilter = try colorNormalizeFilter(for: clip.colorInfo, outputDynamicRange: plan.dynamicRange)
            guard let videoInputIndex = videoInputIndexForClip[index] else {
                throw RenderError.exportFailed("FFmpeg command build failed: missing video input index for clip index \(index).")
            }
            let videoOutputLabel = overlayInputIndexForClip[index] == nil ? "v\(index)" : "vbase\(index)"
            let foregroundSourceLabel = "vfgsrc\(index)"
            let backgroundSourceLabel = "vbgsrc\(index)"
            let foregroundLabel = "vfg\(index)"
            let backgroundLabel = "vbg\(index)"
            filterParts.append(
                "[\(videoInputIndex):v]trim=duration=\(formatSeconds(clipDuration)),setpts=PTS-STARTPTS,fps=\(plan.frameRate)," +
                "\(normalizeFilter),split=2[\(foregroundSourceLabel)][\(backgroundSourceLabel)]"
            )
            filterParts.append(
                "[\(foregroundSourceLabel)]scale=w=\(renderWidth):h=\(renderHeight):force_original_aspect_ratio=decrease:flags=lanczos," +
                "setsar=1[\(foregroundLabel)]"
            )
            filterParts.append(
                "[\(backgroundSourceLabel)]scale=w=\(zoomedBackgroundWidth):h=\(zoomedBackgroundHeight):" +
                "force_original_aspect_ratio=increase:flags=lanczos," +
                "crop=\(zoomedBackgroundWidth):\(zoomedBackgroundHeight)," +
                "scale=w=\(downsampledBackgroundWidth):h=\(downsampledBackgroundHeight):flags=bilinear," +
                "setsar=1," +
                "gblur=sigma=\(formatScalar(Double(backgroundMetrics.blurRadius))):steps=1," +
                "eq=saturation=\(formatScalar(Double(backgroundMetrics.saturation)))," +
                "lutyuv=y=val*\(formatScalar(Double(backgroundMetrics.dimMultiplier)))," +
                "scale=w=\(renderWidth):h=\(renderHeight):flags=lanczos," +
                "setsar=1[\(backgroundLabel)]"
            )
            filterParts.append(
                "[\(backgroundLabel)][\(foregroundLabel)]overlay=x=(main_w-overlay_w)/2:y=(main_h-overlay_h)/2:shortest=1:format=auto," +
                "format=\(intermediatePixelFormat(for: plan.dynamicRange))[\(videoOutputLabel)]"
            )

            if let overlayInputIndex = overlayInputIndexForClip[index] {
                let overlayLayout = CaptureDateOverlayLayout.metrics(for: plan.renderSize)
                filterParts.append(
                    "[\(overlayInputIndex):v]trim=duration=\(formatSeconds(clipDuration)),setpts=PTS-STARTPTS,format=rgba[ov\(index)]"
                )
                filterParts.append(
                    "[\(videoOutputLabel)][ov\(index)]overlay=x=main_w-overlay_w-\(overlayLayout.horizontalMargin):" +
                    "y=main_h-overlay_h-\(overlayLayout.verticalMargin):shortest=1:format=auto[v\(index)]"
                )
            }

            guard let audioInputIndex = audioInputIndexForClip[index] else {
                throw RenderError.exportFailed("FFmpeg command build failed: no audio input available for clip index \(index).")
            }
            filterParts.append(
                "[\(audioInputIndex):a:0]atrim=duration=\(formatSeconds(clipDuration)),asetpts=PTS-STARTPTS," +
                "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=\(outputChannelLayout)[a\(index)]"
            )
        }

        let transition = max(plan.transitionDurationSeconds, 0)
        let totalDurationSeconds = expectedDurationSeconds(for: plan)
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

        let endFadeDurationSeconds = min(max(plan.endFadeToBlackDurationSeconds, 0), totalDurationSeconds)
        let composedVideoLabel: String
        if endFadeDurationSeconds > 0 {
            let endFadeStartSeconds = max(totalDurationSeconds - endFadeDurationSeconds, 0)
            let fadedVideoLabel = "vfaded"
            filterParts.append(
                "[\(finalVideoLabel)]fade=t=out:st=\(formatSeconds(endFadeStartSeconds)):d=\(formatSeconds(endFadeDurationSeconds)):color=black[\(fadedVideoLabel)]"
            )
            composedVideoLabel = fadedVideoLabel
        } else {
            composedVideoLabel = finalVideoLabel
        }

        filterParts.append("[\(composedVideoLabel)]format=\(finalPixelFormat(for: plan.dynamicRange, encoder: selectedEncoder))[vfinal]")
        filterParts.append("[\(finalAudioLabel)]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=\(outputChannelLayout)[afinal]")

        arguments.append(contentsOf: [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "[vfinal]",
            "-map", "[afinal]"
        ])
        if let chapterInputIndex {
            arguments.append(contentsOf: ["-map_chapters", String(chapterInputIndex)])
        }

        appendEncoderArguments(for: selectedEncoder, plan: plan, arguments: &arguments)
        appendAudioArguments(
            for: plan,
            outputChannelCount: outputChannelCount,
            audioBitrate: audioBitrate,
            arguments: &arguments
        )

        appendEmbeddedMetadataArguments(for: plan, arguments: &arguments)

        arguments.append(contentsOf: [
            "-movflags", movflags(for: plan),
            "-colorspace", outputColorspace(for: plan.dynamicRange),
            "-color_primaries", outputColorPrimaries(for: plan.dynamicRange),
            "-color_trc", outputColorTransfer(for: plan.dynamicRange),
            plan.outputURL.path
        ])

        return FFmpegCommand(executableURL: resolution.selectedBinary.ffmpegURL, arguments: arguments)
    }

    func expectedDurationSeconds(for plan: FFmpegRenderPlan) -> Double {
        let total = plan.clips.reduce(0) { $0 + max($1.durationSeconds, 0.01) }
        let transitions = max(plan.transitionDurationSeconds, 0) * Double(max(plan.clips.count - 1, 0))
        return max(total - transitions, 0.01)
    }

    func profileSummary(for plan: FFmpegRenderPlan, encoder: FFmpegVideoEncoder) -> String {
        switch plan.renderIntent {
        case .finalDelivery:
            switch encoder {
            case .libx264:
                return "intent=finalDelivery encoder=libx264 preset=\(x264Preset(for: plan.bitrateMode)) crf=\(x264CRF(for: plan.bitrateMode)) audio=aac"
            case .h264VideoToolbox:
                return "intent=finalDelivery encoder=h264_videotoolbox bitrate=\(estimatedBitrate(for: plan.renderSize, frameRate: plan.frameRate, bitrateMode: plan.bitrateMode, encoder: encoder, dynamicRange: plan.dynamicRange)) audio=aac"
            case .libx265:
                var summary = "intent=finalDelivery encoder=libx265 preset=\(x265Preset(for: plan.bitrateMode)) crf=\(x265CRF(for: plan.bitrateMode, dynamicRange: plan.dynamicRange))"
                if let threadLimit = ffmpegThreadLimit(for: encoder, plan: plan) {
                    let frameThreads = x265FrameThreadLimit(for: plan)
                    summary += " threads=\(threadLimit) x265=pools=\(threadLimit):frame-threads=\(frameThreads)"
                }
                summary += " audio=aac"
                return summary
            case .hevcVideoToolbox:
                return "intent=finalDelivery encoder=hevc_videotoolbox bitrate=\(estimatedBitrate(for: plan.renderSize, frameRate: plan.frameRate, bitrateMode: plan.bitrateMode, encoder: encoder, dynamicRange: plan.dynamicRange)) audio=aac"
            }
        case .intermediateChunk:
            let bitrate = intermediateBitrate(for: plan.renderSize, frameRate: plan.frameRate)
            switch encoder {
            case .hevcVideoToolbox:
                return "intent=intermediateChunk encoder=hevc_videotoolbox bitrate=\(bitrate) audio=pcm_s16le"
            case .libx265:
                return "intent=intermediateChunk encoder=libx265 preset=medium bitrate=\(bitrate) audio=pcm_s16le"
            case .h264VideoToolbox:
                return "intent=intermediateChunk encoder=h264_videotoolbox audio=pcm_s16le"
            case .libx264:
                return "intent=intermediateChunk encoder=libx264 audio=pcm_s16le"
            }
        }
    }

    private func colorNormalizeFilter(for colorInfo: ColorInfo, outputDynamicRange: DynamicRange) throws -> String {
        switch outputDynamicRange {
        case .hdr:
            return try hdrColorNormalizeFilter(for: colorInfo)
        case .sdr:
            return sdrColorNormalizeFilter(for: colorInfo)
        }
    }

    private func hdrColorNormalizeFilter(for colorInfo: ColorInfo) throws -> String {
        switch colorInfo.transferFlavor {
        case .pq:
                return "zscale=transferin=smpte2084:primariesin=bt2020:matrixin=bt2020nc:transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc"
        case .hlg:
            return "zscale=transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc:transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc"
        case .sdr:
            return try sdrToHLGUpliftFilter(for: colorInfo)
        }
    }

    private func sdrColorNormalizeFilter(for colorInfo: ColorInfo) -> String {
        if let transferFlavor = hdrTransferFlavor(for: colorInfo) {
            return hdrToSDRToneMapFilter(for: transferFlavor)
        }

        let transferIn = sdrTransferInput(for: colorInfo)
        let primariesIn = sdrPrimariesInput(for: colorInfo)
        return "zscale=transferin=\(transferIn):primariesin=\(primariesIn):matrixin=bt709:transfer=bt709:primaries=bt709:matrix=bt709"
    }

    private func hdrTransferFlavor(for colorInfo: ColorInfo) -> FFmpegHDRTransferFlavor? {
        switch colorInfo.transferFlavor {
        case .pq:
            return .pq
        case .hlg:
            return .hlg
        case .sdr:
            return nil
        }
    }

    private func sdrToHLGUpliftFilter(for colorInfo: ColorInfo) throws -> String {
        let transferIn = sdrTransferInput(for: colorInfo)
        let primariesIn = sdrPrimariesInput(for: colorInfo)
        return "zscale=transferin=\(transferIn):primariesin=\(primariesIn):matrixin=bt709:transfer=linear," +
            "format=gbrpf32le," +
            // Map SDR into HLG with a lower nominal peak so SDR white lands in
            // the expected HLG range instead of being pushed toward washed-out highlights.
            "zscale=transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc:range=tv:npl=\(Self.hdrSDRNominalPeak)"
    }

    private func sdrTransferInput(for colorInfo: ColorInfo) -> String {
        let normalizedTransfer = (colorInfo.transferFunction ?? "").lowercased()
        if normalizedTransfer.contains("iec_srgb") || normalizedTransfer.contains("srgb") || normalizedTransfer.contains("61966") {
            return "iec61966-2-1"
        }
        return "bt709"
    }

    private func sdrPrimariesInput(for colorInfo: ColorInfo) -> String {
        colorInfo.isDisplayP3Like ? "smpte432" : "bt709"
    }

    // SDR output needs explicit HDR-to-SDR tone mapping for video clips with HDR
    // source transfers; a colorspace remap alone clips highlights badly.
    private func hdrToSDRToneMapFilter(for transferFlavor: FFmpegHDRTransferFlavor) -> String {
        switch transferFlavor {
        case .pq:
            return "zscale=transferin=smpte2084:primariesin=bt2020:matrixin=bt2020nc:transfer=linear," +
                "format=gbrpf32le," +
                "tonemap=mobius:desat=2," +
                "zscale=transfer=bt709:primaries=bt709:matrix=bt709"
        case .hlg:
            // iPhone HLG clips need an explicit nominal peak and gamut reduction
            // before tone mapping or the resulting SDR image stays visibly blown out.
            return "zscale=transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc:transfer=linear:npl=\(Self.hlgSDRNominalPeak)," +
                "format=gbrpf32le," +
                "zscale=primaries=bt709," +
                "tonemap=mobius:desat=2," +
                "zscale=transfer=bt709:matrix=bt709:range=tv"
        }
    }

    private func formatSeconds(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private func formatScalar(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private func audioBitrateArgument(_ bitrate: Int) -> String {
        "\(bitrate / 1_000)k"
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

    private func intermediateBitrate(
        for renderSize: CGSize,
        frameRate: Int
    ) -> String {
        let bitsPerPixel = 0.22
        let estimate = max(renderSize.width * renderSize.height, 1) * Double(max(frameRate, 24)) * bitsPerPixel
        return String(Int(max(estimate.rounded(), 18_000_000)))
    }

    private func appendEncoderArguments(for encoder: FFmpegVideoEncoder, plan: FFmpegRenderPlan, arguments: inout [String]) {
        if plan.renderIntent == .intermediateChunk {
            appendIntermediateEncoderArguments(for: encoder, plan: plan, arguments: &arguments)
            return
        }

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
            values.append(contentsOf: ["-x265-params", x265ParameterString(for: plan)])
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

    private func appendIntermediateEncoderArguments(
        for encoder: FFmpegVideoEncoder,
        plan: FFmpegRenderPlan,
        arguments: inout [String]
    ) {
        let bitrate = intermediateBitrate(for: plan.renderSize, frameRate: plan.frameRate)

        switch encoder {
        case .hevcVideoToolbox:
            arguments.append(contentsOf: [
                "-c:v", "hevc_videotoolbox",
                "-profile:v", plan.dynamicRange == .hdr ? "main10" : "main",
                "-pix_fmt", plan.dynamicRange == .hdr ? "p010le" : "yuv420p",
                "-tag:v", "hvc1",
                "-b:v", bitrate
            ])

        case .libx265:
            var values = [
                "-c:v", "libx265",
                "-preset", "medium",
                "-b:v", bitrate,
                "-maxrate", bitrate,
                "-bufsize", String(Int((Double(bitrate) ?? 18_000_000) * 2)),
                "-pix_fmt", plan.dynamicRange == .hdr ? "yuv420p10le" : "yuv420p",
                "-tag:v", "hvc1"
            ]
            values.append(contentsOf: ["-x265-params", x265ParameterString(for: plan)])
            arguments.append(contentsOf: values)

        case .h264VideoToolbox, .libx264:
            // The chunked path is HDR/HEVC-only today, but keep a compatible
            // fallback so intent-specific command generation remains coherent.
            appendEncoderArguments(for: encoder.fallbackForUnsupportedIntermediate, plan: plan.finalDeliveryEquivalent, arguments: &arguments)
        }
    }

    private func appendAudioArguments(
        for plan: FFmpegRenderPlan,
        outputChannelCount: Int,
        audioBitrate: Int?,
        arguments: inout [String]
    ) {
        switch plan.renderIntent {
        case .finalDelivery:
            guard let audioBitrate else {
                return
            }
            arguments.append(contentsOf: [
                "-c:a", "aac",
                "-ar", "48000",
                "-ac", String(outputChannelCount),
                "-b:a", audioBitrateArgument(audioBitrate)
            ])
        case .intermediateChunk:
            arguments.append(contentsOf: [
                "-c:a", "pcm_s16le",
                "-ar", "48000",
                "-ac", String(outputChannelCount)
            ])
        }
    }

    private func ffmpegThreadLimit(for encoder: FFmpegVideoEncoder, plan: FFmpegRenderPlan) -> Int? {
        guard
            encoder == .libx265,
            plan.renderIntent == .finalDelivery,
            plan.dynamicRange == .hdr
        else {
            return nil
        }

        return min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 4)
    }

    private func x265FrameThreadLimit(for plan: FFmpegRenderPlan) -> Int {
        guard plan.renderIntent == .finalDelivery, plan.dynamicRange == .hdr else {
            return 0
        }

        return min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 2)
    }

    private func x265ParameterString(for plan: FFmpegRenderPlan) -> String {
        var parameters: [String]
        if plan.dynamicRange == .hdr {
            parameters = [
                "colorprim=bt2020",
                "transfer=arib-std-b67",
                "colormatrix=bt2020nc",
                "repeat-headers=1"
            ]
        } else {
            parameters = [
                "colorprim=bt709",
                "transfer=bt709",
                "colormatrix=bt709",
                "repeat-headers=1"
            ]
        }

        if let threadLimit = ffmpegThreadLimit(for: .libx265, plan: plan) {
            parameters.append("pools=\(threadLimit)")
            parameters.append("frame-threads=\(x265FrameThreadLimit(for: plan))")
        }

        return parameters.joined(separator: ":")
    }

    private func appendEmbeddedMetadataArguments(for plan: FFmpegRenderPlan, arguments: inout [String]) {
        guard plan.renderIntent == .finalDelivery,
              plan.container == .mp4,
              let embeddedMetadata = plan.embeddedMetadata else {
            return
        }

        var metadataEntries: [(String, String)] = [
            ("title", embeddedMetadata.title),
            ("show", embeddedMetadata.show),
            ("season_number", String(embeddedMetadata.seasonNumber)),
            ("episode_sort", String(embeddedMetadata.episodeSort)),
            ("episode_id", embeddedMetadata.episodeID),
            ("date", embeddedMetadata.date),
            ("description", embeddedMetadata.description),
            ("synopsis", embeddedMetadata.synopsis),
            ("comment", embeddedMetadata.comment),
            ("genre", embeddedMetadata.genre)
        ]

        if let creationTime = embeddedMetadata.creationTime {
            metadataEntries.append(("creation_time", metadataTimestamp(from: creationTime)))
        }

        if let provenance = embeddedMetadata.provenance {
            metadataEntries.append(contentsOf: [
                ("software", provenance.software),
                ("version", provenance.version),
                ("information", provenance.information)
            ])
            metadataEntries.append(
                contentsOf: provenance.customEntries
                    .sorted { lhs, rhs in lhs.key < rhs.key }
                    .map { ($0.key, $0.value) }
            )
        }

        for (key, value) in metadataEntries where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["-metadata", "\(key)=\(value)"])
        }
    }

    private func movflags(for plan: FFmpegRenderPlan) -> String {
        guard plan.renderIntent == .finalDelivery, plan.container == .mp4 else {
            return "+write_colr"
        }
        return "+write_colr+use_metadata_tags"
    }

    private func metadataTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
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

private extension FFmpegVideoEncoder {
    var fallbackForUnsupportedIntermediate: FFmpegVideoEncoder {
        switch self {
        case .libx264, .h264VideoToolbox:
            return .libx264
        case .libx265:
            return .libx265
        case .hevcVideoToolbox:
            return .hevcVideoToolbox
        }
    }
}

private extension FFmpegRenderPlan {
    var finalDeliveryEquivalent: FFmpegRenderPlan {
        FFmpegRenderPlan(
            clips: clips,
            transitionDurationSeconds: transitionDurationSeconds,
            endFadeToBlackDurationSeconds: endFadeToBlackDurationSeconds,
            outputURL: outputURL,
            renderSize: renderSize,
            frameRate: frameRate,
            audioLayout: audioLayout,
            bitrateMode: bitrateMode,
            container: container,
            videoCodec: videoCodec,
            dynamicRange: dynamicRange,
            hdrHEVCEncoderMode: hdrHEVCEncoderMode,
            embeddedMetadata: embeddedMetadata,
            chapters: chapters,
            chapterMetadataURL: chapterMetadataURL,
            renderIntent: .finalDelivery
        )
    }
}
