@testable import Core
import CoreGraphics
import Foundation
import XCTest

final class FFmpegChunkedPipelineTests: XCTestCase {
    func testSmallHDRPlanStaysSinglePass() {
        let builder = FFmpegHDRChunkPipelineBuilder()
        let plan = makeHDRPlan(clipCount: 5, clipDuration: 3.0, transitionDuration: 0.75)

        let executionPlan = builder.makeExecutionPlan(for: plan) { index in
            URL(fileURLWithPath: "/tmp/chunk-\(index).mov")
        }

        XCTAssertNil(executionPlan)
    }

    func testTwentyTwoClipHDRPlanSplitsIntoBoundedChunksAndPreservesOrder() {
        let builder = FFmpegHDRChunkPipelineBuilder()
        let plan = makeHDRPlan(clipCount: 22, clipDuration: 4.0, transitionDuration: 0.75)

        guard let executionPlan = builder.makeExecutionPlan(for: plan, intermediateOutputURL: { index in
            URL(fileURLWithPath: "/tmp/chunk-\(index).mov")
        }) else {
            return XCTFail("Expected chunked execution plan")
        }

        XCTAssertEqual(executionPlan.chunkPlan.chunks.count, 3)
        XCTAssertEqual(executionPlan.chunkPlan.chunks.map(\.clips.count), [10, 10, 2])
        XCTAssertTrue(executionPlan.chunkPlan.chunks.allSatisfy { $0.clips.count <= FFmpegHDRChunkPlanner.defaultMaxClipsPerChunk })

        let flattenedDescriptions = executionPlan.chunkPlan.chunks
            .flatMap(\.clips)
            .map(\.sourceDescription)
        XCTAssertEqual(flattenedDescriptions, plan.clips.map(\.sourceDescription))

        XCTAssertEqual(executionPlan.finalPlan.clips.count, 3)
        XCTAssertEqual(executionPlan.finalPlan.clips.map(\.captureDateOverlayURL), [nil, nil, nil])
    }

    func testLargeHDRPlanProducesBoundedChunksAndPreservesDurationMath() {
        let builder = FFmpegHDRChunkPipelineBuilder()
        let commandBuilder = FFmpegCommandBuilder()
        let plan = makeHDRPlan(clipCount: 1_000, clipDuration: 3.5, transitionDuration: 0.75)

        guard let executionPlan = builder.makeExecutionPlan(for: plan, intermediateOutputURL: { index in
            URL(fileURLWithPath: "/tmp/chunk-\(index).mov")
        }) else {
            return XCTFail("Expected chunked execution plan")
        }

        XCTAssertTrue(executionPlan.chunkPlan.chunks.allSatisfy { $0.clips.count <= FFmpegHDRChunkPlanner.defaultMaxClipsPerChunk })
        XCTAssertTrue(executionPlan.chunkPlan.chunks.allSatisfy { $0.expectedDurationSeconds <= FFmpegHDRChunkPlanner.defaultMaxChunkDurationSeconds })
        XCTAssertEqual(
            commandBuilder.expectedDurationSeconds(for: executionPlan.finalPlan),
            commandBuilder.expectedDurationSeconds(for: plan),
            accuracy: 0.0001
        )
    }

    func testChunkPipelineOnlyActivatesForFinalDeliveryHDRHEVCPlans() {
        let builder = FFmpegHDRChunkPipelineBuilder()
        let finalIntentPlan = makeHDRPlan(clipCount: 22, clipDuration: 4.0, transitionDuration: 0.75)
        let intermediateIntentPlan = FFmpegRenderPlan(
            clips: finalIntentPlan.clips,
            transitionDurationSeconds: finalIntentPlan.transitionDurationSeconds,
            outputURL: finalIntentPlan.outputURL,
            renderSize: finalIntentPlan.renderSize,
            frameRate: finalIntentPlan.frameRate,
            audioLayout: finalIntentPlan.audioLayout,
            bitrateMode: finalIntentPlan.bitrateMode,
            container: finalIntentPlan.container,
            videoCodec: finalIntentPlan.videoCodec,
            dynamicRange: finalIntentPlan.dynamicRange,
            hdrHEVCEncoderMode: finalIntentPlan.hdrHEVCEncoderMode,
            renderIntent: .intermediateChunk
        )

        XCTAssertNotNil(builder.makeExecutionPlan(for: finalIntentPlan, intermediateOutputURL: { index in
            URL(fileURLWithPath: "/tmp/chunk-\(index).mov")
        }))
        XCTAssertNil(builder.makeExecutionPlan(for: intermediateIntentPlan, intermediateOutputURL: { index in
            URL(fileURLWithPath: "/tmp/chunk-\(index).mov")
        }))
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
            outputURL: URL(fileURLWithPath: "/tmp/final.mov"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mov,
            videoCodec: .hevc,
            dynamicRange: .hdr,
            hdrHEVCEncoderMode: .automatic,
            renderIntent: .finalDelivery
        )
    }
}
