import Foundation

package enum OpeningTitlePreviewSelector {
    package static func selectPreviewItems(
        from orderedItems: [MediaItem],
        variationSeed: UInt64,
        count: Int
    ) -> [MediaItem] {
        guard !orderedItems.isEmpty, count > 0 else {
            return []
        }

        if count <= orderedItems.count {
            return selectUniquePreviewItems(
                from: orderedItems,
                variationSeed: variationSeed,
                count: count
            )
        }

        let uniqueItems = selectUniquePreviewItems(
            from: orderedItems,
            variationSeed: variationSeed,
            count: orderedItems.count
        )
        let repeatedItems = selectRepeatedPreviewItems(
            from: uniqueItems,
            variationSeed: variationSeed,
            count: count - uniqueItems.count
        )

        var selectedItems = Array<MediaItem?>(repeating: nil, count: count)
        for (index, item) in uniqueItems.enumerated() {
            let slot = min(index * count / uniqueItems.count, count - 1)
            selectedItems[slot] = item
        }

        var repeatedIndex = 0
        for slot in 0..<selectedItems.count where selectedItems[slot] == nil {
            selectedItems[slot] = repeatedItems[repeatedIndex]
            repeatedIndex += 1
        }

        return selectedItems.compactMap { $0 }
    }

    private static func selectUniquePreviewItems(
        from orderedItems: [MediaItem],
        variationSeed: UInt64,
        count: Int
    ) -> [MediaItem] {
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

    private static func selectRepeatedPreviewItems(
        from orderedItems: [MediaItem],
        variationSeed: UInt64,
        count: Int
    ) -> [MediaItem] {
        guard !orderedItems.isEmpty, count > 0 else {
            return []
        }

        var generator = SeededRandomNumberGenerator(seed: variationSeed ^ 0x91E10DA5C79E7B1D)
        var repeatedItems: [MediaItem] = []
        repeatedItems.reserveCapacity(count)
        var shuffledItems = orderedItems

        while repeatedItems.count < count {
            shuffledItems.shuffle(using: &generator)
            for item in shuffledItems {
                repeatedItems.append(item)
                if repeatedItems.count == count {
                    break
                }
            }
        }

        return repeatedItems
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
