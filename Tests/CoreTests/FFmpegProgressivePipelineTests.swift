@testable import Core
import CoreGraphics
import Foundation
import XCTest

final class FFmpegProgressivePipelineTests: XCTestCase {
    func testSmallHDRPlanStaysSinglePass() {
        let builder = FFmpegHDRProgressivePipelineBuilder()
        let plan = makeHDRPlan(clipCount: 5, clipDuration: 4.0, transitionDuration: 0.75)

        let executionPlan = builder.makeExecutionPlan(
            for: plan,
            presentationOutputURL: { index in URL(fileURLWithPath: "/tmp/presentation-\(index).mov") },
            batchOutputURL: { index in URL(fileURLWithPath: "/tmp/batch-\(index).mov") },
            concatListURL: { URL(fileURLWithPath: "/tmp/progressive.ffconcat") },
            concatOutputURL: { URL(fileURLWithPath: "/tmp/progressive.mov") }
        )

        XCTAssertNil(executionPlan)
    }

    func testProgressivePipelineOnlyActivatesForLargeFinalDeliveryHDRHEVCPlans() {
        let builder = FFmpegHDRProgressivePipelineBuilder()
        let finalPlan = makeHDRPlan(clipCount: 22, clipDuration: 4.0, transitionDuration: 0.75)
        let sdrPlan = FFmpegRenderPlan(
            clips: finalPlan.clips,
            transitionDurationSeconds: finalPlan.transitionDurationSeconds,
            endFadeToBlackDurationSeconds: finalPlan.endFadeToBlackDurationSeconds,
            outputURL: finalPlan.outputURL,
            renderSize: finalPlan.renderSize,
            frameRate: finalPlan.frameRate,
            audioLayout: finalPlan.audioLayout,
            bitrateMode: finalPlan.bitrateMode,
            container: finalPlan.container,
            videoCodec: .h264,
            dynamicRange: .sdr,
            renderIntent: .finalDelivery
        )
        let intermediatePlan = FFmpegRenderPlan(
            clips: finalPlan.clips,
            transitionDurationSeconds: finalPlan.transitionDurationSeconds,
            endFadeToBlackDurationSeconds: finalPlan.endFadeToBlackDurationSeconds,
            outputURL: finalPlan.outputURL,
            renderSize: finalPlan.renderSize,
            frameRate: finalPlan.frameRate,
            audioLayout: finalPlan.audioLayout,
            bitrateMode: finalPlan.bitrateMode,
            container: finalPlan.container,
            videoCodec: finalPlan.videoCodec,
            dynamicRange: finalPlan.dynamicRange,
            hdrHEVCEncoderMode: finalPlan.hdrHEVCEncoderMode,
            renderIntent: .intermediateChunk
        )

        XCTAssertNotNil(makeExecutionPlan(builder: builder, plan: finalPlan))
        XCTAssertNil(makeExecutionPlan(builder: builder, plan: sdrPlan))
        XCTAssertNil(makeExecutionPlan(builder: builder, plan: intermediatePlan))
    }

    func testProgressivePipelineBuildsBoundedBatchesAndPreservesDurationMath() throws {
        let builder = FFmpegHDRProgressivePipelineBuilder()
        let commandBuilder = FFmpegCommandBuilder()
        let plan = makeHDRPlan(clipCount: 84, clipDuration: 4.0, transitionDuration: 0.75)

        let executionPlan = try XCTUnwrap(makeExecutionPlan(builder: builder, plan: plan))

        XCTAssertEqual(commandBuilder.expectedDurationSeconds(for: plan), 273.75, accuracy: 0.0001)
        XCTAssertTrue(executionPlan.batchPlans.allSatisfy { $0.sourceClipIndices.count <= 12 })
        XCTAssertTrue(executionPlan.batchPlans.allSatisfy {
            commandBuilder.expectedDurationSeconds(for: $0.plan) <= 90.0001
        })
        XCTAssertEqual(
            executionPlan.slices.reduce(0) { $0 + $1.outputDurationSeconds },
            commandBuilder.expectedDurationSeconds(for: plan),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            executionPlan.batchPlans.reduce(0) { $0 + commandBuilder.expectedDurationSeconds(for: $1.plan) },
            commandBuilder.expectedDurationSeconds(for: plan),
            accuracy: 0.0001
        )
        let finalBatch = try XCTUnwrap(executionPlan.batchPlans.last)
        XCTAssertEqual(executionPlan.presentationPlans.count, plan.clips.count)
        XCTAssertTrue(executionPlan.presentationPlans.allSatisfy { $0.renderIntent == .presentationIntermediate })
        XCTAssertTrue(executionPlan.batchPlans.allSatisfy { $0.plan.renderIntent == .finalBatch })
        XCTAssertEqual(finalBatch.plan.endFadeToBlackDurationSeconds, plan.endFadeToBlackDurationSeconds, accuracy: 0.0001)
        XCTAssertTrue(executionPlan.batchPlans.dropLast().allSatisfy { $0.plan.endFadeToBlackDurationSeconds == 0 })
    }

