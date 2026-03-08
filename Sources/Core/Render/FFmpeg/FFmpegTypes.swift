import CoreGraphics
import Foundation

enum FFmpegBinarySource: String, Codable, Sendable {
    case system
    case bundled
}

enum FFmpegVideoEncoder: String, Codable, Sendable {
    case libx264
    case h264VideoToolbox
    case libx265
    case hevcVideoToolbox

    var codec: VideoCodec {
        switch self {
        case .libx264, .h264VideoToolbox:
            return .h264
        case .libx265, .hevcVideoToolbox:
            return .hevc
        }
    }

    var displayLabel: String {
        switch self {
        case .libx264:
            return "libx264"
        case .h264VideoToolbox, .hevcVideoToolbox:
            return "VideoToolbox"
        case .libx265:
            return "libx265"
        }
    }
}

enum FFmpegRenderIntent: String, Equatable, Sendable {
    case finalDelivery
    case intermediateChunk
}

struct FFmpegBinary: Equatable, Sendable {
    let ffmpegURL: URL
    let ffprobeURL: URL
    let source: FFmpegBinarySource

    var displayLabel: String {
        "\(source.rawValue) (\(ffmpegURL.path))"
    }
}

struct FFmpegCapabilities: Equatable, Sendable {
    let versionDescription: String
    let hasZscale: Bool
    let hasTonemap: Bool
    let hasXfade: Bool
    let hasAcrossfade: Bool
    let hasOverlay: Bool
    let hasLibx264: Bool
    let hasH264VideoToolbox: Bool
    let hasLibx265: Bool
    let hasHEVCVideoToolbox: Bool

    init(
        versionDescription: String,
        hasZscale: Bool,
        hasTonemap: Bool,
        hasXfade: Bool,
        hasAcrossfade: Bool,
        hasOverlay: Bool = true,
        hasLibx264: Bool,
        hasH264VideoToolbox: Bool,
        hasLibx265: Bool,
        hasHEVCVideoToolbox: Bool
    ) {
        self.versionDescription = versionDescription
        self.hasZscale = hasZscale
        self.hasTonemap = hasTonemap
        self.hasXfade = hasXfade
        self.hasAcrossfade = hasAcrossfade
        self.hasOverlay = hasOverlay
        self.hasLibx264 = hasLibx264
        self.hasH264VideoToolbox = hasH264VideoToolbox
        self.hasLibx265 = hasLibx265
        self.hasHEVCVideoToolbox = hasHEVCVideoToolbox
    }

    func preferredEncoder(
        for codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic,
        renderIntent: FFmpegRenderIntent = .finalDelivery
    ) -> FFmpegVideoEncoder? {
        for encoder in preferredEncoders(
            for: codec,
            dynamicRange: dynamicRange,
            hdrHEVCEncoderMode: hdrHEVCEncoderMode,
            renderIntent: renderIntent
        ) where supports(encoder) {
            return encoder
        }
        return nil
    }

    func supportsRenderPipeline(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic,
        renderIntent: FFmpegRenderIntent = .finalDelivery
    ) -> Bool {
        supportsRenderPipeline(
            requirements: FFmpegCapabilityRequirements(
                codec: codec,
                dynamicRange: dynamicRange,
                hdrHEVCEncoderMode: hdrHEVCEncoderMode,
                renderIntent: renderIntent
            )
        )
    }

    func supportsRenderPipeline(requirements: FFmpegCapabilityRequirements) -> Bool {
        hasZscale &&
            (!requirements.requiresHDRToSDRToneMapping || hasTonemap) &&
            hasXfade &&
            hasAcrossfade &&
            (!requirements.requiresOverlay || hasOverlay) &&
            preferredEncoder(
                for: requirements.codec,
                dynamicRange: requirements.dynamicRange,
                hdrHEVCEncoderMode: requirements.hdrHEVCEncoderMode,
                renderIntent: requirements.renderIntent
            ) != nil
    }

