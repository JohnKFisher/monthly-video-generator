import AVFoundation
import Core
import XCTest

final class TimelineBuilderTests: XCTestCase {
    func testDeterministicOrderingWithMatchingCaptureDates() {
        let capture = Date(timeIntervalSince1970: 1_700_000_000)
        let itemA = makeImageItem(id: "b", filename: "b.jpg", captureDate: capture, fileSizeBytes: 40)
        let itemB = makeImageItem(id: "a", filename: "a.jpg", captureDate: capture, fileSizeBytes: 20)

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
        let item1 = makeImageItem(id: "1", filename: "1.jpg")
        let item2 = makeImageItem(id: "2", filename: "2.jpg")

        let style = StyleProfile(openingTitle: nil, titleDurationSeconds: 0, crossfadeDurationSeconds: 0.5, stillImageDurationSeconds: 3)
        let timeline = TimelineBuilder().buildTimeline(items: [item1, item2], ordering: .captureDateAscendingStable, style: style)

        XCTAssertEqual(timeline.estimatedDuration.seconds, 5.5, accuracy: 0.05)
    }

    func testOpeningTitleDescriptorCapsPreviewsAndUsesInjectedSeed() {
        let items = (0..<8).map { index in
            makeImageItem(
                id: "item-\(index)",
                filename: "item-\(index).jpg",
                captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 86_400)),
                fileSizeBytes: Int64(index + 1)
            )
        }
        let style = StyleProfile(openingTitle: "Summer", titleDurationSeconds: 2.5, crossfadeDurationSeconds: 0.75, stillImageDurationSeconds: 3)
        let builder = TimelineBuilder(variationSeedGenerator: { 42 })

        let timeline = builder.buildTimeline(
            items: items,
            ordering: .captureDateAscendingStable,
            style: style,
            source: .folder(path: URL(fileURLWithPath: "/tmp/input"), recursive: true)
        )

        guard case let .titleCard(descriptor) = timeline.segments.first?.asset else {
            XCTFail("Expected title-card descriptor")
            return
        }

        XCTAssertEqual(descriptor.variationSeed, 42)
        XCTAssertEqual(descriptor.previewItems.count, 6)

        let repeatedTimeline = builder.buildTimeline(
            items: items,
            ordering: .captureDateAscendingStable,
            style: style,
            source: .folder(path: URL(fileURLWithPath: "/tmp/input"), recursive: true)
        )
        guard case let .titleCard(repeatedDescriptor) = repeatedTimeline.segments.first?.asset else {
            XCTFail("Expected repeated title-card descriptor")
            return
        }

        XCTAssertEqual(
            descriptor.previewItems.map(\.filename),
            repeatedDescriptor.previewItems.map(\.filename)
        )
    }

    func testOpeningTitleDescriptorUsesAlbumTitleAsContextLine() {
        let items = [
            makeImageItem(id: "1", filename: "1.jpg", captureDate: Date(timeIntervalSince1970: 1_700_000_000), fileSizeBytes: 100)
        ]
        let style = StyleProfile(openingTitle: "Summer 2026", titleDurationSeconds: 2.5, crossfadeDurationSeconds: 0.75, stillImageDurationSeconds: 3)

        let timeline = TimelineBuilder(variationSeedGenerator: { 7 }).buildTimeline(
            items: items,
            ordering: .captureDateAscendingStable,
            style: style,
            source: .photosLibrary(scope: .album(localIdentifier: "album-1", title: "Cape Cod"))
        )

        guard case let .titleCard(descriptor) = timeline.segments.first?.asset else {
            XCTFail("Expected title-card descriptor")
            return
        }

        XCTAssertEqual(descriptor.contextLine, "Cape Cod")
    }

    func testCustomOpeningTitleCaptionUsesUserTextAndCustomTitleDuration() {
        let items = [
            makeImageItem(id: "1", filename: "1.jpg", captureDate: Date(timeIntervalSince1970: 1_700_000_000), fileSizeBytes: 100)
        ]
        let style = StyleProfile(
            openingTitle: "Summer 2026",
            titleDurationSeconds: 4.5,
            crossfadeDurationSeconds: 0.75,
            stillImageDurationSeconds: 3,
            openingTitleCaptionMode: .custom,
            openingTitleCaptionText: "Cape Cod at dusk"
        )

        let timeline = TimelineBuilder(variationSeedGenerator: { 11 }).buildTimeline(
            items: items,
            ordering: .captureDateAscendingStable,
            style: style,
            source: .photosLibrary(scope: .album(localIdentifier: "album-1", title: "Cape Cod"))
        )

        guard let firstSegment = timeline.segments.first else {
            XCTFail("Expected title-card segment")
            return
        }
        XCTAssertEqual(firstSegment.duration.seconds, 4.5, accuracy: 0.0001)
        guard case let .titleCard(descriptor) = firstSegment.asset else {
            XCTFail("Expected title-card descriptor")
            return
        }

        XCTAssertEqual(descriptor.contextLineMode, .custom)
        XCTAssertEqual(descriptor.contextLine, "Cape Cod at dusk")
        XCTAssertEqual(descriptor.resolvedContextLine, "Cape Cod at dusk")
    }

    func testBlankCustomOpeningTitleCaptionHidesCaption() {
        let items = [
            makeImageItem(id: "1", filename: "1.jpg", captureDate: Date(timeIntervalSince1970: 1_700_000_000), fileSizeBytes: 100)
        ]
        let style = StyleProfile(
            openingTitle: "Summer 2026",
            titleDurationSeconds: 2.5,
            crossfadeDurationSeconds: 0.75,
            stillImageDurationSeconds: 3,
            openingTitleCaptionMode: .custom,
            openingTitleCaptionText: "   "
        )

        let timeline = TimelineBuilder(variationSeedGenerator: { 12 }).buildTimeline(
            items: items,
            ordering: .captureDateAscendingStable,
            style: style,
            source: .photosLibrary(scope: .album(localIdentifier: "album-1", title: "Cape Cod"))
        )

        guard case let .titleCard(descriptor) = timeline.segments.first?.asset else {
            XCTFail("Expected title-card descriptor")
            return
        }

        XCTAssertNil(descriptor.resolvedContextLine)
        XCTAssertNil(descriptor.displayContextLine)
    }

    private func makeImageItem(
        id: String,
        filename: String,
        captureDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        fileSizeBytes: Int64 = 10
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: .image,
            captureDate: captureDate,
            duration: nil,
            pixelSize: CGSize(width: 100, height: 100),
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/\(filename)")),
            fileSizeBytes: fileSizeBytes,
            filename: filename
        )
    }
}
