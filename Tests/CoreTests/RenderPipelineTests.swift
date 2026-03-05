import AVFoundation
@testable import Core
import CoreGraphics
import Foundation
import VideoToolbox
import XCTest

final class RenderPipelineTests: XCTestCase {
    func testPlexInfuseAppleTV4KDefaultProfileMatchesLockedDefaults() {
        let profile = ExportProfile.plexInfuseAppleTV4KDefault

        XCTAssertEqual(profile.container, .mp4)
        XCTAssertEqual(profile.videoCodec, .hevc)
        XCTAssertEqual(profile.audioCodec, .aac)
        XCTAssertEqual(profile.resolution, .matchSourceMax)
        XCTAssertEqual(profile.dynamicRange, .hdr)
        XCTAssertEqual(profile.hdrFFmpegBinaryMode, .autoSystemThenBundled)
        XCTAssertEqual(profile.audioLayout, .stereo)
        XCTAssertEqual(profile.bitrateMode, .balanced)
    }

    func testExportProfileManagerDefaultProfileUsesPlexInfuseAppleTV4KDefault() {
        let manager = ExportProfileManager()
        XCTAssertEqual(manager.defaultProfile(), .plexInfuseAppleTV4KDefault)
    }

    func testResolveProfileForHDRForcesHEVCAndStereo() {
        let manager = ExportProfileManager()
        let selected = ExportProfile(
            container: .mp4,
            videoCodec: .h264,
            audioCodec: .aac,
            resolution: .matchSourceMax,
            dynamicRange: .hdr,
            hdrFFmpegBinaryMode: .autoSystemThenBundled,
            audioLayout: .surround51,
            bitrateMode: .balanced
        )

        let resolved = manager.resolveProfile(for: selected)

        XCTAssertEqual(resolved.effectiveProfile.videoCodec, .hevc)
        XCTAssertEqual(resolved.effectiveProfile.audioLayout, .stereo)
        XCTAssertTrue(resolved.warnings.contains { $0.message.contains("adjusted to HEVC") })
        XCTAssertTrue(resolved.warnings.contains { $0.message.contains("adjusted to Stereo") })
    }

    func testResolveProfileForSDRKeepsSelectedCodecAndAudioLayout() {
        let manager = ExportProfileManager()
        let selected = ExportProfile(
            container: .mov,
            videoCodec: .h264,
            audioCodec: .aac,
            resolution: .fixed1080p,
            dynamicRange: .sdr,
            hdrFFmpegBinaryMode: .autoSystemThenBundled,
            audioLayout: .surround51,
            bitrateMode: .sizeFirst
        )

        let resolved = manager.resolveProfile(for: selected)

        XCTAssertEqual(resolved.effectiveProfile.videoCodec, .h264)
        XCTAssertEqual(resolved.effectiveProfile.audioLayout, .surround51)
    }

    func testLongDurationWarningIsProduced() {
        let item = MediaItem(
            id: "video",
            type: .video,
            captureDate: Date(),
            duration: CMTime(seconds: 60 * 21, preferredTimescale: 600),
            pixelSize: CGSize(width: 1920, height: 1080),
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/video.mov")),
            fileSizeBytes: 1_000_000,
            filename: "video.mov"
        )

        let request = RenderRequest(
            source: .folder(path: URL(fileURLWithPath: "/tmp"), recursive: true),
            monthYear: nil,
            ordering: .captureDateAscendingStable,
            style: .stageOneDefault,
            export: .balancedDefault,
            output: OutputTarget(directory: URL(fileURLWithPath: "/tmp"), baseFilename: "x")
        )

        let coordinator = RenderCoordinator()
        let preparation = coordinator.prepareFromItems([item], request: request)

        XCTAssertFalse(preparation.warnings.isEmpty)
    }

