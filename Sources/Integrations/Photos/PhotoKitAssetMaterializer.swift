import AVFoundation
import Core
import Foundation
import Photos

public struct SmartMediaInspectionResult: Sendable {
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
    case noVideoResource(String)

    public var errorDescription: String? {
        switch self {
        case let .missingAsset(identifier):
            return "Photo asset not found: \(identifier)"
        case let .noImageData(identifier):
            return "Unable to read image data for asset: \(identifier)"
        case let .noVideoURL(identifier):
            return "Unable to materialize video URL for asset: \(identifier)"
        case let .noVideoResource(identifier):
            return "Unable to find a playable video resource for asset: \(identifier)"
        }
    }
}

public final class PhotoKitAssetMaterializer: PhotoAssetMaterializing, @unchecked Sendable {
    typealias VideoInspectionLoader = @Sendable (String) async throws -> LoadedVideoInspection
    typealias VideoDirectURLLoader = @Sendable (String) async throws -> URL
    typealias VideoFileMaterializer = @Sendable (String, String) async throws -> URL

    struct LoadedVideoInspection: Equatable, Sendable {
        let sourceFrameRate: Double?
        let sourceAudioChannelCount: Int?
    }

    private actor VideoInspectionCache {
        private var loadedVideoInspections: [String: LoadedVideoInspection] = [:]

        func cachedInspection(for localIdentifier: String) -> LoadedVideoInspection? {
            loadedVideoInspections[localIdentifier]
        }

        func store(_ inspection: LoadedVideoInspection, for localIdentifier: String) {
            loadedVideoInspections[localIdentifier] = inspection
        }
    }

    private actor MaterializedVideoCache {
        private var materializedVideoURLs: [String: URL] = [:]

        func cachedURL(for localIdentifier: String) -> URL? {
            materializedVideoURLs[localIdentifier]
        }

        func store(_ url: URL, for localIdentifier: String) {
            materializedVideoURLs[localIdentifier] = url
        }
    }

    private enum ActiveRequestID: Hashable {
        case image(PHImageRequestID)
        case resource(PHAssetResourceDataRequestID)
    }

    private final class ActiveRequestRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var activeRequestIDs: Set<ActiveRequestID> = []

        func addImage(_ requestID: PHImageRequestID) {
            lock.lock()
            activeRequestIDs.insert(.image(requestID))
            lock.unlock()
        }

        func removeImage(_ requestID: PHImageRequestID) {
            lock.lock()
            activeRequestIDs.remove(.image(requestID))
            lock.unlock()
        }

        func addResource(_ requestID: PHAssetResourceDataRequestID) {
            lock.lock()
            activeRequestIDs.insert(.resource(requestID))
            lock.unlock()
        }

        func removeResource(_ requestID: PHAssetResourceDataRequestID) {
            lock.lock()
            activeRequestIDs.remove(.resource(requestID))
            lock.unlock()
        }

