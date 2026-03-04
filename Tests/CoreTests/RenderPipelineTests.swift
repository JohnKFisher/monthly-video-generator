import AVFoundation
@testable import Core
import Foundation
import VideoToolbox
import XCTest

final class RenderPipelineTests: XCTestCase {
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

    private func tryUnwrapCompressionSettings(_ settings: [String: Any]) -> [String: Any] {
        guard let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] else {
            XCTFail("Missing AVVideoCompressionPropertiesKey in HDR writer settings.")
            return [:]
        }
        return compression
    }
}
