import AVFoundation
import Foundation

public enum RenderChapterKind: String, Codable, Sendable {
    case openingTitle
    case captureDay
}

public struct RenderChapter: Equatable, Codable, Sendable {
    public let kind: RenderChapterKind
    public let title: String
    public let startTimeSeconds: Double
    public let endTimeSeconds: Double
    public let photoCount: Int
    public let videoCount: Int
    public let captureDayStart: Date?

    public init(
        kind: RenderChapterKind,
        title: String,
        startTimeSeconds: Double,
        endTimeSeconds: Double,
        photoCount: Int = 0,
        videoCount: Int = 0,
        captureDayStart: Date? = nil
    ) {
        self.kind = kind
        self.title = title
        self.startTimeSeconds = max(startTimeSeconds, 0)
        self.endTimeSeconds = max(endTimeSeconds, self.startTimeSeconds)
        self.photoCount = max(photoCount, 0)
        self.videoCount = max(videoCount, 0)
        self.captureDayStart = captureDayStart
    }
}

public enum MP4ChapterResolver {
    public static func resolve(
        timeline: Timeline,
        requestedTransitionDurationSeconds: Double,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [RenderChapter] {
        resolve(
            timeline: timeline,
            effectiveTransitionDurationSeconds: effectiveTransitionDurationSeconds(
                for: timeline,
                requestedSeconds: requestedTransitionDurationSeconds
            ),
            calendar: calendar,
            locale: locale
        )
    }

    public static func resolve(
        timeline: Timeline,
        effectiveTransitionDurationSeconds: Double,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [RenderChapter] {
        guard !timeline.segments.isEmpty else {
            return []
        }

        var resolvedCalendar = calendar
        resolvedCalendar.locale = locale
        let segmentStarts = segmentStartTimes(
            for: timeline.segments,
            transitionDurationSeconds: effectiveTransitionDurationSeconds
        )
        let totalDurationSeconds = totalDurationSeconds(
            for: timeline.segments,
            transitionDurationSeconds: effectiveTransitionDurationSeconds
        )

        var workingChapters: [WorkingChapter] = []
        if case let .titleCard(descriptor) = timeline.segments[0].asset {
            workingChapters.append(
                WorkingChapter(
                    kind: .openingTitle,
                    title: descriptor.resolvedTitle,
                    startTimeSeconds: 0,
                    photoCount: 0,
                    videoCount: 0,
                    captureDayStart: nil
                )
            )
        }

        let mediaSegments = timeline.segments.enumerated().compactMap { index, segment -> MediaSegment? in
            guard case let .media(item) = segment.asset else {
                return nil
            }
            return MediaSegment(
                item: item,
                startTimeSeconds: segmentStarts[index]
            )
        }

        let assignedDayStarts = assignedDayStarts(for: mediaSegments, calendar: resolvedCalendar)
        let orderedBuckets = makeOrderedBuckets(
            mediaSegments: mediaSegments,
            assignedDayStarts: assignedDayStarts
        )
        let includeYear = Set(orderedBuckets.map { resolvedCalendar.component(.year, from: $0.captureDayStart) }).count > 1

        for bucket in orderedBuckets {
            workingChapters.append(
                WorkingChapter(
                    kind: .captureDay,
                    title: formattedDayChapterTitle(
                        dayStart: bucket.captureDayStart,
                        photoCount: bucket.photoCount,
                        videoCount: bucket.videoCount,
                        includeYear: includeYear,
                        locale: locale,
                        timeZone: resolvedCalendar.timeZone
                    ),
                    startTimeSeconds: bucket.startTimeSeconds,
                    photoCount: bucket.photoCount,
                    videoCount: bucket.videoCount,
                    captureDayStart: bucket.captureDayStart
                )
            )
        }

        guard !workingChapters.isEmpty else {
            return []
        }

        return workingChapters.enumerated().map { index, chapter in
            let nextStart = index + 1 < workingChapters.count
                ? workingChapters[index + 1].startTimeSeconds
                : totalDurationSeconds
            let boundedEnd = min(max(nextStart, chapter.startTimeSeconds), totalDurationSeconds)
            return RenderChapter(
                kind: chapter.kind,
                title: chapter.title,
                startTimeSeconds: chapter.startTimeSeconds,
                endTimeSeconds: max(boundedEnd, chapter.startTimeSeconds),
                photoCount: chapter.photoCount,
                videoCount: chapter.videoCount,
                captureDayStart: chapter.captureDayStart
            )
        }
    }

    public static func effectiveTransitionDurationSeconds(
        for timeline: Timeline,
        requestedSeconds: Double
    ) -> Double {
        guard timeline.segments.count > 1, requestedSeconds > 0 else {
            return 0
        }

        let halfOfShortest = timeline.segments
            .map { max($0.duration.seconds, 0) / 2.0 }
            .min() ?? 0
        return min(max(requestedSeconds, 0), max(halfOfShortest, 0))
    }

    private struct MediaSegment {
        let item: MediaItem
        let startTimeSeconds: Double
    }

    private struct WorkingBucket {
        let captureDayStart: Date
        var startTimeSeconds: Double
        var photoCount: Int
        var videoCount: Int
    }

    private struct WorkingChapter {
        let kind: RenderChapterKind
        let title: String
        let startTimeSeconds: Double
        let photoCount: Int
        let videoCount: Int
        let captureDayStart: Date?
    }

    private static func segmentStartTimes(
        for segments: [TimelineSegment],
        transitionDurationSeconds: Double
    ) -> [Double] {
        var starts: [Double] = []
        starts.reserveCapacity(segments.count)

        var cumulativeDuration = 0.0
        for (index, segment) in segments.enumerated() {
            let start = max(cumulativeDuration - transitionDurationSeconds * Double(index), 0)
            starts.append(start)
            cumulativeDuration += max(segment.duration.seconds, 0)
        }
        return starts
    }

    private static func totalDurationSeconds(
        for segments: [TimelineSegment],
        transitionDurationSeconds: Double
    ) -> Double {
        let total = segments.reduce(0.0) { partial, segment in
            partial + max(segment.duration.seconds, 0)
        }
        let overlap = transitionDurationSeconds * Double(max(segments.count - 1, 0))
        return max(total - overlap, 0)
    }

    private static func assignedDayStarts(
        for mediaSegments: [MediaSegment],
        calendar: Calendar
    ) -> [Date?] {
        let ownDayStarts = mediaSegments.map { mediaSegment in
            mediaSegment.item.captureDate.map { calendar.startOfDay(for: $0) }
        }

        guard ownDayStarts.contains(where: { $0 != nil }) else {
            return Array(repeating: nil, count: mediaSegments.count)
        }

        var previousAnchors: [Date?] = Array(repeating: nil, count: mediaSegments.count)
        var nextAnchors: [Date?] = Array(repeating: nil, count: mediaSegments.count)
        var runningPrevious: Date?
        for index in ownDayStarts.indices {
            if let ownDayStart = ownDayStarts[index] {
                runningPrevious = ownDayStart
            }
            previousAnchors[index] = runningPrevious
        }

        var runningNext: Date?
        for index in ownDayStarts.indices.reversed() {
            if let ownDayStart = ownDayStarts[index] {
                runningNext = ownDayStart
            }
            nextAnchors[index] = runningNext
        }

        return ownDayStarts.enumerated().map { index, ownDayStart in
            if let ownDayStart {
                return ownDayStart
            }
            if let previousAnchor = previousAnchors[index] {
                return previousAnchor
            }
            return nextAnchors[index]
        }
    }

    private static func makeOrderedBuckets(
        mediaSegments: [MediaSegment],
        assignedDayStarts: [Date?]
    ) -> [WorkingBucket] {
        var bucketsByDay: [Date: WorkingBucket] = [:]
        var orderedDays: [Date] = []

        for (index, mediaSegment) in mediaSegments.enumerated() {
            guard let assignedDayStart = assignedDayStarts[index] else {
                continue
            }

            if bucketsByDay[assignedDayStart] == nil {
                orderedDays.append(assignedDayStart)
                bucketsByDay[assignedDayStart] = WorkingBucket(
                    captureDayStart: assignedDayStart,
                    startTimeSeconds: mediaSegment.startTimeSeconds,
                    photoCount: 0,
                    videoCount: 0
                )
            }

            guard var bucket = bucketsByDay[assignedDayStart] else {
                continue
            }
            bucket.startTimeSeconds = min(bucket.startTimeSeconds, mediaSegment.startTimeSeconds)
            switch mediaSegment.item.type {
            case .image:
                bucket.photoCount += 1
            case .video:
                bucket.videoCount += 1
            }
            bucketsByDay[assignedDayStart] = bucket
        }

        return orderedDays.compactMap { bucketsByDay[$0] }
    }

    private static func formattedDayChapterTitle(
        dayStart: Date,
        photoCount: Int,
        videoCount: Int,
        includeYear: Bool,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(includeYear ? "MMMM d yyyy" : "MMMM d")
        let dateLabel = formatter.string(from: dayStart)

        var countParts: [String] = []
        if photoCount > 0 {
            countParts.append("\(photoCount) \(photoCount == 1 ? "photo" : "photos")")
        }
        if videoCount > 0 {
            countParts.append("\(videoCount) \(videoCount == 1 ? "video" : "videos")")
        }

        guard !countParts.isEmpty else {
            return dateLabel
        }
        return "\(dateLabel) (\(countParts.joined(separator: ", ")))"
    }
}