    func testProgressivePipelineCarriesX265ThreadProfileIntoFinalBatches() throws {
        let builder = FFmpegHDRProgressivePipelineBuilder()
        let plan = FFmpegRenderPlan(
            clips: makeHDRPlan(clipCount: 22, clipDuration: 4.0, transitionDuration: 0.75).clips,
            transitionDurationSeconds: 0.75,
            endFadeToBlackDurationSeconds: 1.5,
            outputURL: URL(fileURLWithPath: "/tmp/final.mp4"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .hevc,
            dynamicRange: .hdr,
            hdrHEVCEncoderMode: .automatic,
            x265ThreadProfile: .shortJobBoost,
            renderIntent: .finalDelivery
        )

        let executionPlan = try XCTUnwrap(makeExecutionPlan(builder: builder, plan: plan))

        XCTAssertTrue(executionPlan.batchPlans.allSatisfy { $0.plan.x265ThreadProfile == .shortJobBoost })
    }

    func testPresentationIntermediatesKeepNormalizationButFinalBatchesAddNoNewColorMath() throws {
        let builder = FFmpegHDRProgressivePipelineBuilder()
        let commandBuilder = FFmpegCommandBuilder()
        let executionPlan = try XCTUnwrap(makeExecutionPlan(builder: builder, plan: makeHDRPlan(clipCount: 22, clipDuration: 4.0, transitionDuration: 0.75)))
        let resolution = makeCapableResolution()

        let presentationCommand = try commandBuilder.buildCommand(
            plan: try XCTUnwrap(executionPlan.presentationPlans.first),
            resolution: resolution
        )
        let batchCommand = try commandBuilder.buildCommand(
            plan: try XCTUnwrap(executionPlan.batchPlans.first?.plan),
            resolution: resolution
        )

        let presentationJoined = presentationCommand.arguments.joined(separator: " ")
        let batchJoined = batchCommand.arguments.joined(separator: " ")

        XCTAssertTrue(presentationJoined.contains("hevc_videotoolbox"))
        XCTAssertTrue(presentationJoined.contains("zscale="))
        XCTAssertTrue(presentationJoined.contains("split=2[vfgsrc0][vbgsrc0]"))
        XCTAssertTrue(presentationJoined.contains("gblur=sigma="))
        XCTAssertTrue(presentationJoined.contains("lutyuv=y=val*"))
        XCTAssertTrue(presentationJoined.contains("overlay=x=(main_w-overlay_w)/2:y=(main_h-overlay_h)/2:shortest=1:format=auto"))

        XCTAssertTrue(batchJoined.contains("libx265"))
        XCTAssertTrue(batchJoined.contains("xfade=transition=fade"))
        XCTAssertTrue(batchJoined.contains("concat=n="))
        XCTAssertFalse(batchJoined.contains("hevc_videotoolbox"))
        XCTAssertFalse(batchJoined.contains("zscale="))
        XCTAssertFalse(batchJoined.contains("tonemap="))
        XCTAssertFalse(batchJoined.contains("eq="))
        XCTAssertFalse(batchJoined.contains("lutyuv="))
        XCTAssertFalse(batchJoined.contains("gblur="))
        XCTAssertFalse(batchJoined.contains("split=2["))
        XCTAssertFalse(batchJoined.contains("overlay=x=(main_w-overlay_w)/2"))
        XCTAssertFalse(batchJoined.contains("overlay=x=main_w-overlay_w-"))
        XCTAssertFalse(batchJoined.contains("fps="))
    }

    func testPackagingCommandCopiesVideoAndMapsChaptersFromFinalPlan() throws {
        let commandBuilder = FFmpegCommandBuilder()
        let chapterMetadataURL = URL(fileURLWithPath: "/tmp/final-chapters.ffmeta")
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/final.mov"),
                    durationSeconds: 4.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: .hlgBT2020Intermediate,
                    sourceDescription: "final"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/final.mp4"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .hevc,
            dynamicRange: .hdr,
            chapters: [
                RenderChapter(
                    kind: .openingTitle,
                    title: "July 2025",
                    startTimeSeconds: 0,
                    endTimeSeconds: 4.0
                )
            ],
            chapterMetadataURL: chapterMetadataURL
        )

        let command = try commandBuilder.buildPackagingCommand(
            executableURL: URL(fileURLWithPath: "/tmp/ffmpeg"),
            concatenatedURL: URL(fileURLWithPath: "/tmp/concatenated.mov"),
            finalPlan: plan
        )
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("-map 0:v:0"))
        XCTAssertTrue(joined.contains("-map 0:a:0"))
        XCTAssertTrue(joined.contains("-map_chapters 1"))
        XCTAssertTrue(joined.contains("-c:v copy"))
        XCTAssertTrue(joined.contains("-tag:v hvc1"))
        XCTAssertTrue(joined.contains("-c:a aac"))
        XCTAssertTrue(joined.contains("-movflags +write_colr"))
        XCTAssertFalse(joined.contains("use_metadata_tags"))
        XCTAssertTrue(joined.contains("-color_primaries bt2020"))
        XCTAssertTrue(joined.contains("-color_trc arib-std-b67"))
        XCTAssertTrue(joined.contains("-colorspace bt2020nc"))
    }

    func testProgressiveIntentEncoderPreferencesPreserveSoftwareFinalDelivery() {
        let capabilities = FFmpegCapabilities(
            versionDescription: "dual-encoder",
            hasZscale: true,
            hasTonemap: true,
            hasXfade: true,
            hasAcrossfade: true,
            hasLibx264: true,
            hasH264VideoToolbox: true,
            hasLibx265: true,
            hasHEVCVideoToolbox: true
        )

        XCTAssertEqual(
            capabilities.preferredEncoder(
                for: .hevc,
                dynamicRange: .hdr,
                hdrHEVCEncoderMode: .automatic,
                renderIntent: .presentationIntermediate
            ),
            .hevcVideoToolbox
        )
        XCTAssertEqual(
            capabilities.preferredEncoder(
                for: .hevc,
                dynamicRange: .hdr,
                hdrHEVCEncoderMode: .automatic,
                renderIntent: .finalBatch
            ),
            .libx265
        )
    }

    func testFinalHDRDeliveryUsesDefaultLibx265TuningWithoutOverride() throws {
        let commandBuilder = FFmpegCommandBuilder()
        let command = try commandBuilder.buildCommand(
            plan: makeHDRPlan(clipCount: 4, clipDuration: 4.0, transitionDuration: 0.75),
            resolution: makeCapableResolution()
        )
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("-preset medium"))
        XCTAssertTrue(joined.contains("-crf 17"))
    }

    func testHDRSizeFirstFastProfileUsesCRF21FastPresetWithoutOverride() throws {
        let commandBuilder = FFmpegCommandBuilder()
        let command = try commandBuilder.buildCommand(
            plan: FFmpegRenderPlan(
                clips: makeHDRPlan(clipCount: 4, clipDuration: 4.0, transitionDuration: 0.75).clips,
                transitionDurationSeconds: 0.75,
                endFadeToBlackDurationSeconds: 1.5,
                outputURL: URL(fileURLWithPath: "/tmp/final.mp4"),
                renderSize: CGSize(width: 3840, height: 2160),
                frameRate: 60,
                audioLayout: .stereo,
                bitrateMode: .sizeFirst,
                container: .mp4,
                videoCodec: .hevc,
                dynamicRange: .hdr,
                hdrHEVCEncoderMode: .automatic,
                x265ThreadProfile: .shortJobBoost,
                renderIntent: .finalDelivery
            ),
            resolution: makeCapableResolution()
        )
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("-preset fast"))
        XCTAssertTrue(joined.contains("-crf 21"))
    }

    func testBakeoffOverrideOnlyChangesFinalSoftwareHEVCCommands() throws {
        let builder = FFmpegHDRProgressivePipelineBuilder()
        let commandBuilder = FFmpegCommandBuilder()
        let plan = FFmpegRenderPlan(
            clips: makeHDRPlan(clipCount: 22, clipDuration: 4.0, transitionDuration: 0.75).clips,
            transitionDurationSeconds: 0.75,
            endFadeToBlackDurationSeconds: 1.5,
            outputURL: URL(fileURLWithPath: "/tmp/final.mp4"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .hevc,
            dynamicRange: .hdr,
            hdrHEVCEncoderMode: .automatic,
            finalHEVCTuningOverride: FinalHEVCTuningOverride(preset: "slow", crf: 18),
            renderIntent: .finalDelivery
        )

        let executionPlan = try XCTUnwrap(makeExecutionPlan(builder: builder, plan: plan))
        let presentationCommand = try commandBuilder.buildCommand(
            plan: try XCTUnwrap(executionPlan.presentationPlans.first),
            resolution: makeSoftwareOnlyResolution()
        )
        let batchCommand = try commandBuilder.buildCommand(
            plan: try XCTUnwrap(executionPlan.batchPlans.first?.plan),
            resolution: makeSoftwareOnlyResolution()
        )

        let presentationJoined = presentationCommand.arguments.joined(separator: " ")
        let batchJoined = batchCommand.arguments.joined(separator: " ")

        XCTAssertTrue(presentationJoined.contains("-preset medium"))
        XCTAssertFalse(presentationJoined.contains("-crf 18"))
        XCTAssertTrue(batchJoined.contains("-preset slow"))
        XCTAssertTrue(batchJoined.contains("-crf 18"))
    }

    private func makeExecutionPlan(
        builder: FFmpegHDRProgressivePipelineBuilder,
        plan: FFmpegRenderPlan
    ) -> FFmpegHDRProgressiveExecutionPlan? {
        builder.makeExecutionPlan(
            for: plan,
            presentationOutputURL: { index in URL(fileURLWithPath: "/tmp/presentation-\(index).mov") },
            batchOutputURL: { index in URL(fileURLWithPath: "/tmp/batch-\(index).mov") },
            concatListURL: { URL(fileURLWithPath: "/tmp/progressive.ffconcat") },
            concatOutputURL: { URL(fileURLWithPath: "/tmp/progressive.mov") }
        )
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

    private func makeCapableResolution() -> FFmpegBinaryResolution {
        FFmpegBinaryResolution(
            selectedBinary: FFmpegBinary(
                ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"),
                ffprobeURL: URL(fileURLWithPath: "/tmp/ffprobe"),
                source: .system
            ),
            selectedCapabilities: FFmpegCapabilities(
                versionDescription: "system",
                hasZscale: true,
                hasTonemap: true,
                hasXfade: true,
                hasAcrossfade: true,
                hasLibx264: true,
                hasH264VideoToolbox: true,
                hasLibx265: true,
                hasHEVCVideoToolbox: true
            ),
            systemCapabilities: nil,
            bundledCapabilities: nil,
            fallbackReason: nil
        )
    }

    private func makeSoftwareOnlyResolution() -> FFmpegBinaryResolution {
        FFmpegBinaryResolution(
            selectedBinary: FFmpegBinary(
                ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"),
                ffprobeURL: URL(fileURLWithPath: "/tmp/ffprobe"),
                source: .system
            ),
            selectedCapabilities: FFmpegCapabilities(
                versionDescription: "system",
                hasZscale: true,
                hasTonemap: true,
                hasXfade: true,
                hasAcrossfade: true,
                hasLibx264: true,
                hasH264VideoToolbox: true,
                hasLibx265: true,
                hasHEVCVideoToolbox: false
            ),
            systemCapabilities: nil,
            bundledCapabilities: nil,
            fallbackReason: nil
        )
    }
}
