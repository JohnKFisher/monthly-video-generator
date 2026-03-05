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
        XCTAssertTrue(joined.contains(":a:0]atrim"))
        XCTAssertTrue(joined.contains("zscale="))
        XCTAssertFalse(joined.contains("gbrpf32le"))
        XCTAssertTrue(joined.contains("-stats_period 0.5"))
        XCTAssertTrue(joined.contains("-color_trc arib-std-b67"))
        XCTAssertTrue(joined.contains("-color_primaries bt2020"))
        XCTAssertTrue(joined.contains("-colorspace bt2020nc"))
        XCTAssertTrue(joined.contains("libx265"))
    }

    func testProgressParserReadsOutTimeUS() {
        var parser = FFmpegProgressParser()
        parser.ingest(line: "out_time_us=1500000")
        let progress = parser.progress(totalDurationMicroseconds: 3_000_000)
        XCTAssertEqual(progress, 0.5, accuracy: 0.0001)
    }

    func testProgressParserReadsOutTimeMS() {
        var parser = FFmpegProgressParser()
        parser.ingest(line: "out_time_ms=600000")
        let progress = parser.progress(totalDurationMicroseconds: 3_000_000)
        XCTAssertEqual(progress, 0.2, accuracy: 0.0001)
    }

    func testProgressParserTracksSpeedAndTotalSize() {
        var parser = FFmpegProgressParser()
        parser.ingest(line: "total_size=123456789")
        parser.ingest(line: "speed=1.37x")

        XCTAssertEqual(parser.latestTotalSizeBytes, 123_456_789)
        XCTAssertEqual(parser.latestSpeed ?? 0, 1.37, accuracy: 0.0001)
    }

    func testProgressParserEmitsStructuredUpdateAtProgressBoundary() {
        var parser = FFmpegProgressParser()
        parser.ingest(line: "out_time_us=2200000")
        parser.ingest(line: "total_size=99887766")
        parser.ingest(line: "speed=0.82x")
        let update = parser.ingest(line: "progress=continue")

        XCTAssertNotNil(update)
        XCTAssertEqual(update?.outTimeMicroseconds, 2_200_000)
        XCTAssertEqual(update?.totalSizeBytes, 99_887_766)
        XCTAssertEqual(update?.speed ?? 0, 0.82, accuracy: 0.0001)
        XCTAssertEqual(update?.state, "continue")
        XCTAssertEqual(update?.isTerminal, false)
    }

    func testProgressParserMarksTerminalProgressUpdate() {
        var parser = FFmpegProgressParser()
        let update = parser.ingest(line: "progress=end")

        XCTAssertEqual(update?.state, "end")
        XCTAssertEqual(update?.isTerminal, true)
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
