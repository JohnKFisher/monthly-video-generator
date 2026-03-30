import AVFoundation
@testable import Core
import CoreGraphics
import Foundation
import VideoToolbox
import XCTest

final class RenderPipelineTests: XCTestCase {
    func testPhotosScopeAlbumDescriptionUsesTitleWhenAvailable() {
        let scope = PhotosScope.album(localIdentifier: "abc123", title: "Family")
        XCTAssertEqual(scope.description, "Album: Family")
    }

    func testPhotosScopeAlbumDescriptionFallsBackToIdentifier() {
        let scope = PhotosScope.album(localIdentifier: "abc123", title: nil)
        XCTAssertEqual(scope.description, "Album (id: abc123)")
    }

    func testPhotosScopeAlbumCodableRoundTrip() throws {
        let scope = PhotosScope.album(localIdentifier: "album-id-1", title: "Trips")
        let data = try JSONEncoder().encode(scope)
        let decoded = try JSONDecoder().decode(PhotosScope.self, from: data)
        XCTAssertEqual(decoded, scope)
    }

    func testPlexInfuseAppleTV4KDefaultProfileMatchesLockedDefaults() {
        let profile = ExportProfile.plexInfuseAppleTV4KDefault

        XCTAssertEqual(profile.container, .mp4)
        XCTAssertEqual(profile.videoCodec, .hevc)
        XCTAssertEqual(profile.audioCodec, .aac)
        XCTAssertEqual(profile.frameRate, .smart)
        XCTAssertEqual(profile.resolution, .smart)
        XCTAssertEqual(profile.dynamicRange, .hdr)
        XCTAssertEqual(profile.hdrFFmpegBinaryMode, .bundledPreferred)
        XCTAssertEqual(profile.hdrHEVCEncoderMode, .automatic)
        XCTAssertEqual(profile.audioLayout, .smart)
        XCTAssertEqual(profile.bitrateMode, .balanced)
    }

    func testExportProfileManagerDefaultProfileUsesPlexInfuseAppleTV4KDefault() {
        let manager = ExportProfileManager()
        XCTAssertEqual(manager.defaultProfile(), .plexInfuseAppleTV4KDefault)
    }

    func testResolveProfileForHDRForcesHEVCButKeepsSelectedAudioLayout() {
        let manager = ExportProfileManager()
        let selected = ExportProfile(
            container: .mp4,
            videoCodec: .h264,
            audioCodec: .aac,
            frameRate: .smart,
            resolution: .matchSourceMax,
            dynamicRange: .hdr,
            hdrFFmpegBinaryMode: .bundledPreferred,
            audioLayout: .surround51,
            bitrateMode: .balanced
        )

        let resolved = manager.resolveProfile(for: selected)

        XCTAssertEqual(resolved.effectiveProfile.resolution, .smart)
        XCTAssertEqual(resolved.effectiveProfile.videoCodec, .hevc)
        XCTAssertEqual(resolved.effectiveProfile.audioLayout, .surround51)
        XCTAssertTrue(resolved.warnings.contains { $0.message.contains("adjusted to HEVC") })
        XCTAssertFalse(resolved.warnings.contains { $0.message.contains("adjusted to Stereo") })
    }

    func testResolveProfileForSDRKeepsSelectedCodecAndAudioLayout() {
        let manager = ExportProfileManager()
        let selected = ExportProfile(
            container: .mov,
            videoCodec: .h264,
            audioCodec: .aac,
            frameRate: .fps30,
            resolution: .fixed1080p,
            dynamicRange: .sdr,
            hdrFFmpegBinaryMode: .bundledPreferred,
            audioLayout: .surround51,
            bitrateMode: .sizeFirst
        )

        let resolved = manager.resolveProfile(for: selected)

        XCTAssertEqual(resolved.effectiveProfile.videoCodec, .h264)
        XCTAssertEqual(resolved.effectiveProfile.audioLayout, .surround51)
    }

    func testResolveProfileForSmartAudioChoosesMonoWhenAllVideosAreMonoOrSilent() {
        let manager = ExportProfileManager()
        let selected = ExportProfile(
            container: .mov,
            videoCodec: .h264,
            audioCodec: .aac,
            frameRate: .fps30,
            resolution: .fixed1080p,
            dynamicRange: .sdr,
            hdrFFmpegBinaryMode: .bundledPreferred,
            audioLayout: .smart,
            bitrateMode: .balanced
        )

        let resolved = manager.resolveProfile(
            for: selected,
            items: [
                makeVideoMediaItem(frameRate: 30, audioChannelCount: 1),
                makeVideoMediaItem(frameRate: 30, audioChannelCount: 0)
            ]
        )

        XCTAssertEqual(resolved.effectiveProfile.audioLayout, .mono)
    }

