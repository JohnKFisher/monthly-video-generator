@testable import Core
import AVFoundation
import Foundation
import XCTest

final class MP4ChapterResolverTests: XCTestCase {
    func testResolveIncludesOpeningTitleAndCrossfadeAdjustedStartTimes() {
        let timeline = Timeline(
            segments: [
                TimelineSegment(
                    asset: .titleCard(
                        OpeningTitleCardDescriptor(
                            title: "March 2026",
                            contextLine: nil,
                            previewItems: [],
                            dateSpanText: nil,
                            variationSeed: 1
                        )
                    ),
                    duration: CMTime(seconds: 2.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "photo-1", type: .image, captureDate: makeDate(year: 2026, month: 3, day: 5))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "video-1", type: .video, captureDate: makeDate(year: 2026, month: 3, day: 5))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "photo-2", type: .image, captureDate: makeDate(year: 2026, month: 3, day: 6))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                )
            ],
            estimatedDuration: CMTime(seconds: 3.5, preferredTimescale: 600)
        )

        let chapters = MP4ChapterResolver.resolve(
            timeline: timeline,
            requestedTransitionDurationSeconds: 0.5,
            calendar: gmtCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(chapters.map(\.title), [
            "March 2026",
            "March 5 (1 photo, 1 video)",
            "March 6 (1 photo)"
        ])
        XCTAssertEqual(chapters[0].kind, .openingTitle)
        XCTAssertEqual(chapters[1].kind, .captureDay)
        XCTAssertEqual(chapters[0].startTimeSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(chapters[0].endTimeSeconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual(chapters[1].startTimeSeconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual(chapters[1].endTimeSeconds, 2.5, accuracy: 0.0001)
        XCTAssertEqual(chapters[2].startTimeSeconds, 2.5, accuracy: 0.0001)
        XCTAssertEqual(chapters[2].endTimeSeconds, 3.5, accuracy: 0.0001)
    }

    func testResolveOmitsZeroCountMediaTypes() {
        let timeline = Timeline(
            segments: [
                TimelineSegment(
                    asset: .media(makeItem(id: "photo-1", type: .image, captureDate: makeDate(year: 2026, month: 3, day: 5))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "video-1", type: .video, captureDate: makeDate(year: 2026, month: 3, day: 6))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                )
            ],
            estimatedDuration: CMTime(seconds: 2.0, preferredTimescale: 600)
        )

        let chapters = MP4ChapterResolver.resolve(
            timeline: timeline,
            requestedTransitionDurationSeconds: 0,
            calendar: gmtCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(chapters.map(\.title), [
            "March 5 (1 photo)",
            "March 6 (1 video)"
        ])
    }

    func testResolveIncludesYearOnlyWhenNeeded() {
        let singleYearTimeline = Timeline(
            segments: [
                TimelineSegment(
                    asset: .media(makeItem(id: "photo-1", type: .image, captureDate: makeDate(year: 2026, month: 3, day: 5))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "photo-2", type: .image, captureDate: makeDate(year: 2026, month: 4, day: 2))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                )
            ],
            estimatedDuration: CMTime(seconds: 2.0, preferredTimescale: 600)
        )
        let multiYearTimeline = Timeline(
            segments: [
                TimelineSegment(
                    asset: .media(makeItem(id: "photo-3", type: .image, captureDate: makeDate(year: 2025, month: 12, day: 31))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "photo-4", type: .image, captureDate: makeDate(year: 2026, month: 1, day: 1))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                )
            ],
            estimatedDuration: CMTime(seconds: 2.0, preferredTimescale: 600)
        )

        let singleYearChapters = MP4ChapterResolver.resolve(
            timeline: singleYearTimeline,
            requestedTransitionDurationSeconds: 0,
            calendar: gmtCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        )
        let multiYearChapters = MP4ChapterResolver.resolve(
            timeline: multiYearTimeline,
            requestedTransitionDurationSeconds: 0,
            calendar: gmtCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(singleYearChapters.map(\.title), [
            "March 5 (1 photo)",
            "April 2 (1 photo)"
        ])
        XCTAssertEqual(multiYearChapters.map(\.title), [
            "December 31, 2025 (1 photo)",
            "January 1, 2026 (1 photo)"
        ])
    }

    func testResolveMergesUndatedMediaIntoNearestDatedBuckets() {
        let timeline = Timeline(
            segments: [
                TimelineSegment(
                    asset: .media(makeItem(id: "leading-undated", type: .image, captureDate: nil)),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "dated-a", type: .image, captureDate: makeDate(year: 2026, month: 3, day: 5))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "interior-undated", type: .video, captureDate: nil)),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "dated-b", type: .video, captureDate: makeDate(year: 2026, month: 3, day: 6))),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "trailing-undated", type: .image, captureDate: nil)),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                )
            ],
            estimatedDuration: CMTime(seconds: 5.0, preferredTimescale: 600)
        )

        let chapters = MP4ChapterResolver.resolve(
            timeline: timeline,
            requestedTransitionDurationSeconds: 0,
            calendar: gmtCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(chapters.map(\.title), [
            "March 5 (2 photos, 1 video)",
            "March 6 (1 photo, 1 video)"
        ])
        XCTAssertEqual(chapters[0].startTimeSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(chapters[1].startTimeSeconds, 3, accuracy: 0.0001)
    }

    func testResolveReturnsOnlyOpeningTitleWhenAllMediaIsUndated() {
        let timeline = Timeline(
            segments: [
                TimelineSegment(
                    asset: .titleCard(
                        OpeningTitleCardDescriptor(
                            title: "March 2026",
                            contextLine: nil,
                            previewItems: [],
                            dateSpanText: nil,
                            variationSeed: 1
                        )
                    ),
                    duration: CMTime(seconds: 2.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "undated-1", type: .image, captureDate: nil)),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "undated-2", type: .video, captureDate: nil)),
                    duration: CMTime(seconds: 1.0, preferredTimescale: 600)
                )
            ],
            estimatedDuration: CMTime(seconds: 3.0, preferredTimescale: 600)
        )

        let chapters = MP4ChapterResolver.resolve(
            timeline: timeline,
            requestedTransitionDurationSeconds: 0.5,
            calendar: gmtCalendar(),
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(chapters.map(\.title), ["March 2026"])
        XCTAssertEqual(chapters[0].startTimeSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(chapters[0].endTimeSeconds, 3.0, accuracy: 0.0001)
    }

    func testEffectiveTransitionDurationClampsToHalfShortestSegment() {
        let timeline = Timeline(
            segments: [
                TimelineSegment(
                    asset: .media(makeItem(id: "short", type: .image, captureDate: makeDate(year: 2026, month: 3, day: 5))),
                    duration: CMTime(seconds: 0.4, preferredTimescale: 600)
                ),
                TimelineSegment(
                    asset: .media(makeItem(id: "long", type: .image, captureDate: makeDate(year: 2026, month: 3, day: 6))),
                    duration: CMTime(seconds: 2.0, preferredTimescale: 600)
                )
            ],
            estimatedDuration: CMTime(seconds: 2.2, preferredTimescale: 600)
        )

        XCTAssertEqual(
            MP4ChapterResolver.effectiveTransitionDurationSeconds(for: timeline, requestedSeconds: 1.0),
            0.2,
            accuracy: 0.0001
        )
    }

    private func makeItem(id: String, type: MediaType, captureDate: Date?) -> MediaItem {
        MediaItem(
            id: id,
            type: type,
            captureDate: captureDate,
            duration: type == .video ? CMTime(seconds: 1.0, preferredTimescale: 600) : nil,
            pixelSize: CGSize(width: 1920, height: 1080),
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/\(id)")),
            fileSizeBytes: 1_000,
            filename: "\(id).\(type == .video ? "mov" : "jpg")"
        )
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        let calendar = gmtCalendar()
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    private func gmtCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }
}
