import AVFoundation
import Core
import Foundation
import Photos

public struct SmartFrameRateInspectionResult: Sendable {
    public let items: [MediaItem]
    public let warnings: [String]

    public init(items: [MediaItem], warnings: [String]) {
        self.items = items
        self.warnings = warnings
    }
}

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
    typealias VideoAssetLoader = @Sendable (String) async throws -> LoadedVideoAsset

    struct LoadedVideoAsset: Equatable, Sendable {
        let url: URL
        let sourceFrameRate: Double?
    }

    private actor VideoAssetCache {
        private var loadedVideoAssets: [String: LoadedVideoAsset] = [:]

        func cachedAsset(for localIdentifier: String) -> LoadedVideoAsset? {
            loadedVideoAssets[localIdentifier]
        }

        func store(_ asset: LoadedVideoAsset, for localIdentifier: String) {
            loadedVideoAssets[localIdentifier] = asset
        }
    }

    private final class ActiveRequestRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var activeRequestIDs: Set<PHImageRequestID> = []

        func add(_ requestID: PHImageRequestID) {
            lock.lock()
            activeRequestIDs.insert(requestID)
            lock.unlock()
        }

        func remove(_ requestID: PHImageRequestID) {
            lock.lock()
            activeRequestIDs.remove(requestID)
            lock.unlock()
        }

        func takeAll() -> [PHImageRequestID] {
            lock.lock()
            let requestIDs = Array(activeRequestIDs)
            activeRequestIDs.removeAll()
            lock.unlock()
            return requestIDs
        }
    }

    private final class PhotoRequestState<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private let activeRequests: ActiveRequestRegistry
        private var continuation: CheckedContinuation<Value, Error>?
        private var requestID: PHImageRequestID = PHInvalidImageRequestID

        init(activeRequests: ActiveRequestRegistry) {
            self.activeRequests = activeRequests
        }

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func setRequestID(_ requestID: PHImageRequestID) {
            var shouldCancel = false

            lock.lock()
            if continuation == nil {
                shouldCancel = true
            } else {
                self.requestID = requestID
            }
            lock.unlock()

            guard requestID != PHInvalidImageRequestID else {
                return
            }

            if shouldCancel {
                PHImageManager.default().cancelImageRequest(requestID)
                return
            }

            activeRequests.add(requestID)
        }

        func resume(returning value: sending Value) {
            finish(result: .success(value), shouldCancelRequest: false)
        }

        func resume(throwing error: sending Error) {
            finish(result: .failure(error), shouldCancelRequest: false)
        }

        func cancel() {
            finish(result: .failure(CancellationError()), shouldCancelRequest: true)
        }

        private func finish(result: sending Result<Value, Error>, shouldCancelRequest: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let requestID = self.requestID
            self.requestID = PHInvalidImageRequestID
            lock.unlock()

            guard let continuation else {
                return
            }

            if requestID != PHInvalidImageRequestID {
                activeRequests.remove(requestID)
                if shouldCancelRequest {
                    PHImageManager.default().cancelImageRequest(requestID)
                }
            }

            continuation.resume(with: result)
        }
    }

    private let fileManager = FileManager.default
    private let videoAssetCache = VideoAssetCache()
    private let activeRequestRegistry: ActiveRequestRegistry
    private let videoAssetLoader: VideoAssetLoader

    public init() {
        let registry = ActiveRequestRegistry()
        self.activeRequestRegistry = registry
        self.videoAssetLoader = { localIdentifier in
            try await Self.loadPhotoVideoAsset(localIdentifier: localIdentifier, activeRequests: registry)
        }
    }

    init(videoAssetLoader: @escaping VideoAssetLoader) {
        let registry = ActiveRequestRegistry()
        self.activeRequestRegistry = registry
        self.videoAssetLoader = videoAssetLoader
    }

    public func cancelPendingRequests() {
        let requestIDs = activeRequestRegistry.takeAll()
        let imageManager = PHImageManager.default()
        for requestID in requestIDs {
            imageManager.cancelImageRequest(requestID)
        }
    }

    public func materializePhotoAsset(localIdentifier: String, preferredFilename: String) async throws -> URL {
        if let cachedVideoAsset = await videoAssetCache.cachedAsset(for: localIdentifier) {
            return cachedVideoAsset.url
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoMaterializerError.missingAsset(localIdentifier)
        }

        switch asset.mediaType {
        case .image:
            return try await materializeImage(asset: asset, preferredFilename: preferredFilename)
        case .video:
            _ = preferredFilename
            return try await materializeVideo(localIdentifier: asset.localIdentifier)
        default:
            throw PhotoMaterializerError.missingAsset(localIdentifier)
        }
    }

    public func prepareItemsForSmartFrameRate(
        _ items: [MediaItem],
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        statusHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> SmartFrameRateInspectionResult {
        let inspectionTargets = items.enumerated().compactMap { index, item -> (Int, MediaItem, String)? in
            guard item.type == .video,
                  case let .photoAsset(localIdentifier) = item.locator else {
                return nil
            }
            return (index, item, localIdentifier)
        }

        guard !inspectionTargets.isEmpty else {
            return SmartFrameRateInspectionResult(items: items, warnings: [])
        }

        var updatedItems = items
        var warnings: [String] = []
        var emittedInspectionWarning = false

        for (position, inspectionTarget) in inspectionTargets.enumerated() {
            try Task.checkCancellation()

            let progress = Double(position) / Double(inspectionTargets.count)
            progressHandler?(progress)
            statusHandler?("Inspecting video frame rates \(position + 1) of \(inspectionTargets.count)...")

            do {
                let loadedVideoAsset = try await loadVideoAsset(localIdentifier: inspectionTarget.2)
                updatedItems[inspectionTarget.0] = inspectionTarget.1.withSourceFrameRate(loadedVideoAsset.sourceFrameRate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !emittedInspectionWarning {
                    warnings.append("Some Apple Photos videos could not be inspected for Smart fps and will fall back toward 30 fps.")
                    emittedInspectionWarning = true
                }
            }

            let completedProgress = Double(position + 1) / Double(inspectionTargets.count)
            progressHandler?(completedProgress)
        }

        return SmartFrameRateInspectionResult(items: updatedItems, warnings: warnings)
    }

    private func materializeImage(asset: PHAsset, preferredFilename: String) async throws -> URL {
        let imageData = try await requestImageData(asset: asset)

        let ext = URL(fileURLWithPath: preferredFilename).pathExtension.isEmpty ? "jpg" : URL(fileURLWithPath: preferredFilename).pathExtension
        let targetURL = temporaryAssetURL(localIdentifier: asset.localIdentifier, preferredExtension: ext)
        try imageData.write(to: targetURL)
        return targetURL
    }

    private func materializeVideo(localIdentifier: String) async throws -> URL {
        let loadedVideoAsset = try await loadVideoAsset(localIdentifier: localIdentifier)
        return loadedVideoAsset.url
    }

    private func loadVideoAsset(localIdentifier: String) async throws -> LoadedVideoAsset {
        if let cachedVideoAsset = await videoAssetCache.cachedAsset(for: localIdentifier) {
            return cachedVideoAsset
        }

        let loadedVideoAsset = try await videoAssetLoader(localIdentifier)
        await videoAssetCache.store(loadedVideoAsset, for: localIdentifier)
        return loadedVideoAsset
    }

    private func requestImageData(asset: PHAsset) async throws -> Data {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true

        let requestState = PhotoRequestState<Data>(activeRequests: activeRequestRegistry)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                requestState.install(continuation)
                let requestID = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    if let isCancelled = info?[PHImageCancelledKey] as? Bool, isCancelled {
                        requestState.resume(throwing: CancellationError())
                        return
                    }
                    if let error = info?[PHImageErrorKey] as? Error {
                        requestState.resume(throwing: error)
                        return
                    }
                    if let data {
                        requestState.resume(returning: data)
                    } else {
                        requestState.resume(throwing: PhotoMaterializerError.noImageData(asset.localIdentifier))
                    }
                }
                requestState.setRequestID(requestID)
            }
        }, onCancel: {
            requestState.cancel()
        })
    }

    private static func loadPhotoVideoAsset(
        localIdentifier: String,
        activeRequests: ActiveRequestRegistry
    ) async throws -> LoadedVideoAsset {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoMaterializerError.missingAsset(localIdentifier)
        }

        let urlAsset = try await requestVideoURLAsset(asset: asset, activeRequests: activeRequests)
        let videoTracks = try? await urlAsset.loadTracks(withMediaType: .video)
        let sourceFrameRate: Float?
        if let videoTrack = videoTracks?.first {
            sourceFrameRate = try? await videoTrack.load(.nominalFrameRate)
        } else {
            sourceFrameRate = nil
        }

        let resolvedFrameRate: Double?
        if let sourceFrameRate, sourceFrameRate > 0 {
            resolvedFrameRate = Double(sourceFrameRate)
        } else {
            resolvedFrameRate = nil
        }

        return LoadedVideoAsset(
            url: urlAsset.url,
            sourceFrameRate: resolvedFrameRate
        )
    }

    private static func requestVideoURLAsset(
        asset: PHAsset,
        activeRequests: ActiveRequestRegistry
    ) async throws -> AVURLAsset {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        let requestState = PhotoRequestState<AVURLAsset>(activeRequests: activeRequests)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVURLAsset, Error>) in
                requestState.install(continuation)
                let requestID = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    if let isCancelled = info?[PHImageCancelledKey] as? Bool, isCancelled {
                        requestState.resume(throwing: CancellationError())
                        return
                    }
                    if let error = info?[PHImageErrorKey] as? Error {
                        requestState.resume(throwing: error)
                        return
                    }
                    if let urlAsset = avAsset as? AVURLAsset {
                        requestState.resume(returning: urlAsset)
                        return
                    }

                    requestState.resume(throwing: PhotoMaterializerError.noVideoURL(asset.localIdentifier))
                }
                requestState.setRequestID(requestID)
            }
        }, onCancel: {
            requestState.cancel()
        })
    }

    private func temporaryAssetURL(localIdentifier: String, preferredExtension: String) -> URL {
        let sanitizedID = localIdentifier.replacingOccurrences(of: "/", with: "-")
        let directory = fileManager.temporaryDirectory.appendingPathComponent("MonthlyVideoGenerator/Photos", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(sanitizedID)-\(UUID().uuidString)").appendingPathExtension(preferredExtension)
    }
}
