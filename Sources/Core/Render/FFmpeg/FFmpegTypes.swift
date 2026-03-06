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
    let hasXfade: Bool
    let hasAcrossfade: Bool
    let hasLibx264: Bool
    let hasH264VideoToolbox: Bool
    let hasLibx265: Bool
    let hasHEVCVideoToolbox: Bool

    func preferredEncoder(for codec: VideoCodec, dynamicRange: DynamicRange) -> FFmpegVideoEncoder? {
        for encoder in preferredEncoders(for: codec, dynamicRange: dynamicRange) where supports(encoder) {
            return encoder
        }
        return nil
    }

    func supportsRenderPipeline(codec: VideoCodec, dynamicRange: DynamicRange) -> Bool {
        hasZscale && hasXfade && hasAcrossfade && preferredEncoder(for: codec, dynamicRange: dynamicRange) != nil
    }

    func missingRequiredCapabilities(codec: VideoCodec, dynamicRange: DynamicRange) -> [String] {
        var missing: [String] = []
        if !hasZscale {
            missing.append("zscale filter")
        }
        if !hasXfade {
            missing.append("xfade filter")
        }
        if !hasAcrossfade {
            missing.append("acrossfade filter")
        }
        if preferredEncoder(for: codec, dynamicRange: dynamicRange) == nil {
            missing.append(requiredEncoderDescription(codec: codec, dynamicRange: dynamicRange))
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

    private func preferredEncoders(for codec: VideoCodec, dynamicRange: DynamicRange) -> [FFmpegVideoEncoder] {
        switch (dynamicRange, codec) {
        case (.hdr, .hevc):
            return [.libx265, .hevcVideoToolbox]
        case (.hdr, .h264):
            return []
        case (.sdr, .hevc):
            return [.hevcVideoToolbox, .libx265]
        case (.sdr, .h264):
            return [.h264VideoToolbox, .libx264]
        }
    }

    private func requiredEncoderDescription(codec: VideoCodec, dynamicRange: DynamicRange) -> String {
        switch (dynamicRange, codec) {
        case (.hdr, .hevc):
            return "HEVC Main10 encoder (libx265 or hevc_videotoolbox)"
        case (.hdr, .h264):
            return "HDR HEVC Main10 encoder (libx265 or hevc_videotoolbox)"
        case (.sdr, .hevc):
            return "HEVC encoder (hevc_videotoolbox or libx265)"
        case (.sdr, .h264):
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

    func backendSummary(codec: VideoCodec, dynamicRange: DynamicRange) -> String {
        var base = "FFmpeg \(dynamicRange == .hdr ? "HDR" : "SDR") backend [\(selectedBinary.source.rawValue)]"
        if let encoder = selectedCapabilities.preferredEncoder(for: codec, dynamicRange: dynamicRange) {
            base += " (encoder: \(encoder.rawValue))"
        }
        return base
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

struct FFmpegRenderPlan: Equatable, Sendable {
    let clips: [FFmpegRenderClip]
    let transitionDurationSeconds: Double
    let outputURL: URL
    let renderSize: CGSize
    let frameRate: Int
    let bitrateMode: BitrateMode
    let container: ContainerFormat
    let videoCodec: VideoCodec
    let dynamicRange: DynamicRange
}
