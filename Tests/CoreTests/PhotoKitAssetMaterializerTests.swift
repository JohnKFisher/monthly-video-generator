import Core
import Foundation
@testable import PhotosIntegration
import XCTest

final class PhotoKitAssetMaterializerTests: XCTestCase {
    func testPrepareItemsForSmartFrameRateCachesLoadedVideoAssetForMaterialization() async throws {
        let expectedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoKitAssetMaterializerTests-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try Data().write(to: expectedURL)
        defer {
            try? FileManager.default.removeItem(at: expectedURL)
        }

        let loadCounter = LockedCounter()
        let callbackRecorder = InspectionCallbackRecorder()
        let materializer = PhotoKitAssetMaterializer(videoAssetLoader: { localIdentifier in
            XCTAssertEqual(localIdentifier, "video-1")
            loadCounter.increment()
            return PhotoKitAssetMaterializer.LoadedVideoAsset(url: expectedURL, sourceFrameRate: 59.94)
        })

        let result = try await materializer.prepareItemsForSmartFrameRate(
            [makePhotoVideoItem(localIdentifier: "video-1")],
            progressHandler: { callbackRecorder.recordProgress($0) },
            statusHandler: { callbackRecorder.recordStatus($0) }
        )

        let updatedItem = try XCTUnwrap(result.items.first)
        XCTAssertEqual(updatedItem.sourceFrameRate ?? 0, 59.94, accuracy: 0.001)
        XCTAssertTrue(result.warnings.isEmpty)

        let callbacks = callbackRecorder.snapshot()
        XCTAssertEqual(callbacks.progress.first ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(callbacks.progress.last ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(callbacks.status, ["Inspecting video frame rates 1 of 1..."])

        let materializedURL = try await materializer.materializePhotoAsset(
            localIdentifier: "video-1",
            preferredFilename: "video.mov"
        )

        XCTAssertEqual(materializedURL, expectedURL)
        XCTAssertEqual(loadCounter.value, 1)
    }

    func testPrepareItemsForSmartFrameRateRespectsTaskCancellation() async throws {
        let loaderStarted = expectation(description: "video asset loader started")
        let materializer = PhotoKitAssetMaterializer(videoAssetLoader: { _ in
            loaderStarted.fulfill()
            try await Task.sleep(for: .seconds(30))
            return PhotoKitAssetMaterializer.LoadedVideoAsset(
                url: URL(fileURLWithPath: "/tmp/unused.mov"),
                sourceFrameRate: 60
            )
        })
        let item = makePhotoVideoItem(localIdentifier: "video-1")

        let task = Task {
            try await materializer.prepareItemsForSmartFrameRate(
                [item]
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