    func testSDRColorConfigurationUsesBT709() {
        let engine = AVFoundationRenderEngine()

        let config = engine.colorConfiguration(for: .sdr)

        XCTAssertEqual(config.colorPrimaries, AVVideoColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(config.colorTransferFunction, AVVideoTransferFunction_ITU_R_709_2)
        XCTAssertEqual(config.colorYCbCrMatrix, AVVideoYCbCrMatrix_ITU_R_709_2)
    }

    func testHDRColorConfigurationUsesBT2020HLG() {
        let engine = AVFoundationRenderEngine()

        let config = engine.colorConfiguration(for: .hdr)

        XCTAssertEqual(config.colorPrimaries, AVVideoColorPrimaries_ITU_R_2020)
        XCTAssertEqual(config.colorTransferFunction, AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(config.colorYCbCrMatrix, AVVideoYCbCrMatrix_ITU_R_2020)
    }

    func testHDRProfileEnablesToneMappingPass() {
        let engine = AVFoundationRenderEngine()
        let profile = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            resolution: .matchSourceMax,
            dynamicRange: .hdr,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        XCTAssertTrue(engine.shouldApplyHDRToneMapping(for: profile))
    }

    func testSDRProfileSkipsToneMappingPass() {
        let engine = AVFoundationRenderEngine()
        let profile = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            resolution: .matchSourceMax,
            dynamicRange: .sdr,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        XCTAssertFalse(engine.shouldApplyHDRToneMapping(for: profile))
    }

    func testHDRMatchSourceMaxRenderSizeIsCappedLandscape() {
        let engine = AVFoundationRenderEngine()
        let profile = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            resolution: .matchSourceMax,
            dynamicRange: .hdr,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        let capped = engine.constrainedRenderSizeForExport(
            requestedSize: CGSize(width: 5712, height: 4284),
            profile: profile
        )

        XCTAssertEqual(capped, CGSize(width: 2880, height: 2160))
    }

    func testHDRMatchSourceMaxRenderSizeIsCappedPortrait() {
        let engine = AVFoundationRenderEngine()
        let profile = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            resolution: .matchSourceMax,
            dynamicRange: .hdr,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        let capped = engine.constrainedRenderSizeForExport(
            requestedSize: CGSize(width: 4284, height: 5712),
            profile: profile
        )

        XCTAssertEqual(capped, CGSize(width: 2160, height: 2880))
    }

    func testSDRMatchSourceMaxRenderSizeIsNotCapped() {
        let engine = AVFoundationRenderEngine()
        let profile = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            resolution: .matchSourceMax,
            dynamicRange: .sdr,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        let capped = engine.constrainedRenderSizeForExport(
            requestedSize: CGSize(width: 5712, height: 4284),
            profile: profile
        )

        XCTAssertEqual(capped, CGSize(width: 5712, height: 4284))
    }

    func testHDRMatchSourceMaxCompatibilityWarningMentions4KCap() {
        let manager = ExportProfileManager()
        let profile = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            resolution: .matchSourceMax,
            dynamicRange: .hdr,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        let warnings = manager.compatibilityWarnings(for: profile).map(\.message)

        XCTAssertTrue(warnings.contains { $0.contains("capped to 4K-equivalent dimensions") })
    }

    func testHDRWriterSettingsUseMain10AndAutoMetadataInsertion() {
        let engine = AVFoundationRenderEngine()
        let config = engine.colorConfiguration(for: .hdr)

        let settings = engine.hdrToneMappedVideoSettings(
            renderSize: CGSize(width: 2160, height: 3840),
            frameRate: 30,
            colorConfiguration: config,
            metadataPolicy: .autoRecomputeDynamicMetadata
        )

        let compression = tryUnwrapCompressionSettings(settings)
        let codecType = settings[AVVideoCodecKey] as? AVVideoCodecType
        let codecString = settings[AVVideoCodecKey] as? String
        XCTAssertTrue(codecType == .hevc || codecString == AVVideoCodecType.hevc.rawValue)
        XCTAssertEqual(compression[AVVideoProfileLevelKey] as? String, kVTProfileLevel_HEVC_Main10_AutoLevel as String)
        XCTAssertEqual(
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] as? String,
            kVTHDRMetadataInsertionMode_Auto as String
        )
        XCTAssertEqual(compression[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] as? Bool, false)
    }

    func testHDRWriterSettingsFallbackDisablesDynamicMetadataInsertion() {
        let engine = AVFoundationRenderEngine()
        let config = engine.colorConfiguration(for: .hdr)

        let settings = engine.hdrToneMappedVideoSettings(
            renderSize: CGSize(width: 2160, height: 3840),
            frameRate: 30,
            colorConfiguration: config,
            metadataPolicy: .hlgWithoutDynamicMetadata(reason: "unit test")
        )

        let compression = tryUnwrapCompressionSettings(settings)
        XCTAssertEqual(
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] as? String,
            kVTHDRMetadataInsertionMode_None as String
        )
        XCTAssertEqual(compression[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] as? Bool, false)
    }

    func testToneMapSourceColorSpaceNameUsesHLGForHLGTransfer() {
        let engine = AVFoundationRenderEngine()

        let name = engine.toneMapSourceColorSpaceName(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
            transferFunction: AVVideoTransferFunction_ITU_R_2100_HLG
        )

        XCTAssertEqual(name as String, CGColorSpace.itur_2100_HLG as String)
    }

    func testToneMapSourceColorSpaceNameDefaultsTo709ForUnknownTags() {
        let engine = AVFoundationRenderEngine()

        let name = engine.toneMapSourceColorSpaceName(
            colorPrimaries: nil,
            transferFunction: nil
        )

        XCTAssertEqual(name as String, CGColorSpace.itur_709 as String)
    }

    func testToneMapSourceColorSpaceNameUsesDisplayP3ForP3Primaries() {
        let engine = AVFoundationRenderEngine()

        let name = engine.toneMapSourceColorSpaceName(
            colorPrimaries: AVVideoColorPrimaries_P3_D65,
            transferFunction: AVVideoTransferFunction_ITU_R_709_2
        )

        XCTAssertEqual(name as String, CGColorSpace.displayP3 as String)
    }

    private func tryUnwrapCompressionSettings(_ settings: [String: Any]) -> [String: Any] {
        guard let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] else {
            XCTFail("Missing AVVideoCompressionPropertiesKey in HDR writer settings.")
            return [:]
        }
        return compression
    }
}
