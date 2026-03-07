@testable import Core
import CoreGraphics
import Darwin
import Foundation
import XCTest

final class HDRFFmpegPipelineTests: XCTestCase {
    func testRendererClosesParentPipeWriteEndsAfterLaunch() {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutWriteFD = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrWriteFD = stderrPipe.fileHandleForWriting.fileDescriptor

        FFmpegHDRRenderer.closeUnusedPipeWriteEnds(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        errno = 0
        XCTAssertEqual(fcntl(stdoutWriteFD, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)

        errno = 0
        XCTAssertEqual(fcntl(stderrWriteFD, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testCapabilityProbeParsesRequiredFeatures() {
        let version = "ffmpeg version 7.1-custom"
        let filters = """
         ... zscale            V->V       Apply resizing, colorspace and bit depth conversion.
         ... tonemap           V->V       Conversion to/from different dynamic ranges.
         ... xfade             VV->V      Cross fade one video with another.
         ... acrossfade        AA->A      Cross fade two input audio streams.
         ... overlay           VV->V      Overlay a video source on top of the input.
        """
        let encoders = """
         V....D libx264              libx264 H.264 / AVC
         V....D h264_videotoolbox    VideoToolbox H.264
         V....D libx265              libx265 H.265 / HEVC
         V....D hevc_videotoolbox    VideoToolbox HEVC
        """

        let capabilities = FFmpegCapabilityProbe.parseCapabilities(
            versionOutput: version,
            filtersOutput: filters,
            encodersOutput: encoders
        )

        XCTAssertTrue(capabilities.hasZscale)
        XCTAssertTrue(capabilities.hasTonemap)
        XCTAssertTrue(capabilities.hasXfade)
        XCTAssertTrue(capabilities.hasAcrossfade)
        XCTAssertTrue(capabilities.hasOverlay)
        XCTAssertTrue(capabilities.hasLibx264)
        XCTAssertTrue(capabilities.hasLibx265)
        XCTAssertTrue(capabilities.supportsRenderPipeline(codec: .hevc, dynamicRange: .hdr))
        XCTAssertEqual(capabilities.preferredEncoder(for: .hevc, dynamicRange: .hdr), .libx265)
        XCTAssertEqual(capabilities.preferredEncoder(for: .h264, dynamicRange: .sdr), .h264VideoToolbox)
    }

    func testHDRAutomaticFallsBackToVideoToolboxWhenLibx265IsUnavailable() {
        let capabilities = FFmpegCapabilities(
            versionDescription: "vt-only",
            hasZscale: true,
            hasTonemap: true,
            hasXfade: true,
            hasAcrossfade: true,
            hasLibx264: true,
            hasH264VideoToolbox: true,
            hasLibx265: false,
            hasHEVCVideoToolbox: true
        )

        XCTAssertEqual(
            capabilities.preferredEncoder(
                for: .hevc,
                dynamicRange: .hdr,
                hdrHEVCEncoderMode: .automatic
            ),
            .hevcVideoToolbox
        )
    }

    func testHDRVideoToolboxModeRequiresVideoToolboxEncoder() {
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
                hdrHEVCEncoderMode: .videoToolbox
            ),
            .hevcVideoToolbox
        )
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
                        hasTonemap: true,
                        hasXfade: true,
                        hasAcrossfade: true,
                        hasLibx264: true,
                        hasH264VideoToolbox: true,
                        hasLibx265: true,
                        hasHEVCVideoToolbox: true
                    )
                }
                return FFmpegCapabilities(
                    versionDescription: "bundled",
                    hasZscale: true,
                    hasTonemap: true,
                    hasXfade: true,
                    hasAcrossfade: true,
                    hasLibx264: true,
                    hasH264VideoToolbox: true,
                    hasLibx265: true,
                    hasHEVCVideoToolbox: false
                )
            }
        )

