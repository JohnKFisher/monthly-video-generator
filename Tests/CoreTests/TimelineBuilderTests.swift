import AVFoundation
import Core
import XCTest

final class TimelineBuilderTests: XCTestCase {
    func testDeterministicOrderingWithMatchingCaptureDates() {
        let capture = Date(timeIntervalSince1970: 1_700_000_000)
        let itemA = MediaItem(
            id: "b",
            type: .image,
            captureDate: capture,
            duration: nil,
            pixelSize: CGSize(width: 100, height: 100),
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/b.jpg")),
            fileSizeBytes: 40,
            filename: "b.jpg"
        )
        let itemB = MediaItem(
            id: "a",
            type: .image,
            captureDate: capture,
            duration: nil,
            pixelSize: CGSize(width: 100, height: 100),
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/a.jpg")),
            fileSizeBytes: 20,
            filename: "a.jpg"
        )

        let timeline = TimelineBuilder().buildTimeline(
            items: [itemA, itemB],
            ordering: .captureDateAscendingStable,
            style: .stageOneDefault
        )

        XCTAssertEqual(timeline.segments.count, 2)
        guard case let .media(firstItem) = timeline.segments[0].asset else {
            XCTFail("Expected first segment to be media")
            return
        }
        XCTAssertEqual(firstItem.filename, "a.jpg")
    }

    func testEstimatedDurationAppliesCrossfadeReduction() {
        let item1 = MediaItem(
            id: "1",
            type: .image,
            captureDate: Date(),
            duration: nil,
            pixelSize: CGSize(width: 100, height: 100),
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/1.jpg")),
            fileSizeBytes: 10,
            filename: "1.jpg"
        )
        let item2 = MediaItem(
            id: "2",
            type: .image,
            captureDate: Date(),
            duration: nil,
            pixelSize: CGSize(width: 100, height: 100),
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/2.jpg")),
            fileSizeBytes: 10,
            filename: "2.jpg"
        )

        let style = StyleProfile(openingTitle: nil, titleDurationSeconds: 0, crossfadeDurationSeconds: 0.5, stillImageDurationSeconds: 3)
        let timeline = TimelineBuilder().buildTimeline(items: [item1, item2], ordering: .captureDateAscendingStable, style: style)

        XCTAssertEqual(timeline.estimatedDuration.seconds, 5.5, accuracy: 0.05)
    }
}
