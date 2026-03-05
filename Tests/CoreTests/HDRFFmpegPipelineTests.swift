@testable import Core
import CoreGraphics
import Foundation
import XCTest

final class HDRFFmpegPipelineTests: XCTestCase {
    func testCapabilityProbeParsesRequiredFeatures() {
        let version = "ffmpeg version 7.1-custom"
        let filters = """
         ... zscale            V->V       Apply resizing, colorspace and bit depth conversion.
         ... xfade             VV->V      Cross fade one video with another.
         ... acrossfade        AA->A      Cross fade two input audio streams.
        """
        let encoders = """
         V....D libx265              libx265 H.265 / HEVC
         V....D hevc_videotoolbox    VideoToolbox HEVC
        """

        let capabilities = FFmpegCapabilityProbe.parseCapabilities(
            versionOutput: version,
            filtersOutput: filters,
            encodersOutput: encoders
        )

        XCTAssertTrue(capabilities.hasZscale)
        XCTAssertTrue(capabilities.hasXfade)
        XCTAssertTrue(capabilities.hasAcrossfade)
        XCTAssertTrue(capabilities.hasLibx265)
        XCTAssertTrue(capabilities.supportsQualityHDRPipeline)
        XCTAssertEqual(capabilities.preferredEncoder, .libx265)
    }

    func testBinaryResolverAutoFallsBackToBundledWhenSystemIsMissingZscale() throws {
        let systemBinary = FFmpegBinary(
            ffmpegURL: URL(fileURLWithPath: "/tmp/system/ffmpeg"),
            ffprobeURL: URL(fileURLWithPath: "/tmp/system/ffprobe"),
            source: .system
        )
        let bundledBinary = FFmpegBinary(
            ffmpegURL: URL(fileURLWithPath: "/tmp/bundled/ffmpeg"),
            ffprobeURL: URL(fileURLWithPath: "/tmp/bundled/ffprobe"),
            source: .bundled
        )

        let resolver = FFmpegBinaryResolver(
            systemBinaryOverride: systemBinary,
            bundledBinaryOverride: bundledBinary,
            probeOverride: { binary in
                if binary.source == .system {
                    return FFmpegCapabilities(
                        versionDescription: "system",
                        hasZscale: false,
                        hasXfade: true,
                        hasAcrossfade: true,
                        hasLibx265: true,
                        hasHEVCVideoToolbox: true
                    )
                }
                return FFmpegCapabilities(
                    versionDescription: "bundled",
                    hasZscale: true,
                    hasXfade: true,
                    hasAcrossfade: true,
                    hasLibx265: true,
                    hasHEVCVideoToolbox: false
                )
            }
        )

        let resolution = try resolver.resolve(mode: .autoSystemThenBundled, diagnostics: { _ in })

        XCTAssertEqual(resolution.selectedBinary.source, .bundled)
        XCTAssertNotNil(resolution.fallbackReason)
        XCTAssertTrue(resolution.fallbackReason?.contains("missing required features") ?? false)
    }

    func testBinaryResolverAutoPrefersSystemWhenCapable() throws {
        let systemBinary = FFmpegBinary(
            ffmpegURL: URL(fileURLWithPath: "/tmp/system/ffmpeg"),
            ffprobeURL: URL(fileURLWithPath: "/tmp/system/ffprobe"),
            source: .system
        )

        let resolver = FFmpegBinaryResolver(
            systemBinaryOverride: systemBinary,
            bundledBinaryOverride: nil,
            probeOverride: { _ in
                FFmpegCapabilities(
                    versionDescription: "system",
                    hasZscale: true,
                    hasXfade: true,
                    hasAcrossfade: true,
                    hasLibx265: true,
                    hasHEVCVideoToolbox: true
                )
            }
        )

        let resolution = try resolver.resolve(mode: .autoSystemThenBundled, diagnostics: { _ in })

        XCTAssertEqual(resolution.selectedBinary.source, .system)
        XCTAssertNil(resolution.fallbackReason)
    }

    func testCommandBuilderIncludesHLGMetadataAndTransitions() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = FFmpegBinaryResolution(
            selectedBinary: FFmpegBinary(
                ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"),
                ffprobeURL: URL(fileURLWithPath: "/tmp/ffprobe"),
                source: .bundled
            ),
            selectedCapabilities: FFmpegCapabilities(
                versionDescription: "bundled",
                hasZscale: true,
                hasXfade: true,
                hasAcrossfade: true,
                hasLibx265: true,
                hasHEVCVideoToolbox: false
            ),
            systemCapabilities: nil,
            bundledCapabilities: nil,
            fallbackReason: nil
        )

        let plan = FFmpegHDRRenderPlan(
            clips: [
                FFmpegHDRClip(
                    url: URL(fileURLWithPath: "/tmp/a.mov"),
                    durationSeconds: 3.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: false, colorPrimaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2"),
                    sourceDescription: "clip-a"
                ),
                FFmpegHDRClip(
                    url: URL(fileURLWithPath: "/tmp/b.mov"),
                    durationSeconds: 4.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: true, colorPrimaries: "ITU_R_2020", transferFunction: "ITU_R_2100_HLG"),
                    sourceDescription: "clip-b"
                )
            ],
            transitionDurationSeconds: 0.75,
            outputURL: URL(fileURLWithPath: "/tmp/out.mov"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            bitrateMode: .qualityFirst,
            container: .mov
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("xfade=transition=fade"))
        XCTAssertTrue(joined.contains("acrossfade=d=0.750000"))
        XCTAssertTrue(joined.contains("zscale="))
        XCTAssertFalse(joined.contains("gbrpf32le"))
        XCTAssertTrue(joined.contains("-color_trc arib-std-b67"))
        XCTAssertTrue(joined.contains("-color_primaries bt2020"))
        XCTAssertTrue(joined.contains("-colorspace bt2020nc"))
        XCTAssertTrue(joined.contains("libx265"))
    }

    func testExportProfileCodablePreservesHDRBinaryMode() throws {
        let profile = ExportProfile(
            container: .mov,
            videoCodec: .hevc,
            audioCodec: .aac,
            resolution: .matchSourceMax,
            dynamicRange: .hdr,
            hdrFFmpegBinaryMode: .bundledOnly,
            audioLayout: .stereo,
            bitrateMode: .qualityFirst
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ExportProfile.self, from: data)

        XCTAssertEqual(decoded.hdrFFmpegBinaryMode, .bundledOnly)
    }
}
