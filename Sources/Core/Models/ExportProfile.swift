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

public enum FrameRatePolicy: String, CaseIterable, Codable, Sendable {
    case fps30
    case fps60
    case smart
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
    case mono
    case stereo
    case surround51
    case smart

    public static var allCases: [AudioLayout] {
        [.mono, .stereo, .surround51, .smart]
    }

    public var displayLabel: String {
        switch self {
        case .mono:
            return "Mono"
        case .stereo:
            return "Stereo"
        case .surround51:
            return "5.1"
        case .smart:
            return "Smart"
        }
    }

    public var testingToken: String {
        displayLabel
    }

    public var outputChannelCount: Int? {
        switch self {
        case .mono:
            return 1
        case .stereo:
            return 2
        case .surround51:
            return 6
        case .smart:
            return nil
        }
    }

    public var ffmpegChannelLayout: String? {
        switch self {
        case .mono:
            return "mono"
        case .stereo:
            return "stereo"
        case .surround51:
            return "5.1"
        case .smart:
            return nil
        }
    }

    public var aacBitrate: Int? {
        switch self {
        case .mono:
            return 96_000
        case .stereo:
            return 192_000
        case .surround51:
            return 384_000
        case .smart:
            return nil
        }
    }

    public var isResolved: Bool {
        self != .smart
    }
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
    public let frameRate: FrameRatePolicy
    public let resolution: ResolutionPolicy
    public let dynamicRange: DynamicRange
    public let hdrFFmpegBinaryMode: HDRFFmpegBinaryMode
    public let audioLayout: AudioLayout
    public let bitrateMode: BitrateMode

    public init(
        container: ContainerFormat,
        videoCodec: VideoCodec,
        audioCodec: AudioCodec,
        frameRate: FrameRatePolicy = .smart,
        resolution: ResolutionPolicy,
        dynamicRange: DynamicRange,
        hdrFFmpegBinaryMode: HDRFFmpegBinaryMode = .autoSystemThenBundled,
        audioLayout: AudioLayout,
        bitrateMode: BitrateMode
    ) {
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.frameRate = frameRate
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
        frameRate: .smart,
        resolution: .smart,
        dynamicRange: .sdr,
        hdrFFmpegBinaryMode: .autoSystemThenBundled,
        audioLayout: .smart,
        bitrateMode: .balanced
    )

    public static let plexInfuseAppleTV4KDefault = ExportProfile(
        container: .mp4,
        videoCodec: .hevc,
        audioCodec: .aac,
        frameRate: .smart,
        resolution: .smart,
        dynamicRange: .hdr,
        hdrFFmpegBinaryMode: .autoSystemThenBundled,
        audioLayout: .smart,
        bitrateMode: .balanced
    )

    private enum CodingKeys: String, CodingKey {
        case container
        case videoCodec
        case audioCodec
        case frameRate
        case resolution
        case dynamicRange
        case hdrFFmpegBinaryMode
        case audioLayout
        case bitrateMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.container = try container.decode(ContainerFormat.self, forKey: .container)
        self.videoCodec = try container.decode(VideoCodec.self, forKey: .videoCodec)
        self.audioCodec = try container.decode(AudioCodec.self, forKey: .audioCodec)
        self.frameRate = try container.decodeIfPresent(FrameRatePolicy.self, forKey: .frameRate) ?? .smart
        self.resolution = try container.decode(ResolutionPolicy.self, forKey: .resolution)
        self.dynamicRange = try container.decode(DynamicRange.self, forKey: .dynamicRange)
        self.hdrFFmpegBinaryMode = try container.decodeIfPresent(HDRFFmpegBinaryMode.self, forKey: .hdrFFmpegBinaryMode) ?? .autoSystemThenBundled
        self.audioLayout = try container.decode(AudioLayout.self, forKey: .audioLayout)
        self.bitrateMode = try container.decode(BitrateMode.self, forKey: .bitrateMode)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.container, forKey: .container)
        try container.encode(self.videoCodec, forKey: .videoCodec)
        try container.encode(self.audioCodec, forKey: .audioCodec)
        try container.encode(self.frameRate, forKey: .frameRate)
        try container.encode(self.resolution, forKey: .resolution)
        try container.encode(self.dynamicRange, forKey: .dynamicRange)
        try container.encode(self.hdrFFmpegBinaryMode, forKey: .hdrFFmpegBinaryMode)
        try container.encode(self.audioLayout, forKey: .audioLayout)
        try container.encode(self.bitrateMode, forKey: .bitrateMode)
    }
}
