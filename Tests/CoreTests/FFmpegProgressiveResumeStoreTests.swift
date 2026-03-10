@testable import Core
import CoreGraphics
import Foundation
import XCTest

final class FFmpegProgressiveResumeStoreTests: XCTestCase {
    func testPausedSessionPersistsCompletedStagesAndReloadsFromDisk() throws {
        let baseDirectoryURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectoryURL) }

        var currentDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = FFmpegProgressiveResumeStore(
            baseDirectoryURL: baseDirectoryURL,
            now: { currentDate }
        )
        let outputTarget = OutputTarget(
            directory: URL(fileURLWithPath: "/tmp/export-output"),
            baseFilename: "July 2025"
        )
        var session = try store.createSession(
            planSignature: "signature-1",
            outputTarget: outputTarget,
            finalOutputURL: outputTarget.directory.appendingPathComponent("July 2025.mp4")
        )

        try store.markPresentationCompleted(3, session: &session)
        currentDate.addTimeInterval(60)
        try store.markBatchCompleted(1, session: &session)
        currentDate.addTimeInterval(60)
        try store.markConcatCompleted(&session)
        currentDate.addTimeInterval(60)
        try store.markPaused(&session)

        let reloadedStore = FFmpegProgressiveResumeStore(
            baseDirectoryURL: baseDirectoryURL,
            now: { currentDate }
        )
        let reloaded = try XCTUnwrap(
            reloadedStore.findPausedSession(
                planSignature: "signature-1",
                outputTarget: outputTarget
            )
        )

        XCTAssertEqual(reloaded.state, .paused)
        XCTAssertEqual(reloaded.completedPresentationIndices, [3])
        XCTAssertEqual(reloaded.completedBatchIndices, [1])
        XCTAssertTrue(reloaded.concatCompleted)
        XCTAssertEqual(reloaded.finalOutputURL, outputTarget.directory.appendingPathComponent("July 2025.mp4"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.manifestURL.path))
    }

    func testPruneStaleSessionsRemovesExpiredWorkDirectories() throws {
        let baseDirectoryURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseDirectoryURL) }

        var currentDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = FFmpegProgressiveResumeStore(
            baseDirectoryURL: baseDirectoryURL,
            now: { currentDate }
        )
        let outputTarget = OutputTarget(
            directory: URL(fileURLWithPath: "/tmp/export-output"),
            baseFilename: "July 2025"
        )
        var session = try store.createSession(
            planSignature: "signature-1",
            outputTarget: outputTarget,
            finalOutputURL: outputTarget.directory.appendingPathComponent("July 2025.mp4")
        )
        try store.markPaused(&session)

        currentDate.addTimeInterval(8 * 24 * 60 * 60)
        store.pruneStaleSessions(maximumSessionCount: 5, maximumAgeDays: 7)

        XCTAssertFalse(FileManager.default.fileExists(atPath: session.workDirectoryURL.path))
        XCTAssertNil(store.findPausedSession(planSignature: "signature-1", outputTarget: outputTarget))
    }

    func testPlanSignatureChangesWhenRenderPlanChanges() {
        let outputTarget = OutputTarget(
            directory: URL(fileURLWithPath: "/tmp/export-output"),
            baseFilename: "July 2025"
        )

        let baselineSignature = FFmpegProgressiveResumeStore.planSignature(
            for: makeHDRPlan(clipCount: 22, clipDuration: 4.0, transitionDuration: 0.75),
            outputTarget: outputTarget
        )
        let changedSignature = FFmpegProgressiveResumeStore.planSignature(
            for: makeHDRPlan(clipCount: 23, clipDuration: 4.0, transitionDuration: 0.75),
            outputTarget: outputTarget
        )

        XCTAssertNotEqual(baselineSignature, changedSignature)
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeHDRPlan(
        clipCount: Int,
        clipDuration: Double,
        transitionDuration: Double
    ) -> FFmpegRenderPlan {
        FFmpegRenderPlan(
            clips: (0..<clipCount).map { index in
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/source-\(index).mov"),
                    durationSeconds: clipDuration,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(
                        isHDR: true,
                        colorPrimaries: "ITU_R_2020",
                        transferFunction: "ITU_R_2100_HLG"
                    ),
                    sourceDescription: "clip-\(index)"
                )
            },
            transitionDurationSeconds: transitionDuration,
            endFadeToBlackDurationSeconds: max(transitionDuration * 2, 0),
            outputURL: URL(fileURLWithPath: "/tmp/final.mp4"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .hevc,
            dynamicRange: .hdr,
            hdrHEVCEncoderMode: .automatic,
            renderIntent: .finalDelivery
        )
    }
}
