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

public enum ResolutionPolicy: Equatable, Codable, Sendable {
    case matchSourceMax
    case fixed1080p
    case fixed4K
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
        resolution: .matchSourceMax,
        dynamicRange: .sdr,
        hdrFFmpegBinaryMode: .autoSystemThenBundled,
        audioLayout: .stereo,
        bitrateMode: .balanced
    )

    public static let plexInfuseAppleTV4KDefault = ExportProfile(
        container: .mp4,
        videoCodec: .hevc,
        audioCodec: .aac,
        resolution: .matchSourceMax,
        dynamicRange: .hdr,
        hdrFFmpegBinaryMode: .autoSystemThenBundled,
        audioLayout: .stereo,
        bitrateMode: .balanced
    )
}