    func testResolveProfileForSmartAudioChoosesStereoWhenAnyVideoIsStereo() {
        let manager = ExportProfileManager()
        let selected = ExportProfile(
            container: .mov,
            videoCodec: .h264,
            audioCodec: .aac,
            frameRate: .fps30,
            resolution: .fixed1080p,
            dynamicRange: .sdr,
            hdrFFmpegBinaryMode: .bundledPreferred,
            audioLayout: .smart,
            bitrateMode: .balanced
        )

        let resolved = manager.resolveProfile(
            for: selected,
            items: [
                makeVideoMediaItem(frameRate: 30, audioChannelCount: 1),
                makeVideoMediaItem(frameRate: 30, audioChannelCount: 2)
            ]
        )

        XCTAssertEqual(resolved.effectiveProfile.audioLayout, .stereo)
    }

    func testResolveProfileForSmartAudioChooses51WhenAnyVideoExceedsStereo() {
        let manager = ExportProfileManager()
        let selected = ExportProfile(
            container: .mov,
            videoCodec: .h264,
            audioCodec: .aac,
            frameRate: .fps30,
            resolution: .fixed1080p,
            dynamicRange: .sdr,
            hdrFFmpegBinaryMode: .bundledPreferred,
            audioLayout: .smart,
            bitrateMode: .balanced
        )

        let resolved = manager.resolveProfile(
            for: selected,
            items: [
                makeVideoMediaItem(frameRate: 30, audioChannelCount: 2),
                makeVideoMediaItem(frameRate: 30, audioChannelCount: 6)
            ]
        )

        XCTAssertEqual(resolved.effectiveProfile.audioLayout, .surround51)
    }

    func testResolveProfileForSmartAudioFallsBackTo51WhenVideoAudioIsUnknown() {
        let manager = ExportProfileManager()
        let selected = ExportProfile(
            container: .mov,
            videoCodec: .h264,
            audioCodec: .aac,
            frameRate: .fps30,
            resolution: .fixed1080p,
            dynamicRange: .sdr,
            hdrFFmpegBinaryMode: .bundledPreferred,
            audioLayout: .smart,
            bitrateMode: .balanced
        )

        let resolved = manager.resolveProfile(
            for: selected,
            items: [makeVideoMediaItem(frameRate: 30, audioChannelCount: nil)]
        )

        XCTAssertEqual(resolved.effectiveProfile.audioLayout, .surround51)
        XCTAssertTrue(resolved.warnings.contains { $0.message.contains("raised to 5.1") })
    }

