import AVFoundation
import Foundation

public enum TimelineAsset: Equatable, @unchecked Sendable {
    case media(MediaItem)
    case titleCard(String)
}

public struct TimelineSegment: Equatable, @unchecked Sendable {
    public let asset: TimelineAsset
    public let duration: CMTime

    public init(asset: TimelineAsset, duration: CMTime) {
        self.asset = asset
        self.duration = duration
    }
}

public struct Timeline: Equatable, @unchecked Sendable {
    public let segments: [TimelineSegment]
    public let estimatedDuration: CMTime

    public init(segments: [TimelineSegment], estimatedDuration: CMTime) {
        self.segments = segments
        self.estimatedDuration = estimatedDuration
    }

    public var isEmpty: Bool {
        segments.isEmpty
    }
}
