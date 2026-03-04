import Foundation

public enum MediaSorting {
    public static func sort(_ items: [MediaItem], by ordering: OrderingRule) -> [MediaItem] {
        switch ordering {
        case .captureDateAscendingStable:
            return items.sorted { lhs, rhs in
                let lhsDate = lhs.captureDate ?? Date.distantFuture
                let rhsDate = rhs.captureDate ?? Date.distantFuture
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                if lhs.filename.lowercased() != rhs.filename.lowercased() {
                    return lhs.filename.lowercased() < rhs.filename.lowercased()
                }
                let lhsSize = lhs.fileSizeBytes ?? Int64.max
                let rhsSize = rhs.fileSizeBytes ?? Int64.max
                if lhsSize != rhsSize {
                    return lhsSize < rhsSize
                }
                return lhs.id < rhs.id
            }
        }
    }
}
