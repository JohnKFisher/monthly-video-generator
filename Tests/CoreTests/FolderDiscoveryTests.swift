import AVFoundation
import Core
import Foundation
import XCTest

final class FolderDiscoveryTests: XCTestCase {
    func testRecursiveDiscoveryIncludesNestedMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let topImage = root.appendingPathComponent("a.jpg")
        let nestedImage = nested.appendingPathComponent("b.png")
        let unsupported = nested.appendingPathComponent("c.txt")

        try Data([0xFF, 0xD8, 0xFF]).write(to: topImage)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: nestedImage)
        try Data("x".utf8).write(to: unsupported)

        let service = FolderMediaDiscoveryService()
        let recursive = try await service.discover(folderURL: root, recursive: true)
        let nonRecursive = try await service.discover(folderURL: root, recursive: false)

        XCTAssertEqual(recursive.count, 2)
        XCTAssertEqual(nonRecursive.count, 1)
    }

    func testDiscoveryCapturesSourceFrameRateForLocalVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let generatedClipURL = try await StillImageClipFactory().makeTitleCardClip(
            title: "60 fps",
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            renderSize: CGSize(width: 1280, height: 720),
            frameRate: 60
        )
        defer {
            try? FileManager.default.removeItem(at: generatedClipURL)
        }

        let copiedClipURL = root.appendingPathComponent("clip.mov")
        try FileManager.default.copyItem(at: generatedClipURL, to: copiedClipURL)

        let service = FolderMediaDiscoveryService()
        let items = try await service.discover(folderURL: root, recursive: false)

        let videoItem = try XCTUnwrap(items.first(where: { $0.filename == "clip.mov" }))
        XCTAssertEqual(videoItem.type, .video)
        XCTAssertGreaterThanOrEqual(videoItem.sourceFrameRate ?? 0, 50)
    }
}
