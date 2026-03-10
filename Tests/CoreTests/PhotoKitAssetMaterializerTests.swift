import Core
import Foundation
@testable import PhotosIntegration
import XCTest

final class PhotoKitAssetMaterializerTests: XCTestCase {
    func testPrepareItemsForSmartMediaCachesInspectionMetadataWithoutMaterializingVideo() async throws {
        let materializedVideoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoKitAssetMaterializerTests-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try Data().write(to: materializedVideoURL)
        defer {
            try? FileManager.default.removeItem(at: materializedVideoURL)
        }

        let inspectionLoadCounter = LockedCounter()
        let materializationCounter = LockedCounter()
        let callbackRecorder = InspectionCallbackRecorder()
        let materializer = PhotoKitAssetMaterializer(
            videoInspectionLoader: { localIdentifier in
                XCTAssertEqual(localIdentifier, "video-1")
                inspectionLoadCounter.increment()
                return PhotoKitAssetMaterializer.LoadedVideoInspection(
                    sourceFrameRate: 59.94,
                    sourceAudioChannelCount: 6
                )
            },
            videoFileMaterializer: { localIdentifier, preferredFilename in
                XCTAssertEqual(localIdentifier, "video-1")
                XCTAssertEqual(preferredFilename, "video.mov")
                materializationCounter.increment()
                return materializedVideoURL
            }
        )

        let result = try await materializer.prepareItemsForSmartMedia(
            [makePhotoVideoItem(localIdentifier: "video-1")],
            inspectFrameRate: true,
            inspectAudioChannels: true,
            progressHandler: { callbackRecorder.recordProgress($0) },
            statusHandler: { callbackRecorder.recordStatus($0) }
        )

        guard let updatedItem = result.items.first else {
            return XCTFail("Expected inspected item")
        }
        XCTAssertEqual(updatedItem.sourceFrameRate ?? 0, 59.94, accuracy: 0.001)
        XCTAssertEqual(updatedItem.sourceAudioChannelCount, 6)
        XCTAssertTrue(result.warnings.isEmpty)

        let callbacks = callbackRecorder.snapshot()
        XCTAssertEqual(callbacks.progress.first ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(callbacks.progress.last ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(callbacks.status, ["Inspecting video frame rates and audio 1 of 1..."])
        XCTAssertEqual(inspectionLoadCounter.value, 1)
        XCTAssertEqual(materializationCounter.value, 0)
    }

    func testMaterializePhotoAssetCachesTempCopyAcrossRepeatedCalls() async throws {
        let materializedVideoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoKitAssetMaterializerTests-cached-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try Data().write(to: materializedVideoURL)
        defer {
            try? FileManager.default.removeItem(at: materializedVideoURL)
        }

        let materializationCounter = LockedCounter()
        let materializer = PhotoKitAssetMaterializer(
            videoInspectionLoader: { localIdentifier in
                XCTAssertEqual(localIdentifier, "video-1")
                return PhotoKitAssetMaterializer.LoadedVideoInspection(
                    sourceFrameRate: 30,
                    sourceAudioChannelCount: 2
                )
            },
            videoFileMaterializer: { localIdentifier, preferredFilename in
                XCTAssertEqual(localIdentifier, "video-1")
                XCTAssertEqual(preferredFilename, "video.mov")
                materializationCounter.increment()
                return materializedVideoURL
            }
        )

        _ = try await materializer.prepareItemsForSmartMedia(
            [makePhotoVideoItem(localIdentifier: "video-1")],
            inspectFrameRate: true,
            inspectAudioChannels: true
        )

        let firstMaterializedURL = try await materializer.materializePhotoAsset(
            localIdentifier: "video-1",
            preferredFilename: "video.mov"
        )
        let secondMaterializedURL = try await materializer.materializePhotoAsset(
            localIdentifier: "video-1",
            preferredFilename: "video.mov"
        )

        XCTAssertEqual(firstMaterializedURL, materializedVideoURL)
        XCTAssertEqual(secondMaterializedURL, materializedVideoURL)
        XCTAssertEqual(materializationCounter.value, 1)
    }

    func testPrepareItemsForSmartFrameRateRespectsTaskCancellation() async throws {
        let loaderStarted = expectation(description: "video asset loader started")
        let materializer = PhotoKitAssetMaterializer(
            videoInspectionLoader: { _ in
                loaderStarted.fulfill()
                try await Task.sleep(for: .seconds(30))
                return PhotoKitAssetMaterializer.LoadedVideoInspection(
                    sourceFrameRate: 60,
                    sourceAudioChannelCount: 2
                )
            },
            videoFileMaterializer: { _, _ in
                XCTFail("Video materialization should not run during metadata inspection cancellation test")
                return URL(fileURLWithPath: "/tmp/unused.mov")
            }
        )
        let item = makePhotoVideoItem(localIdentifier: "video-1")

        let task = Task<SmartMediaInspectionResult, Error> {
            try await materializer.prepareItemsForSmartMedia(
                [item],
                inspectFrameRate: true,
                inspectAudioChannels: true
            )
        }

        await fulfillment(of: [loaderStarted], timeout: 1.0)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected Smart frame-rate inspection to cancel")
        } catch is CancellationError {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func makePhotoVideoItem(localIdentifier: String) -> MediaItem {
        MediaItem(
            id: localIdentifier,
            type: .video,
            captureDate: Date(),
            duration: nil,
            pixelSize: CGSize(width: 1920, height: 1080),
            colorInfo: .unknown,
            locator: .photoAsset(localIdentifier: localIdentifier),
            fileSizeBytes: 1_000,
            filename: "\(localIdentifier).mov"
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value: Int = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private final class InspectionCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var progressValues: [Double] = []
    private var statusValues: [String] = []

    func recordProgress(_ value: Double) {
        lock.lock()
        progressValues.append(value)
        lock.unlock()
    }

    func recordStatus(_ value: String) {
        lock.lock()
        statusValues.append(value)
        lock.unlock()
    }

    func snapshot() -> (progress: [Double], status: [String]) {
        lock.lock()
        let snapshot = (progressValues, statusValues)
        lock.unlock()
        return snapshot
    }
}
