import Foundation

package enum OpeningTitlePreviewSelector {
    package static func selectPreviewItems(
        from orderedItems: [MediaItem],
        variationSeed: UInt64,
        count: Int
    ) -> [MediaItem] {
        guard !orderedItems.isEmpty else {
            return []
        }

        let previewCount = min(max(count, 1), orderedItems.count)
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
}

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