    func missingRequiredCapabilities(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic,
        renderIntent: FFmpegRenderIntent = .finalDelivery
    ) -> [String] {
        missingRequiredCapabilities(
            requirements: FFmpegCapabilityRequirements(
                codec: codec,
                dynamicRange: dynamicRange,
                hdrHEVCEncoderMode: hdrHEVCEncoderMode,
                renderIntent: renderIntent
            )
        )
    }

    func missingRequiredCapabilities(requirements: FFmpegCapabilityRequirements) -> [String] {
        var missing: [String] = []
        if !hasZscale {
            missing.append("zscale filter")
        }
        if requirements.requiresHDRToSDRToneMapping && !hasTonemap {
            missing.append("tonemap filter")
        }
        if !hasXfade {
            missing.append("xfade filter")
        }
        if !hasAcrossfade {
            missing.append("acrossfade filter")
        }
        if requirements.requiresOverlay && !hasOverlay {
            missing.append("overlay filter")
        }
        if preferredEncoder(
            for: requirements.codec,
            dynamicRange: requirements.dynamicRange,
            hdrHEVCEncoderMode: requirements.hdrHEVCEncoderMode,
            renderIntent: requirements.renderIntent
        ) == nil {
            missing.append(
                requiredEncoderDescription(
                    codec: requirements.codec,
                    dynamicRange: requirements.dynamicRange,
                    hdrHEVCEncoderMode: requirements.hdrHEVCEncoderMode,
                    renderIntent: requirements.renderIntent
                )
            )
        }
        return missing
    }

    private func supports(_ encoder: FFmpegVideoEncoder) -> Bool {
        switch encoder {
        case .libx264:
            return hasLibx264
        case .h264VideoToolbox:
            return hasH264VideoToolbox
        case .libx265:
            return hasLibx265
        case .hevcVideoToolbox:
            return hasHEVCVideoToolbox
        }
    }

    func preferredEncoders(
        for codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode,
        renderIntent: FFmpegRenderIntent
    ) -> [FFmpegVideoEncoder] {
        switch renderIntent {
        case .finalDelivery:
            switch (dynamicRange, codec, hdrHEVCEncoderMode) {
            case (.hdr, .hevc, .automatic):
                return [.libx265, .hevcVideoToolbox]
            case (.hdr, .hevc, .videoToolbox):
                return [.hevcVideoToolbox]
            case (.hdr, .h264, _):
                return []
            case (.sdr, .hevc, _):
                return [.hevcVideoToolbox, .libx265]
            case (.sdr, .h264, _):
                return [.h264VideoToolbox, .libx264]
            }
        case .intermediateChunk:
            switch (dynamicRange, codec) {
            case (.hdr, .hevc), (.sdr, .hevc):
                return [.hevcVideoToolbox, .libx265]
            case (.sdr, .h264):
                return [.h264VideoToolbox, .libx264]
            case (.hdr, .h264):
                return []
            }
        }
    }

    private func requiredEncoderDescription(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode,
        renderIntent: FFmpegRenderIntent
    ) -> String {
        switch (renderIntent, dynamicRange, codec, hdrHEVCEncoderMode) {
        case (.intermediateChunk, .hdr, .hevc, _):
            return "HEVC Main10 intermediate encoder (hevc_videotoolbox or libx265)"
        case (.intermediateChunk, .sdr, .hevc, _):
            return "HEVC intermediate encoder (hevc_videotoolbox or libx265)"
        case (.intermediateChunk, .sdr, .h264, _):
            return "H.264 intermediate encoder (h264_videotoolbox or libx264)"
        case (.intermediateChunk, .hdr, .h264, _):
            return "HDR HEVC Main10 intermediate encoder (hevc_videotoolbox or libx265)"
        case (.finalDelivery, .hdr, .hevc, .videoToolbox):
            return "hevc_videotoolbox HEVC Main10 encoder"
        case (.finalDelivery, .hdr, .hevc, .automatic):
            return "HEVC Main10 encoder (libx265 or hevc_videotoolbox)"
        case (.finalDelivery, .hdr, .h264, _):
            return "HDR HEVC Main10 encoder (libx265 or hevc_videotoolbox)"
        case (.finalDelivery, .sdr, .hevc, _):
            return "HEVC encoder (hevc_videotoolbox or libx265)"
        case (.finalDelivery, .sdr, .h264, _):
            return "H.264 encoder (h264_videotoolbox or libx264)"
        }
    }
}