        func takeAll() -> [ActiveRequestID] {
            lock.lock()
            let requestIDs = Array(activeRequestIDs)
            activeRequestIDs.removeAll()
            lock.unlock()
            return requestIDs
        }
    }

    private final class PhotoRequestState<Value: Sendable>: @unchecked Sendable {
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

            activeRequests.addImage(requestID)
        }

        func resume(returning value: Value) {
            finishSuccess(value, shouldCancelRequest: false)
        }

        func resume(throwing error: Error) {
            finishFailure(error, shouldCancelRequest: false)
        }

        func cancel() {
            finishFailure(CancellationError(), shouldCancelRequest: true)
        }

        private func finishSuccess(_ value: Value, shouldCancelRequest: Bool) {
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
                activeRequests.removeImage(requestID)
                if shouldCancelRequest {
                    PHImageManager.default().cancelImageRequest(requestID)
                }
            }

            continuation.resume(returning: value)
        }

        private func finishFailure(_ error: Error, shouldCancelRequest: Bool) {
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
                activeRequests.removeImage(requestID)
                if shouldCancelRequest {
                    PHImageManager.default().cancelImageRequest(requestID)
                }
            }

            continuation.resume(throwing: error)
        }
    }

    private final class PhotoAssetResourceRequestState<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let activeRequests: ActiveRequestRegistry
        private var continuation: CheckedContinuation<Value, Error>?
        private var requestID: PHAssetResourceDataRequestID = PHInvalidAssetResourceDataRequestID

        init(activeRequests: ActiveRequestRegistry) {
            self.activeRequests = activeRequests
        }

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func setRequestID(_ requestID: PHAssetResourceDataRequestID) {
            var shouldCancel = false

            lock.lock()
            if continuation == nil {
                shouldCancel = true
            } else {
                self.requestID = requestID
            }
            lock.unlock()

            guard requestID != PHInvalidAssetResourceDataRequestID else {
                return
            }

            if shouldCancel {
                PHAssetResourceManager.default().cancelDataRequest(requestID)
                return
            }

            activeRequests.addResource(requestID)
        }

        func resume(returning value: Value) {
            finishSuccess(value, shouldCancelRequest: false)
        }

        func resume(throwing error: Error, cancelRequest: Bool = false) {
            finishFailure(error, shouldCancelRequest: cancelRequest)
        }

        func cancel() {
            finishFailure(CancellationError(), shouldCancelRequest: true)
        }

        private func finishSuccess(_ value: Value, shouldCancelRequest: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let requestID = self.requestID
            self.requestID = PHInvalidAssetResourceDataRequestID
            lock.unlock()

            guard let continuation else {
                return
            }

            if requestID != PHInvalidAssetResourceDataRequestID {
                activeRequests.removeResource(requestID)
                if shouldCancelRequest {
                    PHAssetResourceManager.default().cancelDataRequest(requestID)
                }
            }

            continuation.resume(returning: value)
        }

        private func finishFailure(_ error: Error, shouldCancelRequest: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let requestID = self.requestID
            self.requestID = PHInvalidAssetResourceDataRequestID
            lock.unlock()

            guard let continuation else {
                return
            }

            if requestID != PHInvalidAssetResourceDataRequestID {
                activeRequests.removeResource(requestID)
                if shouldCancelRequest {
                    PHAssetResourceManager.default().cancelDataRequest(requestID)
                }
            }

            continuation.resume(throwing: error)
        }
    }

    private let fileManager = FileManager.default
    private let videoInspectionCache = VideoInspectionCache()
    private let materializedVideoCache = MaterializedVideoCache()
    private let activeRequestRegistry: ActiveRequestRegistry
    private let videoInspectionLoader: VideoInspectionLoader
    private let videoDirectURLLoader: VideoDirectURLLoader
    private let videoFileMaterializer: VideoFileMaterializer

    public init() {
        let registry = ActiveRequestRegistry()
        self.activeRequestRegistry = registry
        self.videoInspectionLoader = { localIdentifier in
            try await Self.loadPhotoVideoInspection(localIdentifier: localIdentifier, activeRequests: registry)
        }
        self.videoDirectURLLoader = { localIdentifier in
            try await Self.loadPhotoVideoDirectURL(localIdentifier: localIdentifier, activeRequests: registry)
        }
        self.videoFileMaterializer = { localIdentifier, preferredFilename in
            try await Self.materializePhotoVideoFile(
                localIdentifier: localIdentifier,
                preferredFilename: preferredFilename,
                activeRequests: registry
            )
        }
    }

    init(
        videoInspectionLoader: @escaping VideoInspectionLoader,
        videoDirectURLLoader: @escaping VideoDirectURLLoader,
        videoFileMaterializer: @escaping VideoFileMaterializer
    ) {
        let registry = ActiveRequestRegistry()
        self.activeRequestRegistry = registry
        self.videoInspectionLoader = videoInspectionLoader
        self.videoDirectURLLoader = videoDirectURLLoader
        self.videoFileMaterializer = videoFileMaterializer
    }

    public func cancelPendingRequests() {
        let requestIDs = activeRequestRegistry.takeAll()
        let imageManager = PHImageManager.default()
        let resourceManager = PHAssetResourceManager.default()
        for requestID in requestIDs {
            switch requestID {
            case let .image(imageRequestID):
                imageManager.cancelImageRequest(imageRequestID)
            case let .resource(resourceRequestID):
                resourceManager.cancelDataRequest(resourceRequestID)
            }
        }
    }

    public func materializePhotoAsset(localIdentifier: String, preferredFilename: String) async throws -> URL {
        if let cachedVideoURL = await materializedVideoCache.cachedURL(for: localIdentifier),
           fileManager.fileExists(atPath: cachedVideoURL.path) {
            return cachedVideoURL
        }

        if await videoInspectionCache.cachedInspection(for: localIdentifier) != nil {
            return try await materializeVideo(
                localIdentifier: localIdentifier,
                preferredFilename: preferredFilename
            )
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoMaterializerError.missingAsset(localIdentifier)
        }

        switch asset.mediaType {
        case .image:
            return try await materializeImage(asset: asset, preferredFilename: preferredFilename)
        case .video:
            return try await materializeVideo(
                localIdentifier: asset.localIdentifier,
                preferredFilename: preferredFilename
            )
        default:
            throw PhotoMaterializerError.missingAsset(localIdentifier)
        }
    }

    public func prepareItemsForSmartMedia(
        _ items: [MediaItem],
        inspectFrameRate: Bool,
        inspectAudioChannels: Bool,
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        statusHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> SmartMediaInspectionResult {
        guard inspectFrameRate || inspectAudioChannels else {
            return SmartMediaInspectionResult(items: items, warnings: [])
        }

        let inspectionTargets = items.enumerated().compactMap { index, item -> (Int, MediaItem, String)? in
            guard item.type == .video,
                  case let .photoAsset(localIdentifier) = item.locator else {
                return nil
            }
            return (index, item, localIdentifier)
        }

        guard !inspectionTargets.isEmpty else {
            return SmartMediaInspectionResult(items: items, warnings: [])
        }

        var updatedItems = items
        var warnings: [String] = []
        var emittedInspectionWarning = false

        for (position, inspectionTarget) in inspectionTargets.enumerated() {
            try Task.checkCancellation()

            let progress = Double(position) / Double(inspectionTargets.count)
            progressHandler?(progress)
            statusHandler?(inspectionStatusMessage(
                position: position + 1,
                total: inspectionTargets.count,
                inspectFrameRate: inspectFrameRate,
                inspectAudioChannels: inspectAudioChannels
            ))

            do {
                let loadedVideoInspection = try await loadVideoInspection(localIdentifier: inspectionTarget.2)
                updatedItems[inspectionTarget.0] = inspectionTarget.1.withSourceInspection(
                    sourceFrameRate: inspectFrameRate ? loadedVideoInspection.sourceFrameRate : inspectionTarget.1.sourceFrameRate,
                    sourceAudioChannelCount: inspectAudioChannels ? loadedVideoInspection.sourceAudioChannelCount : inspectionTarget.1.sourceAudioChannelCount
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if !emittedInspectionWarning {
                    warnings.append(
                        inspectionFailureWarning(
                            inspectFrameRate: inspectFrameRate,
                            inspectAudioChannels: inspectAudioChannels
                        )
                    )
                    emittedInspectionWarning = true
                }
            }

            let completedProgress = Double(position + 1) / Double(inspectionTargets.count)
            progressHandler?(completedProgress)
        }

        return SmartMediaInspectionResult(items: updatedItems, warnings: warnings)
    }

    public func prepareItemsForSmartFrameRate(
        _ items: [MediaItem],
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        statusHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> SmartMediaInspectionResult {
        try await prepareItemsForSmartMedia(
            items,
            inspectFrameRate: true,
            inspectAudioChannels: false,
            progressHandler: progressHandler,
            statusHandler: statusHandler
        )
    }

    private func materializeImage(asset: PHAsset, preferredFilename: String) async throws -> URL {
        let imageData = try await requestImageData(asset: asset)

        let ext = URL(fileURLWithPath: preferredFilename).pathExtension.isEmpty ? "jpg" : URL(fileURLWithPath: preferredFilename).pathExtension
        let targetURL = Self.temporaryAssetURL(
            localIdentifier: asset.localIdentifier,
            preferredExtension: ext,
            fileManager: fileManager
        )
        try imageData.write(to: targetURL)
        return targetURL
    }

    private func materializeVideo(localIdentifier: String, preferredFilename: String) async throws -> URL {
        if let cachedVideoURL = await materializedVideoCache.cachedURL(for: localIdentifier),
           fileManager.fileExists(atPath: cachedVideoURL.path) {
            return cachedVideoURL
        }

        do {
            let directVideoURL = try await videoDirectURLLoader(localIdentifier)
            if Self.isUsableDirectVideoURL(directVideoURL, fileManager: fileManager) {
                return directVideoURL
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fall back to temp-file materialization for URLs that are transient or unavailable.
        }

        let materializedURL = try await videoFileMaterializer(localIdentifier, preferredFilename)
        await materializedVideoCache.store(materializedURL, for: localIdentifier)
        return materializedURL
    }

    private func loadVideoInspection(localIdentifier: String) async throws -> LoadedVideoInspection {
        if let cachedVideoInspection = await videoInspectionCache.cachedInspection(for: localIdentifier) {
            return cachedVideoInspection
        }

        let loadedVideoInspection = try await videoInspectionLoader(localIdentifier)
        await videoInspectionCache.store(loadedVideoInspection, for: localIdentifier)
        return loadedVideoInspection
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

    private static func loadPhotoVideoInspection(
        localIdentifier: String,
        activeRequests: ActiveRequestRegistry
    ) async throws -> LoadedVideoInspection {
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

        let sourceAudioChannelCount = await primaryAudioChannelCount(for: urlAsset)

        return LoadedVideoInspection(
            sourceFrameRate: resolvedFrameRate,
            sourceAudioChannelCount: sourceAudioChannelCount
        )
    }

    private static func loadPhotoVideoDirectURL(
        localIdentifier: String,
        activeRequests: ActiveRequestRegistry
    ) async throws -> URL {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoMaterializerError.missingAsset(localIdentifier)
        }

        let urlAsset = try await requestVideoURLAsset(asset: asset, activeRequests: activeRequests)
        return urlAsset.url
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

    private static func materializePhotoVideoFile(
        localIdentifier: String,
        preferredFilename: String,
        activeRequests: ActiveRequestRegistry
    ) async throws -> URL {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw PhotoMaterializerError.missingAsset(localIdentifier)
        }
        guard let resource = preferredVideoResource(for: asset) else {
            throw PhotoMaterializerError.noVideoResource(localIdentifier)
        }

        let targetURL = temporaryAssetURL(
            localIdentifier: localIdentifier,
            preferredExtension: preferredVideoExtension(
                preferredFilename: preferredFilename,
                resourceFilename: resource.originalFilename
            ),
            fileManager: FileManager.default
        )
        FileManager.default.createFile(atPath: targetURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: targetURL)
        defer {
            try? fileHandle.close()
        }

        let requestOptions = PHAssetResourceRequestOptions()
        requestOptions.isNetworkAccessAllowed = true
        let requestState = PhotoAssetResourceRequestState<URL>(activeRequests: activeRequests)

        do {
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    requestState.install(continuation)
                    let requestID = PHAssetResourceManager.default().requestData(
                        for: resource,
                        options: requestOptions,
                        dataReceivedHandler: { data in
                            do {
                                try fileHandle.write(contentsOf: data)
                            } catch {
                                requestState.resume(throwing: error, cancelRequest: true)
                            }
                        },
                        completionHandler: { error in
                            if let error {
                                requestState.resume(throwing: error)
                            } else {
                                requestState.resume(returning: targetURL)
                            }
                        }
                    )
                    requestState.setRequestID(requestID)
                }
            }, onCancel: {
                requestState.cancel()
            })
        } catch {
            try? FileManager.default.removeItem(at: targetURL)
            throw error
        }
    }

    private static func temporaryAssetURL(
        localIdentifier: String,
        preferredExtension: String,
        fileManager: FileManager
    ) -> URL {
        let sanitizedID = localIdentifier.replacingOccurrences(of: "/", with: "-")
        let directory = fileManager.temporaryDirectory.appendingPathComponent("MonthlyVideoGenerator/Photos", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(sanitizedID)-\(UUID().uuidString)").appendingPathExtension(preferredExtension)
    }

    private static func preferredVideoResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType] = [
            .fullSizeVideo,
            .video,
            .adjustmentBaseVideo,
            .fullSizePairedVideo,
            .pairedVideo
        ]

        for preferredType in preferredTypes {
            if let resource = resources.first(where: { $0.type == preferredType }) {
                return resource
            }
        }

        return nil
    }

    private static func isUsableDirectVideoURL(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.isFileURL else {
            return false
        }

        let path = url.path
        guard !path.isEmpty else {
            return false
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }

        return fileManager.isReadableFile(atPath: path)
    }

    private static func preferredVideoExtension(preferredFilename: String, resourceFilename: String) -> String {
        let resourceExtension = URL(fileURLWithPath: resourceFilename).pathExtension
        if !resourceExtension.isEmpty {
            return resourceExtension
        }

        let preferredExtension = URL(fileURLWithPath: preferredFilename).pathExtension
        if !preferredExtension.isEmpty {
            return preferredExtension
        }

        return "mov"
    }

    private func inspectionStatusMessage(
        position: Int,
        total: Int,
        inspectFrameRate: Bool,
        inspectAudioChannels: Bool
    ) -> String {
        switch (inspectFrameRate, inspectAudioChannels) {
        case (true, true):
            return "Inspecting video frame rates and audio \(position) of \(total)..."
        case (true, false):
            return "Inspecting video frame rates \(position) of \(total)..."
        case (false, true):
            return "Inspecting video audio \(position) of \(total)..."
        case (false, false):
            return "Inspecting video metadata \(position) of \(total)..."
        }
    }

    private func inspectionFailureWarning(
        inspectFrameRate: Bool,
        inspectAudioChannels: Bool
    ) -> String {
        switch (inspectFrameRate, inspectAudioChannels) {
        case (true, true):
            return "Some Apple Photos videos could not be inspected for Smart fps/audio and will fall back toward 30 fps or 5.1."
        case (true, false):
            return "Some Apple Photos videos could not be inspected for Smart fps and will fall back toward 30 fps."
        case (false, true):
            return "Some Apple Photos videos could not be inspected for Smart audio and may fall back to 5.1."
        case (false, false):
            return "Some Apple Photos videos could not be inspected."
        }
    }

    private static func primaryAudioChannelCount(for asset: AVAsset) async -> Int? {
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return nil
        }

        guard let audioTrack = audioTracks.first else {
            return 0
        }

        guard let formatDescriptions = try? await audioTrack.load(.formatDescriptions) else {
            return nil
        }

        for formatDescription in formatDescriptions {
            let cmFormatDescription = formatDescription as CMFormatDescription
            if let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(cmFormatDescription) {
                let channels = Int(basicDescription.pointee.mChannelsPerFrame)
                if channels > 0 {
                    return channels
                }
            }
        }

        return nil
    }
}
