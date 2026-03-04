import AVFoundation
import Core
import Foundation
import Photos

public enum PhotoKitDiscoveryError: LocalizedError {
    case unauthorized(PHAuthorizationStatus)

    public var errorDescription: String? {
        switch self {
        case let .unauthorized(status):
            return "Photo library access is not authorized (status: \(status.rawValue))."
        }
    }
}

public final class PhotoKitMediaDiscoveryService: @unchecked Sendable {
    public init() {}

    public func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    public func discover(monthYear: MonthYear, timeZone: TimeZone = .current) async throws -> [MediaItem] {
        let status = authorizationStatus()
        guard status == .authorized || status == .limited else {
            throw PhotoKitDiscoveryError.unauthorized(status)
        }

        let interval = monthYear.dateInterval(in: timeZone)
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.predicate = NSPredicate(
            format: "(mediaType == %d OR mediaType == %d) AND creationDate >= %@ AND creationDate < %@",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue,
            interval.start as NSDate,
            interval.end as NSDate
        )

        let result = PHAsset.fetchAssets(with: fetchOptions)
        var items: [MediaItem] = []
        items.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            let mediaType: MediaType = asset.mediaType == .video ? .video : .image
            let duration: CMTime? = mediaType == .video ? CMTime(seconds: asset.duration, preferredTimescale: 600) : nil
            let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier

            let item = MediaItem(
                id: asset.localIdentifier,
                type: mediaType,
                captureDate: asset.creationDate,
                duration: duration,
                pixelSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
                colorInfo: .unknown,
                locator: .photoAsset(localIdentifier: asset.localIdentifier),
                fileSizeBytes: nil,
                filename: filename
            )
            items.append(item)
        }

        return items
    }
}
