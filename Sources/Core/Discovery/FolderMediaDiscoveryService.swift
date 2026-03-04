import AVFoundation
import Foundation
#if canImport(AppKit)
import AppKit
#endif

public final class FolderMediaDiscoveryService {
    public enum DiscoveryError: Error {
        case folderNotReachable(URL)
    }

    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
    private let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi"]

    public init() {}

    public func discover(folderURL: URL, recursive: Bool) async throws -> [MediaItem] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: folderURL.path) else {
            throw DiscoveryError.folderNotReachable(folderURL)
        }

        let fileURLs = collectCandidateFiles(folderURL: folderURL, recursive: recursive)
        var items: [MediaItem] = []
        items.reserveCapacity(fileURLs.count)

        for url in fileURLs {
            if let mediaItem = await buildMediaItem(for: url) {
                items.append(mediaItem)
            }
        }

        return items
    }

    private func collectCandidateFiles(folderURL: URL, recursive: Bool) -> [URL] {
        let fileManager = FileManager.default
        var results: [URL] = []

        if recursive {
            let keys: [URLResourceKey] = [.isRegularFileKey]
            let enumerator = fileManager.enumerator(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )

            while let item = enumerator?.nextObject() as? URL {
                if isSupportedMedia(url: item) {
                    results.append(item)
                }
            }
        } else {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            results = urls.filter(isSupportedMedia)
        }

        return results
    }

    private func isSupportedMedia(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    private func buildMediaItem(for url: URL) async -> MediaItem? {
        let ext = url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        let captureDate = values?.creationDate ?? values?.contentModificationDate
        let fileSize = values?.fileSize.map(Int64.init)

        if imageExtensions.contains(ext) {
            let size = imagePixelSize(url: url)
            return MediaItem(
                id: url.path,
                type: .image,
                captureDate: captureDate,
                duration: nil,
                pixelSize: size,
                colorInfo: .unknown,
                locator: .file(url),
                fileSizeBytes: fileSize,
                filename: url.lastPathComponent
            )
        }

        if videoExtensions.contains(ext) {
            let asset = AVURLAsset(url: url)
            let duration = try? await asset.load(.duration)
            let tracks = try? await asset.loadTracks(withMediaType: .video)

            var finalSize = CGSize(width: 1920, height: 1080)
            if let track = tracks?.first,
               let naturalSize = try? await track.load(.naturalSize),
               let preferredTransform = try? await track.load(.preferredTransform) {
                let transformed = naturalSize.applying(preferredTransform)
                finalSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            }

            return MediaItem(
                id: url.path,
                type: .video,
                captureDate: captureDate,
                duration: duration,
                pixelSize: finalSize,
                colorInfo: .unknown,
                locator: .file(url),
                fileSizeBytes: fileSize,
                filename: url.lastPathComponent
            )
        }

        return nil
    }

    private func imagePixelSize(url: URL) -> CGSize {
        #if canImport(AppKit)
        if let image = NSImage(contentsOf: url), let representation = image.representations.first {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        #endif
        return CGSize(width: 1920, height: 1080)
    }
}
