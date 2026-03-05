import Foundation

public enum ContainerFormat: String, CaseIterable, Codable, Sendable {
    case mov
    case mp4

    public var fileExtension: String {
        rawValue
    }
}

public enum VideoCodec: String, CaseIterable, Codable, Sendable {
    case hevc
    case h264
}

public enum AudioCodec: String, CaseIterable, Codable, Sendable {
    case aac
}

public enum ResolutionPolicy: String, CaseIterable, Codable, Sendable {
    case fixed720p
    case matchSourceMax
    case fixed1080p
    case fixed4K
    case smart

    public static var allCases: [ResolutionPolicy] {
        [.fixed720p, .fixed1080p, .fixed4K, .smart]
    }

    public var normalized: ResolutionPolicy {
        switch self {
        case .matchSourceMax:
            return .smart
        case .fixed720p, .fixed1080p, .fixed4K, .smart:
            return self
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.fixed720p.rawValue:
            self = .fixed720p
        case Self.fixed1080p.rawValue:
            self = .fixed1080p
        case Self.fixed4K.rawValue:
            self = .fixed4K
        case Self.smart.rawValue, Self.matchSourceMax.rawValue:
            self = .smart
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported resolution policy: \(rawValue)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(normalized.rawValue)
    }
}

public enum DynamicRange: String, CaseIterable, Codable, Sendable {
    case sdr
    case hdr
}

public enum HDRFFmpegBinaryMode: String, CaseIterable, Codable, Sendable {
    case autoSystemThenBundled
    case systemOnly
    case bundledOnly
}

public enum AudioLayout: String, CaseIterable, Codable, Sendable {
    case stereo
    case surround51
}

public enum BitrateMode: String, CaseIterable, Codable, Sendable {
    case balanced
    case qualityFirst
    case sizeFirst
}

public struct ExportProfile: Equatable, Codable, Sendable {
    public let container: ContainerFormat
    public let videoCodec: VideoCodec
    public let audioCodec: AudioCodec
    public let resolution: ResolutionPolicy
    public let dynamicRange: DynamicRange
    public let hdrFFmpegBinaryMode: HDRFFmpegBinaryMode
    public let audioLayout: AudioLayout
    public let bitrateMode: BitrateMode

    public init(
        container: ContainerFormat,
        videoCodec: VideoCodec,
        audioCodec: AudioCodec,
        resolution: ResolutionPolicy,
        dynamicRange: DynamicRange,
        hdrFFmpegBinaryMode: HDRFFmpegBinaryMode = .autoSystemThenBundled,
        audioLayout: AudioLayout,
        bitrateMode: BitrateMode
    ) {
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.resolution = resolution
        self.dynamicRange = dynamicRange
        self.hdrFFmpegBinaryMode = hdrFFmpegBinaryMode
        self.audioLayout = audioLayout
        self.bitrateMode = bitrateMode
    }

    public static let balancedDefault = ExportProfile(
        container: .mov,
        videoCodec: .hevc,
        audioCodec: .aac,
        resolution: .smart,
        dynamicRange: .sdr,
        hdrFFmpegBinaryMode: .autoSystemThenBundled,
        audioLayout: .stereo,
        bitrateMode: .balanced
    )

    public static let plexInfuseAppleTV4KDefault = ExportProfile(
        container: .mp4,
        videoCodec: .hevc,
        audioCodec: .aac,
        resolution: .smart,
        dynamicRange: .hdr,
        hdrFFmpegBinaryMode: .autoSystemThenBundled,
        audioLayout: .stereo,
        bitrateMode: .balanced
    )
}