struct FFmpegBinaryResolution: Equatable, Sendable {
    let selectedBinary: FFmpegBinary
    let selectedCapabilities: FFmpegCapabilities
    let systemCapabilities: FFmpegCapabilities?
    let bundledCapabilities: FFmpegCapabilities?
    let fallbackReason: String?

    func backendSummary(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic,
        renderIntent: FFmpegRenderIntent = .finalDelivery
    ) -> String {
        var base = "FFmpeg \(dynamicRange == .hdr ? "HDR" : "SDR") backend [\(selectedBinary.source.rawValue)]"
        if let encoder = selectedCapabilities.preferredEncoder(
            for: codec,
            dynamicRange: dynamicRange,
            hdrHEVCEncoderMode: hdrHEVCEncoderMode,
            renderIntent: renderIntent
        ) {
            base += " (encoder: \(encoder.rawValue))"
        }
        return base
    }

    func backendInfo(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic,
        renderIntent: FFmpegRenderIntent = .finalDelivery
    ) -> RenderBackendInfo {
        RenderBackendInfo(
            binarySource: selectedBinary.source.renderBackendBinarySource,
            encoder: selectedCapabilities.preferredEncoder(
                for: codec,
                dynamicRange: dynamicRange,
                hdrHEVCEncoderMode: hdrHEVCEncoderMode,
                renderIntent: renderIntent
            )?.rawValue
        )
    }
}

struct FFmpegRenderClip: Equatable, Sendable {
    let url: URL
    let durationSeconds: Double
    let includeAudio: Bool
    let hasAudioTrack: Bool
    let colorInfo: ColorInfo
    let sourceDescription: String
    let captureDateOverlayURL: URL?

    init(
        url: URL,
        durationSeconds: Double,
        includeAudio: Bool,
        hasAudioTrack: Bool,
        colorInfo: ColorInfo,
        sourceDescription: String,
        captureDateOverlayURL: URL? = nil
    ) {
        self.url = url
        self.durationSeconds = durationSeconds
        self.includeAudio = includeAudio
        self.hasAudioTrack = hasAudioTrack
        self.colorInfo = colorInfo
        self.sourceDescription = sourceDescription
        self.captureDateOverlayURL = captureDateOverlayURL
    }
}

struct FFmpegCapabilityRequirements: Equatable, Sendable {
    let codec: VideoCodec
    let dynamicRange: DynamicRange
    let hdrHEVCEncoderMode: HDRHEVCEncoderMode
    let renderIntent: FFmpegRenderIntent
    let requiresHDRToSDRToneMapping: Bool
    let requiresOverlay: Bool

    init(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic,
        renderIntent: FFmpegRenderIntent = .finalDelivery,
        requiresHDRToSDRToneMapping: Bool = false,
        requiresOverlay: Bool = false
    ) {
        self.codec = codec
        self.dynamicRange = dynamicRange
        self.hdrHEVCEncoderMode = hdrHEVCEncoderMode
        self.renderIntent = renderIntent
        self.requiresHDRToSDRToneMapping = requiresHDRToSDRToneMapping
        self.requiresOverlay = requiresOverlay
    }
}

enum FFmpegHDRTransferFlavor: String, Equatable, Sendable {
    case pq = "PQ"
    case hlg = "HLG"
}

