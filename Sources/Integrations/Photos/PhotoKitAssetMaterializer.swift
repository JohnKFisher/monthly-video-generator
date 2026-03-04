import AVFoundation
import Core
import Foundation
import Photos

public enum PhotoMaterializerError: LocalizedError {
    case missingAsset(String)
    case noImageData(String)
    case noVideoURL(String)

    public var errorDescription: String? {
        switch self {
        case let .missingAsset(identifier):
            return "Photo asset not found: \(identifier)"
        case let .noImageData(identifier):
            return "Unable to read image data for asset: \(identifier)"
        case let .noVideoURL(identifier):
            return "Unable to materialize video URL for asset: \(identifier)"
        }
    }
}

public final class PhotoKitAssetMaterializer: PhotoAssetMaterializing, @unchecked Sendable {
    private let fileManager = FileManager.default

    public init() {}

    public func materializePhotoAsset(localIdentifier: String, preferredFilename: String) async throws -> URL {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoMaterializerError.missingAsset(localIdentifier)
        }

        switch asset.mediaType {
        case .image:
            return try await materializeImage(asset: asset, preferredFilename: preferredFilename)
        case .video:
            return try await materializeVideo(asset: asset, preferredFilename: preferredFilename)
        default:
            throw PhotoMaterializerError.missingAsset(localIdentifier)
        }
    }

    private func materializeImage(asset: PHAsset, preferredFilename: String) async throws -> URL {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true

        let imageData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: PhotoMaterializerError.noImageData(asset.localIdentifier))
                }
            }
        }

        let ext = URL(fileURLWithPath: preferredFilename).pathExtension.isEmpty ? "jpg" : URL(fileURLWithPath: preferredFilename).pathExtension
        let targetURL = temporaryAssetURL(localIdentifier: asset.localIdentifier, preferredExtension: ext)
        try imageData.write(to: targetURL)
        return targetURL
    }

    private func materializeVideo(asset: PHAsset, preferredFilename: String) async throws -> URL {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                if let urlAsset = avAsset as? AVURLAsset {
                    continuation.resume(returning: urlAsset.url)
                    return
                }

                continuation.resume(throwing: PhotoMaterializerError.noVideoURL(asset.localIdentifier))
            }
        }
    }

    private func temporaryAssetURL(localIdentifier: String, preferredExtension: String) -> URL {
        let sanitizedID = localIdentifier.replacingOccurrences(of: "/", with: "-")
        let directory = fileManager.temporaryDirectory.appendingPathComponent("MonthlyVideoGenerator/Photos", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(sanitizedID)-\(UUID().uuidString)").appendingPathExtension(preferredExtension)
    }
}
