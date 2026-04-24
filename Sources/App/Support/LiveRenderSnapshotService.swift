import AVFoundation
import Core
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LiveRenderSnapshotResult: Sendable {
    let snapshotURL: URL
    let sourceURL: URL
    let sourceFileSizeBytes: UInt64
}

actor LiveRenderSnapshotService {
    private let fileManager: FileManager
    private let baseDirectoryURL: URL
    private let timeoutSeconds: TimeInterval
    private let settleDelayNanoseconds: UInt64

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil,
        timeoutSeconds: TimeInterval = 20,
        settleDelaySeconds: TimeInterval = 2
    ) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("MonthlyVideoGenerator/LiveSnapshots", isDirectory: true)
        self.timeoutSeconds = timeoutSeconds
        self.settleDelayNanoseconds = UInt64(max(settleDelaySeconds, 0) * 1_000_000_000)
    }

    func prepareForNewRender(sessionID: UUID) {
        removeAllSnapshots()
        try? fileManager.createDirectory(
            at: sessionDirectoryURL(for: sessionID),
            withIntermediateDirectories: true
        )
    }

    func removeAllSnapshots() {
        try? fileManager.removeItem(at: baseDirectoryURL)
    }

    func makeSnapshot(
        from candidate: RenderArtifactSnapshotCandidate,
        sessionID: UUID,
        capturedAt: Date
    ) async throws -> LiveRenderSnapshotResult {
        if settleDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: settleDelayNanoseconds)
        }
        try Task.checkCancellation()

        let sourceSize = try stableReadableFileSize(at: candidate.url)
        let outputURL = snapshotURL(sessionID: sessionID, capturedAt: capturedAt)
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Self.writeSnapshotImage(from: candidate.url, to: outputURL)
            }
            group.addTask { [timeoutSeconds] in
                try await Task.sleep(nanoseconds: UInt64(max(timeoutSeconds, 0.1) * 1_000_000_000))
                throw SnapshotError.timedOut
            }

            guard let firstResult = try await group.next() else {
                throw SnapshotError.unreadable
            }
            group.cancelAll()
            _ = firstResult
        }

        return LiveRenderSnapshotResult(
            snapshotURL: outputURL,
            sourceURL: candidate.url,
            sourceFileSizeBytes: sourceSize
        )
    }

    private func stableReadableFileSize(at url: URL) throws -> UInt64 {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SnapshotError.missingFile
        }
        let firstSize = try fileSize(at: url)
        guard firstSize > 0 else {
            throw SnapshotError.emptyFile
        }

        Thread.sleep(forTimeInterval: 0.35)
        let secondSize = try fileSize(at: url)
        guard firstSize == secondSize else {
            throw SnapshotError.unstableFile
        }
        return secondSize
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber {
            return size.uint64Value
        }
        if let size = attributes[.size] as? Int {
            return UInt64(max(size, 0))
        }
        throw SnapshotError.unreadable
    }

    private func sessionDirectoryURL(for sessionID: UUID) -> URL {
        baseDirectoryURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    private func snapshotURL(sessionID: UUID, capturedAt: Date) -> URL {
        let milliseconds = Int(capturedAt.timeIntervalSince1970 * 1000)
        return sessionDirectoryURL(for: sessionID)
            .appendingPathComponent("snapshot-\(milliseconds).png")
    }

    private static func writeSnapshotImage(from sourceURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw SnapshotError.unwritable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotError.unwritable
        }
    }

    enum SnapshotError: LocalizedError {
        case missingFile
        case emptyFile
        case unstableFile
        case unreadable
        case unwritable
        case timedOut

        var errorDescription: String? {
            switch self {
            case .missingFile:
                return "snapshot source is not available yet"
            case .emptyFile:
                return "snapshot source is empty"
            case .unstableFile:
                return "snapshot source is still changing"
            case .unreadable:
                return "snapshot source is not readable yet"
            case .unwritable:
                return "snapshot image could not be written"
            case .timedOut:
                return "snapshot extraction timed out"
            }
        }
    }
}