        let resolution = try resolver.resolve(
            mode: .autoSystemThenBundled,
            codec: .hevc,
            dynamicRange: .hdr,
            diagnostics: { _ in }
        )

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
                    hasTonemap: true,
                    hasXfade: true,
                    hasAcrossfade: true,
                    hasLibx264: true,
                    hasH264VideoToolbox: true,
                    hasLibx265: true,
                    hasHEVCVideoToolbox: true
                )
            }
        )

        let resolution = try resolver.resolve(
            mode: .autoSystemThenBundled,
            codec: .hevc,
            dynamicRange: .hdr,
            diagnostics: { _ in }
        )

        XCTAssertEqual(resolution.selectedBinary.source, .system)
        XCTAssertNil(resolution.fallbackReason)
    }

    func testBinaryResolverSystemOnlyFailsWhenHDRVideoToolboxModeIsUnavailable() {
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
                    hasTonemap: true,
                    hasXfade: true,
                    hasAcrossfade: true,
                    hasLibx264: true,
                    hasH264VideoToolbox: true,
                    hasLibx265: true,
                    hasHEVCVideoToolbox: false
                )
            }
        )

        XCTAssertThrowsError(
            try resolver.resolve(
                mode: .systemOnly,
                codec: .hevc,
                dynamicRange: .hdr,
                hdrHEVCEncoderMode: .videoToolbox,
                diagnostics: { _ in }
            )
        ) { error in
            guard case let RenderError.exportFailed(message) = error else {
                return XCTFail("Expected exportFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("hevc_videotoolbox"))
        }
    }

    func testBinaryResolverBundledOnlyFailsWhenHDRVideoToolboxModeIsUnavailable() {
        let bundledBinary = FFmpegBinary(
            ffmpegURL: URL(fileURLWithPath: "/tmp/bundled/ffmpeg"),
            ffprobeURL: URL(fileURLWithPath: "/tmp/bundled/ffprobe"),
            source: .bundled
        )

        let resolver = FFmpegBinaryResolver(
            systemBinaryOverride: nil,
            bundledBinaryOverride: bundledBinary,
            probeOverride: { _ in
                FFmpegCapabilities(
                    versionDescription: "bundled",
                    hasZscale: true,
                    hasTonemap: true,
                    hasXfade: true,
                    hasAcrossfade: true,
                    hasLibx264: true,
                    hasH264VideoToolbox: true,
                    hasLibx265: true,
                    hasHEVCVideoToolbox: false
                )
            }
        )

        XCTAssertThrowsError(
            try resolver.resolve(
                mode: .bundledOnly,
                codec: .hevc,
                dynamicRange: .hdr,
                hdrHEVCEncoderMode: .videoToolbox,
                diagnostics: { _ in }
            )
        ) { error in
            guard case let RenderError.exportFailed(message) = error else {
                return XCTFail("Expected exportFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("hevc_videotoolbox"))
        }
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

        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/a.mov"),
                    durationSeconds: 3.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: false, colorPrimaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2"),
                    sourceDescription: "clip-a"
                ),
                FFmpegRenderClip(
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
            frameRate: 60,
            audioLayout: .stereo,
            bitrateMode: .qualityFirst,
            container: .mov,
            videoCodec: .hevc,
            dynamicRange: .hdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("xfade=transition=fade"))
        XCTAssertTrue(joined.contains("acrossfade=d=0.750000"))
        XCTAssertTrue(joined.contains(":a:0]atrim"))
        XCTAssertTrue(joined.contains("fps=60"))
        XCTAssertTrue(joined.contains("zscale="))
        XCTAssertFalse(joined.contains("gbrpf32le"))
        XCTAssertTrue(joined.contains("-progress pipe:2"))
        XCTAssertTrue(joined.contains("-stats_period 0.5"))
        XCTAssertTrue(joined.contains("-nostdin"))
        XCTAssertTrue(joined.contains("-ignore_unknown"))
        XCTAssertTrue(joined.contains("-dn"))
        XCTAssertTrue(joined.contains("-color_trc arib-std-b67"))
        XCTAssertTrue(joined.contains("-color_primaries bt2020"))
        XCTAssertTrue(joined.contains("-colorspace bt2020nc"))
        XCTAssertTrue(joined.contains("libx265"))
        XCTAssertFalse(joined.contains("hdr-opt=1"))
    }

    func testCommandBuilderUsesVideoToolboxForHDRWhenRequested() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = makeCapableResolution()
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/a.mov"),
                    durationSeconds: 2,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: true, colorPrimaries: "ITU_R_2020", transferFunction: "ITU_R_2100_HLG"),
                    sourceDescription: "clip-a"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .hevc,
            dynamicRange: .hdr,
            hdrHEVCEncoderMode: .videoToolbox
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("hevc_videotoolbox"))
        XCTAssertFalse(joined.contains("libx265"))
    }

    func testCommandBuilderIncludesBT709MetadataForSDRH264() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = FFmpegBinaryResolution(
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

        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/a.mov"),
                    durationSeconds: 2.5,
                    includeAudio: false,
                    hasAudioTrack: false,
                    colorInfo: ColorInfo(isHDR: true, colorPrimaries: "ITU_R_2020", transferFunction: "ITU_R_2100_HLG"),
                    sourceDescription: "clip-a"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("h264_videotoolbox"))
        XCTAssertTrue(joined.contains("-color_trc bt709"))
        XCTAssertTrue(joined.contains("-color_primaries bt709"))
        XCTAssertTrue(joined.contains("-colorspace bt709"))
        XCTAssertTrue(
            joined.contains(
                "transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc:transfer=linear:npl=\(FFmpegCommandBuilder.hlgSDRNominalPeak)"
            )
        )
        XCTAssertTrue(joined.contains("format=gbrpf32le"))
        XCTAssertTrue(joined.contains("zscale=primaries=bt709"))
        XCTAssertTrue(joined.contains("tonemap=mobius:desat=2"))
        XCTAssertTrue(joined.contains("zscale=transfer=bt709:matrix=bt709:range=tv"))
        XCTAssertTrue(joined.contains("format=yuv420p"))
    }

    func testCommandBuilderUsesMonoAudioLayoutWhenRequested() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = makeCapableResolution()
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/a.mov"),
                    durationSeconds: 2,
                    includeAudio: false,
                    hasAudioTrack: false,
                    colorInfo: .unknown,
                    sourceDescription: "clip-a"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .mono,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("anullsrc=r=48000:cl=mono"))
        XCTAssertTrue(joined.contains("channel_layouts=mono"))
        XCTAssertTrue(joined.contains("-ac 1"))
        XCTAssertTrue(joined.contains("-b:a 96k"))
    }

    func testCommandBuilderUses51AudioLayoutWhenRequested() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = makeCapableResolution()
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/a.mov"),
                    durationSeconds: 2,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: .unknown,
                    sourceDescription: "clip-a"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .surround51,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("channel_layouts=5.1"))
        XCTAssertTrue(joined.contains("-ac 6"))
        XCTAssertTrue(joined.contains("-b:a 384k"))
    }

    func testCommandBuilderAddsCaptureDateOverlayInputsWhenPresent() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = makeCapableResolution()
        let overlayURL = URL(fileURLWithPath: "/tmp/capture-date-overlay.png")
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/a.mov"),
                    durationSeconds: 2,
                    includeAudio: false,
                    hasAudioTrack: false,
                    colorInfo: .unknown,
                    sourceDescription: "clip-a",
                    captureDateOverlayURL: overlayURL
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains(overlayURL.path))
        XCTAssertTrue(joined.contains("-loop 1"))
        XCTAssertTrue(
            joined.contains("overlay=x=main_w-overlay_w-48:y=main_h-overlay_h-27:shortest=1:format=auto")
        )
        XCTAssertTrue(plan.capabilityRequirements.requiresOverlay)
    }

    func testCommandBuilderOmitsCaptureDateOverlayWhenNotPresent() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = makeCapableResolution()
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/a.mov"),
                    durationSeconds: 2,
                    includeAudio: false,
                    hasAudioTrack: false,
                    colorInfo: .unknown,
                    sourceDescription: "clip-a"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertFalse(joined.contains("overlay=x=main_w-overlay_w-"))
        XCTAssertFalse(plan.capabilityRequirements.requiresOverlay)
    }

    func testCommandBuilderFailsWhenOverlayFilterIsMissing() {
        let builder = FFmpegCommandBuilder()
        let overlayURL = URL(fileURLWithPath: "/tmp/capture-date-overlay.png")
        let resolution = FFmpegBinaryResolution(
            selectedBinary: FFmpegBinary(
                ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"),
                ffprobeURL: URL(fileURLWithPath: "/tmp/ffprobe"),
                source: .bundled
            ),
            selectedCapabilities: FFmpegCapabilities(
                versionDescription: "overlay-missing",
                hasZscale: true,
                hasTonemap: true,
                hasXfade: true,
                hasAcrossfade: true,
                hasOverlay: false,
                hasLibx264: true,
                hasH264VideoToolbox: true,
                hasLibx265: true,
                hasHEVCVideoToolbox: true
            ),
            systemCapabilities: nil,
            bundledCapabilities: nil,
            fallbackReason: nil
        )
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/a.mov"),
                    durationSeconds: 2,
                    includeAudio: false,
                    hasAudioTrack: false,
                    colorInfo: .unknown,
                    sourceDescription: "clip-a",
                    captureDateOverlayURL: overlayURL
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        XCTAssertThrowsError(try builder.buildCommand(plan: plan, resolution: resolution)) { error in
            guard case let RenderError.exportFailed(message) = error else {
                return XCTFail("Expected exportFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("overlay filter"))
        }
    }

    func testBinaryResolverAutoFallsBackToBundledWhenSystemIsMissingTonemapForSDRHDRSources() throws {
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
                        hasZscale: true,
                        hasTonemap: false,
                        hasXfade: true,
                        hasAcrossfade: true,
                        hasLibx264: true,
                        hasH264VideoToolbox: true,
                        hasLibx265: true,
                        hasHEVCVideoToolbox: true
                    )
                }
                return FFmpegCapabilities(
                    versionDescription: "bundled",
                    hasZscale: true,
                    hasTonemap: true,
                    hasXfade: true,
                    hasAcrossfade: true,
                    hasLibx264: true,
                    hasH264VideoToolbox: true,
                    hasLibx265: true,
                    hasHEVCVideoToolbox: true
                )
            }
        )

        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/hdr.mov"),
                    durationSeconds: 2,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: true, colorPrimaries: "ITU_R_2020", transferFunction: "SMPTE_ST_2084_PQ"),
                    sourceDescription: "hdr-source"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let resolution = try resolver.resolve(
            mode: .autoSystemThenBundled,
            plan: plan,
            diagnostics: { _ in }
        )

        XCTAssertEqual(resolution.selectedBinary.source, .bundled)
        XCTAssertTrue(resolution.fallbackReason?.contains("tonemap filter") ?? false)
    }

    func testBinaryResolverDoesNotRequireTonemapForPureSDRSources() throws {
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
                    hasTonemap: false,
                    hasXfade: true,
                    hasAcrossfade: true,
                    hasLibx264: true,
                    hasH264VideoToolbox: true,
                    hasLibx265: true,
                    hasHEVCVideoToolbox: true
                )
            }
        )

        let resolution = try resolver.resolve(
            mode: .autoSystemThenBundled,
            codec: .h264,
            dynamicRange: .sdr,
            diagnostics: { _ in }
        )

        XCTAssertEqual(resolution.selectedBinary.source, .system)
    }

    func testCommandBuilderToneMapsPQHDRSourceForSDROutput() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = FFmpegBinaryResolution(
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

        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/pq.mov"),
                    durationSeconds: 2.5,
                    includeAudio: false,
                    hasAudioTrack: false,
                    colorInfo: ColorInfo(isHDR: true, colorPrimaries: "ITU_R_2020", transferFunction: "SMPTE_ST_2084_PQ"),
                    sourceDescription: "pq-source"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("transferin=smpte2084:primariesin=bt2020:matrixin=bt2020nc:transfer=linear"))
        XCTAssertTrue(joined.contains("format=gbrpf32le"))
        XCTAssertTrue(joined.contains("tonemap=mobius:desat=2"))
        XCTAssertTrue(joined.contains("zscale=transfer=bt709:primaries=bt709:matrix=bt709"))
    }

    func testCommandBuilderUsesTunedHLGChainForSDROutput() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = FFmpegBinaryResolution(
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

        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/hlg.mov"),
                    durationSeconds: 2.5,
                    includeAudio: false,
                    hasAudioTrack: false,
                    colorInfo: ColorInfo(isHDR: true, colorPrimaries: "ITU_R_2020", transferFunction: "ITU_R_2100_HLG"),
                    sourceDescription: "hlg-source"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(
            joined.contains(
                "transferin=arib-std-b67:primariesin=bt2020:matrixin=bt2020nc:transfer=linear:npl=\(FFmpegCommandBuilder.hlgSDRNominalPeak)"
            )
        )
        XCTAssertTrue(joined.contains("format=gbrpf32le"))
        XCTAssertTrue(joined.contains("zscale=primaries=bt709"))
        XCTAssertTrue(joined.contains("tonemap=mobius:desat=2"))
        XCTAssertTrue(joined.contains("zscale=transfer=bt709:matrix=bt709:range=tv"))
    }

    func testCommandBuilderLeavesSDRSourceOnFastSDRPath() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = FFmpegBinaryResolution(
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

        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/sdr.mov"),
                    durationSeconds: 2,
                    includeAudio: false,
                    hasAudioTrack: false,
                    colorInfo: ColorInfo(isHDR: false, colorPrimaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2"),
                    sourceDescription: "sdr-source"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertFalse(joined.contains("tonemap=mobius:desat=2"))
        XCTAssertFalse(joined.contains("format=gbrpf32le"))
        XCTAssertTrue(joined.contains("transferin=bt709:primariesin=bt709:matrixin=bt709:transfer=bt709:primaries=bt709:matrix=bt709"))
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
            frameRate: .fps60,
            resolution: .smart,
            dynamicRange: .hdr,
            hdrFFmpegBinaryMode: .bundledOnly,
            hdrHEVCEncoderMode: .videoToolbox,
            audioLayout: .stereo,
            bitrateMode: .qualityFirst
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ExportProfile.self, from: data)

        XCTAssertEqual(decoded.hdrFFmpegBinaryMode, .bundledOnly)
        XCTAssertEqual(decoded.hdrHEVCEncoderMode, .videoToolbox)
        XCTAssertEqual(decoded.frameRate, .fps60)
    }

    func testPlexInfuseDefaultProfileCodableRoundTrip() throws {
        let profile = ExportProfile.plexInfuseAppleTV4KDefault

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ExportProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
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
}
