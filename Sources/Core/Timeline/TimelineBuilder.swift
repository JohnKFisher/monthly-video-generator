import AVFoundation
import Foundation

public final class TimelineBuilder {
    public typealias VariationSeedGenerator = @Sendable () -> UInt64

    private let variationSeedGenerator: VariationSeedGenerator

    public init(variationSeedGenerator: @escaping VariationSeedGenerator = {
        UInt64.random(in: UInt64.min...UInt64.max)
    }) {
        self.variationSeedGenerator = variationSeedGenerator
    }

    public func buildTimeline(items: [MediaItem], request: RenderRequest) -> Timeline {
        buildTimeline(
            items: items,
            ordering: request.ordering,
            style: request.style,
            source: request.source,
            monthYear: request.monthYear
        )
    }

    public func buildTimeline(
        items: [MediaItem],
        ordering: OrderingRule,
        style: StyleProfile,
        source: MediaSource? = nil,
        monthYear: MonthYear? = nil
    ) -> Timeline {
        let ordered = MediaSorting.sort(items, by: ordering)
        var segments: [TimelineSegment] = []

        if let openingTitle = style.openingTitle,
           !openingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           style.titleDurationSeconds > 0 {
            let duration = CMTime(seconds: style.titleDurationSeconds, preferredTimescale: 600)
            let descriptor = buildOpeningTitleCardDescriptor(
                title: openingTitle,
                style: style,
                orderedItems: ordered,
                source: source,
                monthYear: monthYear
            )
            segments.append(TimelineSegment(asset: .titleCard(descriptor), duration: duration))
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

    private func buildOpeningTitleCardDescriptor(
        title: String,
        style: StyleProfile,
        orderedItems: [MediaItem],
        source: MediaSource?,
        monthYear: MonthYear?
    ) -> OpeningTitleCardDescriptor {
        let variationSeed = variationSeedGenerator()
        let dateSpanText = formattedDateSpan(for: orderedItems)
        let resolvedContextLine: String?
        switch style.openingTitleCaptionMode {
        case .automatic:
            resolvedContextLine = OpeningTitleCardContextResolver.resolveAutomaticContextLine(
                title: title,
                source: source,
                monthYear: monthYear,
                dateSpanText: dateSpanText
            )
        case .custom:
            resolvedContextLine = style.openingTitleCaptionText
        }
        return OpeningTitleCardDescriptor(
            title: title,
            contextLine: resolvedContextLine,
            previewItems: OpeningTitlePreviewSelector.selectPreviewItems(
                from: orderedItems,
                variationSeed: variationSeed,
                count: 6
            ),
            dateSpanText: dateSpanText,
            variationSeed: variationSeed,
            contextLineMode: style.openingTitleCaptionMode
        )
    }

    private func formattedDateSpan(for items: [MediaItem]) -> String? {
        let datedItems = items.compactMap(\.captureDate).sorted()
        guard let start = datedItems.first, let end = datedItems.last else {
            return nil
        }

        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            return singleDateFormatter.string(from: start)
        }

        if calendar.isDate(start, equalTo: end, toGranularity: .year) {
            if calendar.isDate(start, equalTo: end, toGranularity: .month) {
                return "\(monthDayFormatter.string(from: start))-\(dayFormatter.string(from: end)), \(yearFormatter.string(from: end))"
            }
            return "\(monthDayFormatter.string(from: start)) - \(monthDayFormatter.string(from: end)), \(yearFormatter.string(from: end))"
        }

        return "\(singleDateFormatter.string(from: start)) - \(singleDateFormatter.string(from: end))"
    }

    private var singleDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM d, yyyy")
        return formatter
    }

    private var monthDayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter
    }

    private var yearFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("yyyy")
        return formatter
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
