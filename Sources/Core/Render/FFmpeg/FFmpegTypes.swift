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
    let hasLibx264: Bool
    let hasH264VideoToolbox: Bool
    let hasLibx265: Bool
    let hasHEVCVideoToolbox: Bool

    func preferredEncoder(
        for codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic
    ) -> FFmpegVideoEncoder? {
        for encoder in preferredEncoders(
            for: codec,
            dynamicRange: dynamicRange,
            hdrHEVCEncoderMode: hdrHEVCEncoderMode
        ) where supports(encoder) {
            return encoder
        }
        return nil
    }

    func supportsRenderPipeline(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic
    ) -> Bool {
        supportsRenderPipeline(
            requirements: FFmpegCapabilityRequirements(
                codec: codec,
                dynamicRange: dynamicRange,
                hdrHEVCEncoderMode: hdrHEVCEncoderMode
            )
        )
    }

    func supportsRenderPipeline(requirements: FFmpegCapabilityRequirements) -> Bool {
        hasZscale &&
            (!requirements.requiresHDRToSDRToneMapping || hasTonemap) &&
            hasXfade &&
            hasAcrossfade &&
            preferredEncoder(
                for: requirements.codec,
                dynamicRange: requirements.dynamicRange,
                hdrHEVCEncoderMode: requirements.hdrHEVCEncoderMode
            ) != nil
    }

    func missingRequiredCapabilities(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic
    ) -> [String] {
        missingRequiredCapabilities(
            requirements: FFmpegCapabilityRequirements(
                codec: codec,
                dynamicRange: dynamicRange,
                hdrHEVCEncoderMode: hdrHEVCEncoderMode
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
        if preferredEncoder(
            for: requirements.codec,
            dynamicRange: requirements.dynamicRange,
            hdrHEVCEncoderMode: requirements.hdrHEVCEncoderMode
        ) == nil {
            missing.append(
                requiredEncoderDescription(
                    codec: requirements.codec,
                    dynamicRange: requirements.dynamicRange,
                    hdrHEVCEncoderMode: requirements.hdrHEVCEncoderMode
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

    private func preferredEncoders(
        for codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode
    ) -> [FFmpegVideoEncoder] {
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
    }

    private func requiredEncoderDescription(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode
    ) -> String {
        switch (dynamicRange, codec, hdrHEVCEncoderMode) {
        case (.hdr, .hevc, .videoToolbox):
            return "hevc_videotoolbox HEVC Main10 encoder"
        case (.hdr, .hevc, .automatic):
            return "HEVC Main10 encoder (libx265 or hevc_videotoolbox)"
        case (.hdr, .h264, _):
            return "HDR HEVC Main10 encoder (libx265 or hevc_videotoolbox)"
        case (.sdr, .hevc, _):
            return "HEVC encoder (hevc_videotoolbox or libx265)"
        case (.sdr, .h264, _):
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
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic
    ) -> String {
        var base = "FFmpeg \(dynamicRange == .hdr ? "HDR" : "SDR") backend [\(selectedBinary.source.rawValue)]"
        if let encoder = selectedCapabilities.preferredEncoder(
            for: codec,
            dynamicRange: dynamicRange,
            hdrHEVCEncoderMode: hdrHEVCEncoderMode
        ) {
            base += " (encoder: \(encoder.rawValue))"
        }
        return base
    }

    func backendInfo(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic
    ) -> RenderBackendInfo {
        RenderBackendInfo(
            binarySource: selectedBinary.source.renderBackendBinarySource,
            encoder: selectedCapabilities.preferredEncoder(
                for: codec,
                dynamicRange: dynamicRange,
                hdrHEVCEncoderMode: hdrHEVCEncoderMode
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
}

struct FFmpegCapabilityRequirements: Equatable, Sendable {
    let codec: VideoCodec
    let dynamicRange: DynamicRange
    let hdrHEVCEncoderMode: HDRHEVCEncoderMode
    let requiresHDRToSDRToneMapping: Bool

    init(
        codec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic,
        requiresHDRToSDRToneMapping: Bool = false
    ) {
        self.codec = codec
        self.dynamicRange = dynamicRange
        self.hdrHEVCEncoderMode = hdrHEVCEncoderMode
        self.requiresHDRToSDRToneMapping = requiresHDRToSDRToneMapping
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
    let outputURL: URL
    let renderSize: CGSize
    let frameRate: Int
    let audioLayout: AudioLayout
    let bitrateMode: BitrateMode
    let container: ContainerFormat
    let videoCodec: VideoCodec
    let dynamicRange: DynamicRange
    let hdrHEVCEncoderMode: HDRHEVCEncoderMode

    init(
        clips: [FFmpegRenderClip],
        transitionDurationSeconds: Double,
        outputURL: URL,
        renderSize: CGSize,
        frameRate: Int,
        audioLayout: AudioLayout,
        bitrateMode: BitrateMode,
        container: ContainerFormat,
        videoCodec: VideoCodec,
        dynamicRange: DynamicRange,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode = .automatic
    ) {
        self.clips = clips
        self.transitionDurationSeconds = transitionDurationSeconds
        self.outputURL = outputURL
        self.renderSize = renderSize
        self.frameRate = frameRate
        self.audioLayout = audioLayout
        self.bitrateMode = bitrateMode
        self.container = container
        self.videoCodec = videoCodec
        self.dynamicRange = dynamicRange
        self.hdrHEVCEncoderMode = hdrHEVCEncoderMode
    }

    var capabilityRequirements: FFmpegCapabilityRequirements {
        FFmpegCapabilityRequirements(
            codec: videoCodec,
            dynamicRange: dynamicRange,
            hdrHEVCEncoderMode: hdrHEVCEncoderMode,
            requiresHDRToSDRToneMapping: requiresHDRToSDRToneMapping
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
