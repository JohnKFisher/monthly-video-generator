import CoreGraphics
import Foundation

enum FFmpegBinarySource: String, Codable, Sendable {
    case system
    case bundled
}

enum FFmpegVideoEncoder: String, Codable, Sendable {
    case libx265
    case hevcVideoToolbox
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
    let hasLibx265: Bool
    let hasHEVCVideoToolbox: Bool

    var preferredEncoder: FFmpegVideoEncoder? {
        if hasLibx265 {
            return .libx265
        }
        if hasHEVCVideoToolbox {
            return .hevcVideoToolbox
        }
        return nil
    }

    var supportsQualityHDRPipeline: Bool {
        hasZscale && hasXfade && hasAcrossfade && preferredEncoder != nil
    }

    var missingRequiredCapabilities: [String] {
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
        if preferredEncoder == nil {
            missing.append("HEVC Main10 encoder (libx265 or hevc_videotoolbox)")
        }
        return missing
    }
}

struct FFmpegBinaryResolution: Equatable, Sendable {
    let selectedBinary: FFmpegBinary
    let selectedCapabilities: FFmpegCapabilities
    let systemCapabilities: FFmpegCapabilities?
    let bundledCapabilities: FFmpegCapabilities?
    let fallbackReason: String?

    var backendSummary: String {
        var base = "FFmpeg HDR backend [\(selectedBinary.source.rawValue)]"
        if let encoder = selectedCapabilities.preferredEncoder {
            base += " (encoder: \(encoder.rawValue))"
        }
        return base
    }
}

struct FFmpegHDRClip: Equatable, Sendable {
    let url: URL
    let durationSeconds: Double
    let includeAudio: Bool
    let hasAudioTrack: Bool
    let colorInfo: ColorInfo
    let sourceDescription: String
}

struct FFmpegHDRRenderPlan: Equatable, Sendable {
    let clips: [FFmpegHDRClip]
    let transitionDurationSeconds: Double
    let outputURL: URL
    let renderSize: CGSize
    let frameRate: Int
    let bitrateMode: BitrateMode
    let container: ContainerFormat
}
