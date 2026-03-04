import AVFoundation
import Foundation

public final class TimelineBuilder {
    public init() {}

    public func buildTimeline(items: [MediaItem], ordering: OrderingRule, style: StyleProfile) -> Timeline {
        let ordered = MediaSorting.sort(items, by: ordering)
        var segments: [TimelineSegment] = []

        if let openingTitle = style.openingTitle, !openingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           style.titleDurationSeconds > 0 {
            let duration = CMTime(seconds: style.titleDurationSeconds, preferredTimescale: 600)
            segments.append(TimelineSegment(asset: .titleCard(openingTitle), duration: duration))
        }

        for item in ordered {
            let duration: CMTime
            switch item.type {
            case .image:
                duration = CMTime(seconds: style.stillImageDurationSeconds, preferredTimescale: 600)
            case .video:
                duration = item.duration ?? CMTime(seconds: 0, preferredTimescale: 600)
            }

            guard duration.seconds > 0 else {
                continue
            }

            segments.append(TimelineSegment(asset: .media(item), duration: duration))
        }

        let totalDuration = calculateEstimatedDuration(segments: segments, crossfadeSeconds: style.crossfadeDurationSeconds)
        return Timeline(segments: segments, estimatedDuration: totalDuration)
    }

    private func calculateEstimatedDuration(segments: [TimelineSegment], crossfadeSeconds: Double) -> CMTime {
        guard !segments.isEmpty else {
            return .zero
        }

        let total = segments.reduce(CMTime.zero) { $0 + $1.duration }
        guard crossfadeSeconds > 0, segments.count > 1 else {
            return total
        }

        let transitions = segments.count - 1
        let transitionReduction = CMTime(seconds: Double(transitions) * crossfadeSeconds, preferredTimescale: 600)
        let reduced = total - transitionReduction
        return reduced > .zero ? reduced : .zero
    }
}
