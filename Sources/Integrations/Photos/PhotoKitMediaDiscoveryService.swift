import AVFoundation
import Core
import Foundation
import Photos

public struct PhotoAlbumSummary: Equatable, Sendable, Identifiable {
    public let localIdentifier: String
    public let title: String
    public let assetCount: Int

    public var id: String {
        localIdentifier
    }

    public init(localIdentifier: String, title: String, assetCount: Int) {
        self.localIdentifier = localIdentifier
        self.title = title
        self.assetCount = assetCount
    }

    public var displayLabel: String {
        "\(title) (\(assetCount))"
    }
}

public enum PhotoKitDiscoveryError: LocalizedError {
    case unauthorized(PHAuthorizationStatus)
    case albumNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .unauthorized(status):
            return "Photo library access is not authorized (status: \(status.rawValue))."
        case let .albumNotFound(localIdentifier):
            return "The selected Photos album could not be found (\(localIdentifier))."
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
        try ensureAuthorized()

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
        return mediaItems(from: result)
    }

    public func discover(albumLocalIdentifier: String) async throws -> [MediaItem] {
        try ensureAuthorized()
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumLocalIdentifier],
            options: nil
        )
        guard let collection = collections.firstObject else {
            throw PhotoKitDiscoveryError.albumNotFound(albumLocalIdentifier)
        }

        let result = PHAsset.fetchAssets(in: collection, options: mediaAssetFetchOptions())
        return mediaItems(from: result)
    }

    public func discoverAlbums() async throws -> [PhotoAlbumSummary] {
        try ensureAuthorized()

        let collectionFetchOptions = PHFetchOptions()
        collectionFetchOptions.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]

        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: collectionFetchOptions
        )
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: collectionFetchOptions
        )

        var seenIdentifiers: Set<String> = []
        var albums: [PhotoAlbumSummary] = []
        let mediaOptions = mediaAssetFetchOptions()

        let appendAlbums: (PHFetchResult<PHAssetCollection>) -> Void = { collections in
            collections.enumerateObjects { collection, _, _ in
                guard !seenIdentifiers.contains(collection.localIdentifier) else {
                    return
                }
                seenIdentifiers.insert(collection.localIdentifier)

                let assets = PHAsset.fetchAssets(in: collection, options: mediaOptions)
                guard assets.count > 0 else {
                    return
                }

                let trimmedTitle = (collection.localizedTitle ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let title = trimmedTitle.isEmpty ? "Untitled Album" : trimmedTitle
                albums.append(
                    PhotoAlbumSummary(
                        localIdentifier: collection.localIdentifier,
                        title: title,
                        assetCount: assets.count
                    )
                )
            }
        }

        appendAlbums(userAlbums)
        appendAlbums(smartAlbums)

        albums.sort { lhs, rhs in
            let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }
            return lhs.localIdentifier < rhs.localIdentifier
        }
        return albums
    }

    private func ensureAuthorized() throws {
        let status = authorizationStatus()
        guard status == .authorized || status == .limited else {
            throw PhotoKitDiscoveryError.unauthorized(status)
        }
    }

    private func mediaAssetFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        return options
    }

    private func mediaItems(from result: PHFetchResult<PHAsset>) -> [MediaItem] {
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