struct FFmpegHDRToSDRToneMapClip: Equatable, Sendable {
    let sourceDescription: String
    let transferFlavor: FFmpegHDRTransferFlavor
}

struct FFmpegRenderPlan: Equatable, Sendable {
    let clips: [FFmpegRenderClip]
    let transitionDurationSeconds: Double
    let endFadeToBlackDurationSeconds: Double
    let outputURL: URL
    let renderSize: CGSize
    let frameRate: Int
    let audioLayout: AudioLayout
    let bitrateMode: BitrateMode
    let container: ContainerFormat
    let videoCodec: VideoCodec
    let dynamicRange: DynamicRange
    let hdrHEVCEncoderMode: HDRHEVCEncoderMode
    let embeddedMetadata: EmbeddedOutputMetadata?
    let renderIntent: FFmpegRenderIntent

    init(
        clips: [FFmpegRenderClip],
        transitionDurationSeconds: Double,
        endFadeToBlackDurationSeconds: Double = 0,
        outputURL: URL,
        renderSize: CGSize,
        frameRate: Int,
        audioLayout: AudioLayout,
        bitrateMode: BitrateMode,
        container: ContainerFormat,
        videoCodec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic,
        embeddedMetadata: EmbeddedOutputMetadata? = nil,
        renderIntent: FFmpegRenderIntent = .finalDelivery
    ) {
        self.clips = clips
        self.transitionDurationSeconds = transitionDurationSeconds
        self.endFadeToBlackDurationSeconds = max(endFadeToBlackDurationSeconds, 0)
        self.outputURL = outputURL
        self.renderSize = renderSize
        self.frameRate = frameRate
        self.audioLayout = audioLayout
        self.bitrateMode = bitrateMode
        self.container = container
        self.videoCodec = videoCodec
        self.dynamicRange = dynamicRange
        self.hdrHEVCEncoderMode = hdrHEVCEncoderMode
        self.embeddedMetadata = embeddedMetadata
        self.renderIntent = renderIntent
    }

    var capabilityRequirements: FFmpegCapabilityRequirements {
        FFmpegCapabilityRequirements(
            codec: videoCodec,
            dynamicRange: dynamicRange,
            hdrHEVCEncoderMode: hdrHEVCEncoderMode,
            renderIntent: renderIntent,
            requiresHDRToSDRToneMapping: requiresHDRToSDRToneMapping,
            requiresOverlay: requiresGeneratedBackgroundComposite || requiresCaptureDateOverlay
        )
    }

    var requiresHDRToSDRToneMapping: Bool {
        dynamicRange == .sdr && clips.contains { $0.colorInfo.ffmpegHDRTransferFlavor != nil }
    }

    var hdrToSDRToneMapClips: [FFmpegHDRToSDRToneMapClip] {
        guard dynamicRange == .sdr else {
            return []
        }
        return clips.compactMap { clip in
            guard let transferFlavor = clip.colorInfo.ffmpegHDRTransferFlavor else {
                return nil
            }
            return FFmpegHDRToSDRToneMapClip(
                sourceDescription: clip.sourceDescription,
                transferFlavor: transferFlavor
            )
        }
    }

    var requiresCaptureDateOverlay: Bool {
        clips.contains { $0.captureDateOverlayURL != nil }
    }

    var requiresGeneratedBackgroundComposite: Bool {
        true
    }
}

private extension ColorInfo {
    var ffmpegHDRTransferFlavor: FFmpegHDRTransferFlavor? {
        guard isHDR else {
            return nil
        }
        let transfer = (transferFunction ?? "").lowercased()
        if transfer.contains("2084") || transfer.contains("pq") {
            return .pq
        }
        return .hlg
    }
}

private extension FFmpegBinarySource {
    var renderBackendBinarySource: RenderBackendBinarySource {
        switch self {
        case .system:
            return .system
        case .bundled:
            return .bundled
        }
    }
}