    func testResolutionPolicyDecodesLegacyMatchSourceMaxAsSmart() throws {
        let data = Data(#""matchSourceMax""#.utf8)

        let decoded = try JSONDecoder().decode(ResolutionPolicy.self, from: data)

        XCTAssertEqual(decoded, .smart)
    }

    func testResolutionPolicyEncodesLegacyMatchSourceMaxAsSmart() throws {
        let data = try JSONEncoder().encode(ResolutionPolicy.matchSourceMax)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(encoded, #""smart""#)
    }

    func testExportProfileDecodesMissingFrameRateAsSmart() throws {
        let json = """
        {
          "audioCodec": "aac",
          "audioLayout": "stereo",
          "bitrateMode": "balanced",
          "container": "mp4",
          "dynamicRange": "hdr",
          "hdrFFmpegBinaryMode": "autoSystemThenBundled",
          "resolution": "smart",
          "videoCodec": "hevc"
        }
        """

        let decoded = try JSONDecoder().decode(ExportProfile.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.frameRate, .smart)
    }

    func testExportProfileDecodesMissingHDRHEVCEncoderModeAsAutomatic() throws {
        let json = """
        {
          "audioCodec": "aac",
          "audioLayout": "stereo",
          "bitrateMode": "balanced",
          "container": "mp4",
          "dynamicRange": "hdr",
          "frameRate": "smart",
          "hdrFFmpegBinaryMode": "autoSystemThenBundled",
          "resolution": "smart",
          "videoCodec": "hevc"
        }
        """

        let decoded = try JSONDecoder().decode(ExportProfile.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.hdrHEVCEncoderMode, .automatic)
    }

    func testSmartRenderSizeChooses720p() {
        let renderSize = RenderSizing.renderSize(
            for: [
                makeMediaItem(size: CGSize(width: 960, height: 540)),
                makeMediaItem(size: CGSize(width: 1280, height: 720))
            ],
            policy: .smart
        )

        XCTAssertEqual(renderSize, RenderSizing.fixed720p)
    }

    func testSmartRenderSizeChooses1080p() {
        let renderSize = RenderSizing.renderSize(
            for: [
                makeMediaItem(size: CGSize(width: 1440, height: 1080)),
                makeMediaItem(size: CGSize(width: 1920, height: 1080))
            ],
            policy: .smart
        )

        XCTAssertEqual(renderSize, RenderSizing.fixed1080p)
    }

    func testSmartRenderSizeChooses4KWhenNeeded() {
        let renderSize = RenderSizing.renderSize(
            for: [
                makeMediaItem(size: CGSize(width: 3840, height: 2160)),
                makeMediaItem(size: CGSize(width: 2400, height: 1350))
            ],
            policy: .smart
        )

        XCTAssertEqual(renderSize, RenderSizing.fixed4K)
    }

    func testSmartRenderSizeFallsBackTo4KWhenNoLosslessTierFits() {
        let renderSize = RenderSizing.renderSize(
            for: [makeMediaItem(size: CGSize(width: 3024, height: 4032))],
            policy: .smart
        )

        XCTAssertEqual(renderSize, RenderSizing.fixed4K)
    }

    func testFrameRateResolverChooses30ForPhotoOnlySelections() {
        let frameRate = RenderSizing.frameRate(
            for: [makeMediaItem(size: CGSize(width: 1920, height: 1080))],
            policy: .smart
        )

        XCTAssertEqual(frameRate, 30)
    }

    func testFrameRateResolverChooses30ForVideoUnderThreshold() {
        let frameRate = RenderSizing.frameRate(
            for: [makeVideoMediaItem(frameRate: 30)],
            policy: .smart
        )

        XCTAssertEqual(frameRate, 30)
    }

    func testFrameRateResolverChooses60WhenAnyVideoMeetsThreshold() {
        let frameRate = RenderSizing.frameRate(
            for: [makeVideoMediaItem(frameRate: 29.97), makeVideoMediaItem(frameRate: 59.94)],
            policy: .smart
        )

        XCTAssertEqual(frameRate, 60)
    }

    func testFrameRateResolverTreatsUnknownFrameRateAsNonTriggering() {
        let frameRate = RenderSizing.frameRate(
            for: [makeVideoMediaItem(frameRate: nil)],
            policy: .smart
        )

        XCTAssertEqual(frameRate, 30)
    }

    func testLongDurationWarningIsProduced() {
        let item = MediaItem(
            id: "video",
            type: .video,
            captureDate: Date(),
            duration: CMTime(seconds: 60 * 21, preferredTimescale: 600),
            sourceFrameRate: 30,
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
            frameRate: .smart,
            resolution: .smart,
            dynamicRange: .hdr,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        XCTAssertTrue(engine.shouldApplyHDRToneMapping(for: profile))
    }

    func testHDRX265ThreadProfileMapsExplicitHDRSpeedSelection() {
        let engine = AVFoundationRenderEngine()

        XCTAssertEqual(
            engine.x265ThreadProfile(
                for: .slow,
                dynamicRange: .hdr,
                videoCodec: .hevc
            ),
            .conservative
        )
        XCTAssertEqual(
            engine.x265ThreadProfile(
                for: .medium,
                dynamicRange: .hdr,
                videoCodec: .hevc
            ),
            .balanced
        )
        XCTAssertEqual(
            engine.x265ThreadProfile(
                for: .fast,
                dynamicRange: .hdr,
                videoCodec: .hevc
            ),
            .shortJobBoost
        )
    }

    func testHDRX265ThreadProfileStaysConservativeForNonHDRHEVCPlans() {
        let engine = AVFoundationRenderEngine()

        XCTAssertEqual(
            engine.x265ThreadProfile(
                for: .fast,
                dynamicRange: .sdr,
                videoCodec: .hevc
            ),
            .conservative
        )
        XCTAssertEqual(
            engine.x265ThreadProfile(
                for: .fast,
                dynamicRange: .hdr,
                videoCodec: .h264
            ),
            .conservative
        )
    }

    func testSDRProfileSkipsToneMappingPass() {
        let engine = AVFoundationRenderEngine()
        let profile = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            frameRate: .smart,
            resolution: .smart,
            dynamicRange: .sdr,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        XCTAssertFalse(engine.shouldApplyHDRToneMapping(for: profile))
    }

    func testSmartCompatibilityWarningDescribesTierSelection() {
        let manager = ExportProfileManager()
        let profile = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            frameRate: .smart,
            resolution: .smart,
            dynamicRange: .hdr,
            audioLayout: .smart,
            bitrateMode: .balanced
        )

        let warnings = manager.compatibilityWarnings(for: profile).map(\.message)

        XCTAssertTrue(warnings.contains { $0.contains("smallest 16:9 output tier") })
        XCTAssertTrue(warnings.contains { $0.contains("Smart frame rate exports at 30 fps") })
        XCTAssertTrue(warnings.contains { $0.contains("Smart audio chooses Mono") })
    }

    func testFixed60FPSCompatibilityWarningMentionsCost() {
        let manager = ExportProfileManager()
        let profile = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            frameRate: .fps60,
            resolution: .smart,
            dynamicRange: .sdr,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        let warnings = manager.compatibilityWarnings(for: profile).map(\.message)

        XCTAssertTrue(warnings.contains { $0.contains("60 fps output increases render time") })
    }

    func testAspectFitTransformCentersFourByThreeLandscapeVideoWithinFrame() {
        let transform = RenderSizing.aspectFitTransform(
            naturalSize: CGSize(width: 1440, height: 1080),
            preferredTransform: .identity,
            renderSize: RenderSizing.fixed1080p
        )
        let transformedBounds = CGRect(origin: .zero, size: CGSize(width: 1440, height: 1080)).applying(transform)

        XCTAssertEqual(transformedBounds.width, 1440, accuracy: 0.001)
        XCTAssertEqual(transformedBounds.height, 1080, accuracy: 0.001)
        XCTAssertEqual(transformedBounds.minX, 240, accuracy: 0.001)
        XCTAssertEqual(transformedBounds.minY, 0, accuracy: 0.001)
        XCTAssertEqual(transformedBounds.midX, RenderSizing.fixed1080p.width / 2.0, accuracy: 0.001)
    }

    func testAspectFitTransformCentersPortraitVideoWithinFrame() {
        let portraitTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let transform = RenderSizing.aspectFitTransform(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: portraitTransform,
            renderSize: RenderSizing.fixed1080p
        )
        let transformedBounds = CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080)).applying(transform)

        XCTAssertEqual(transformedBounds.width, 607.5, accuracy: 0.001)
        XCTAssertEqual(transformedBounds.height, 1080, accuracy: 0.001)
        XCTAssertEqual(transformedBounds.minX, 656.25, accuracy: 0.001)
        XCTAssertEqual(transformedBounds.minY, 0, accuracy: 0.001)
        XCTAssertEqual(transformedBounds.midX, RenderSizing.fixed1080p.width / 2.0, accuracy: 0.001)
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

    func testColorInfoInfersSDRTransferFlavorByDefault() {
        let colorInfo = ColorInfo(
            isHDR: false,
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            transferFunction: AVVideoTransferFunction_ITU_R_709_2
        )

        XCTAssertEqual(colorInfo.transferFlavor, .sdr)
        XCTAssertEqual(colorInfo.hdrMetadataFlavor, .none)
        XCTAssertFalse(colorInfo.isHDR)
    }

    func testColorInfoInfersHLGTransferFlavor() {
        let colorInfo = ColorInfo(
            isHDR: true,
            colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
            transferFunction: AVVideoTransferFunction_ITU_R_2100_HLG
        )

        XCTAssertEqual(colorInfo.transferFlavor, .hlg)
        XCTAssertTrue(colorInfo.isHDR)
    }

    func testColorInfoInfersPQTransferFlavor() {
        let colorInfo = ColorInfo(
            isHDR: true,
            colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
            transferFunction: AVVideoTransferFunction_SMPTE_ST_2084_PQ
        )

        XCTAssertEqual(colorInfo.transferFlavor, .pq)
        XCTAssertTrue(colorInfo.isHDR)
    }

    func testColorInfoPreservesDolbyVisionMetadataFlavor() {
        let colorInfo = ColorInfo(
            isHDR: true,
            colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
            transferFunction: AVVideoTransferFunction_ITU_R_2100_HLG,
            transferFlavor: .hlg,
            hdrMetadataFlavor: .dolbyVision
        )

        XCTAssertEqual(colorInfo.hdrMetadataFlavor, .dolbyVision)
        XCTAssertTrue(colorInfo.usesDolbyVisionFallback)
        XCTAssertTrue(colorInfo.isHDR)
    }

    private func tryUnwrapCompressionSettings(_ settings: [String: Any]) -> [String: Any] {
        guard let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] else {
            XCTFail("Missing AVVideoCompressionPropertiesKey in HDR writer settings.")
            return [:]
        }
        return compression
    }

    private func makeMediaItem(size: CGSize) -> MediaItem {
        MediaItem(
            id: UUID().uuidString,
            type: .image,
            captureDate: Date(),
            duration: nil,
            pixelSize: size,
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg")),
            fileSizeBytes: 1_000,
            filename: "fixture.jpg"
        )
    }

    private func makeVideoMediaItem(frameRate: Double?, audioChannelCount: Int? = 2) -> MediaItem {
        MediaItem(
            id: UUID().uuidString,
            type: .video,
            captureDate: Date(),
            duration: CMTime(seconds: 2, preferredTimescale: 600),
            sourceFrameRate: frameRate,
            sourceAudioChannelCount: audioChannelCount,
            pixelSize: CGSize(width: 1920, height: 1080),
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mov")),
            fileSizeBytes: 1_000,
            filename: "fixture.mov"
        )
    }
}
