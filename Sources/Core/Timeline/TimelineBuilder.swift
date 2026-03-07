import AVFoundation
import Foundation

public final class TimelineBuilder {
    public typealias VariationSeedGenerator = @Sendable () -> UInt64

    private struct SeededRandomNumberGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x4D595DF4D0F33173 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }

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
        orderedItems: [MediaItem],
        source: MediaSource?,
        monthYear: MonthYear?
    ) -> OpeningTitleCardDescriptor {
        let variationSeed = variationSeedGenerator()
        let dateSpanText = formattedDateSpan(for: orderedItems)
        return OpeningTitleCardDescriptor(
            title: title,
            contextLine: resolvedContextLine(
                title: title,
                source: source,
                monthYear: monthYear,
                dateSpanText: dateSpanText
            ),
            previewItems: selectedPreviewItems(from: orderedItems, variationSeed: variationSeed),
            dateSpanText: dateSpanText,
            variationSeed: variationSeed
        )
    }

    private func resolvedContextLine(
        title: String,
        source: MediaSource?,
        monthYear: MonthYear?,
        dateSpanText: String?
    ) -> String? {
        if case let .photosLibrary(scope)? = source {
            switch scope {
            case let .album(_, title: albumTitle):
                if let albumTitle = trimmed(albumTitle), !matches(albumTitle, title) {
                    return albumTitle
                }
            case let .entireLibrary(sourceMonthYear):
                let label = sourceMonthYear.displayLabel
                if !matches(label, title) {
                    return label
                }
            }
        }

        if let monthYear {
            let label = monthYear.displayLabel
            if !matches(label, title) {
                return label
            }
        }

        if let dateSpanText = trimmed(dateSpanText), !matches(dateSpanText, title) {
            return dateSpanText
        }

        return nil
    }

    private func selectedPreviewItems(from orderedItems: [MediaItem], variationSeed: UInt64) -> [MediaItem] {
        guard !orderedItems.isEmpty else {
            return []
        }

        let previewCount = min(6, orderedItems.count)
        var generator = SeededRandomNumberGenerator(seed: variationSeed ^ 0xA5A55A5ADEADBEEF)
        var selectedItems: [MediaItem] = []
        selectedItems.reserveCapacity(previewCount)

        for bucketIndex in 0..<previewCount {
            let start = bucketIndex * orderedItems.count / previewCount
            let end = max(start + 1, (bucketIndex + 1) * orderedItems.count / previewCount)
            let clampedEnd = min(end, orderedItems.count)
            let selectedIndex = Int.random(in: start..<clampedEnd, using: &generator)
            selectedItems.append(orderedItems[selectedIndex])
        }

        return selectedItems
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

    private func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ==
            rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
