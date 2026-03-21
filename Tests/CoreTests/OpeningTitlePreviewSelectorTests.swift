import XCTest
@testable import Core

final class OpeningTitlePreviewSelectorTests: XCTestCase {
    func testSelectPreviewItemsReturnsUniqueItemsWhenSourceBatchIsLargeEnough() {
        let items = makeItems(count: 12)

        let selected = OpeningTitlePreviewSelector.selectPreviewItems(
            from: items,
            variationSeed: 42,
            count: 10
        )

        XCTAssertEqual(selected.count, 10)
        XCTAssertEqual(Set(selected.map(\.id)).count, 10)
    }

    func testSelectPreviewItemsFillsRequestedCountByRepeatingOnlyWhenNeeded() {
        let items = makeItems(count: 3)

        let selected = OpeningTitlePreviewSelector.selectPreviewItems(
            from: items,
            variationSeed: 42,
            count: 10
        )

        XCTAssertEqual(selected.count, 10)
        XCTAssertEqual(Set(selected.map(\.id)), Set(items.map(\.id)))
        XCTAssertEqual(Set(selected.map(\.id)).count, 3)
    }

    func testSelectPreviewItemsReturnsEmptyForEmptyInput() {
        let selected = OpeningTitlePreviewSelector.selectPreviewItems(
            from: [],
            variationSeed: 42,
            count: 10
        )

        XCTAssertTrue(selected.isEmpty)
    }

    private func makeItems(count: Int) -> [MediaItem] {
        (0..<count).map { index in
            MediaItem(
                id: "item-\(index)",
                type: .image,
                captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60)),
                duration: nil,
                pixelSize: CGSize(width: 1920, height: 1080),
                colorInfo: .unknown,
                locator: .file(URL(fileURLWithPath: "/tmp/item-\(index).jpg")),
                fileSizeBytes: Int64(index + 1),
                filename: "item-\(index).jpg"
            )
        }
    }
}
