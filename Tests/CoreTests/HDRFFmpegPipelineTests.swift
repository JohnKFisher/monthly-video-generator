@testable import Core
import CoreGraphics
import Darwin
import Foundation
import XCTest

final class HDRFFmpegPipelineTests: XCTestCase {
    private final class ResolverFileManagerStub: FileManager, @unchecked Sendable {
        private let stubCurrentDirectoryPath: String
        private let executablePaths: Set<String>

        init(
            currentDirectoryPath: String = "/tmp/nonexistent-bundled-ffmpeg",
            executablePaths: Set<String> = []
        ) {
            self.stubCurrentDirectoryPath = currentDirectoryPath
            self.executablePaths = executablePaths
            super.init()
        }

        override var currentDirectoryPath: String {
            stubCurrentDirectoryPath
        }

        override func isExecutableFile(atPath path: String) -> Bool {
            executablePaths.contains(path)
        }
    }

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

    func testIntermediateChunkIntentPrefersVideoToolboxWhenAvailable() {
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
                renderIntent: .intermediateChunk
            ),
            .hevcVideoToolbox
        )
    }

    func testIntermediateChunkIntentFallsBackToLibx265WhenVideoToolboxIsUnavailable() {
        let capabilities = FFmpegCapabilities(
            versionDescription: "software-only",
            hasZscale: true,
            hasTonemap: true,
            hasXfade: true,
            hasAcrossfade: true,
            hasLibx264: true,
            hasH264VideoToolbox: true,
            hasLibx265: true,
            hasHEVCVideoToolbox: false
        )

        XCTAssertEqual(
            capabilities.preferredEncoder(
                for: .hevc,
                dynamicRange: .hdr,
                hdrHEVCEncoderMode: .automatic,
                renderIntent: .intermediateChunk
            ),
            .libx265
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

    func testBinaryResolverBundledPreferredUsesBundledWhenCapable() throws {
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
                FFmpegCapabilities(
                    versionDescription: binary.source.rawValue,
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
            mode: .bundledPreferred,
            codec: .hevc,
            dynamicRange: .hdr,
            diagnostics: { _ in }
        )

        XCTAssertEqual(resolution.selectedBinary.source, .bundled)
        XCTAssertNil(resolution.fallbackReason)
    }

    func testBinaryResolverBundledPreferredFallsBackToSystemWhenBundledLacksCapabilities() throws {
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
                if binary.source == .bundled {
                    return FFmpegCapabilities(
                        versionDescription: "bundled",
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
            mode: .bundledPreferred,
            codec: .hevc,
            dynamicRange: .hdr,
            diagnostics: { _ in }
        )

        XCTAssertEqual(resolution.selectedBinary.source, .system)
        XCTAssertTrue(resolution.fallbackReason?.contains("Bundled FFmpeg missing required features") ?? false)
    }

    func testBinaryResolverBundledPreferredProbeRequiresBundledBinary() {
        let systemBinary = FFmpegBinary(
            ffmpegURL: URL(fileURLWithPath: "/tmp/system/ffmpeg"),
            ffprobeURL: URL(fileURLWithPath: "/tmp/system/ffprobe"),
            source: .system
        )

        let resolver = FFmpegBinaryResolver(
            fileManager: ResolverFileManagerStub(),
            systemBinaryOverride: systemBinary,
            bundledBinaryOverride: nil,
            probeOverride: nil
        )

        XCTAssertThrowsError(try resolver.resolveProbeBinary(mode: .bundledPreferred)) { error in
            guard case let RenderError.exportFailed(message) = error else {
                return XCTFail("Expected exportFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("Bundled FFmpeg probe binary was not found"))
        }
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
            endFadeToBlackDurationSeconds: 1.5,
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
        XCTAssertTrue(joined.contains("fade=t=out:st=4.750000:d=1.500000:color=black"))
        XCTAssertTrue(joined.contains(":a:0]atrim"))
        XCTAssertTrue(joined.contains("fps=60"))
        XCTAssertTrue(joined.contains("split=2[vfgsrc0][vbgsrc0]"))
        XCTAssertTrue(joined.contains("force_original_aspect_ratio=decrease"))
        XCTAssertTrue(joined.contains("force_original_aspect_ratio=increase"))
        XCTAssertTrue(joined.contains("crop=2074:1167"))
        XCTAssertTrue(joined.contains("scale=w=480:h=270:flags=bilinear"))
        XCTAssertTrue(joined.contains("gblur=sigma=7.200000:steps=1"))
        XCTAssertTrue(joined.contains("eq=saturation=0.650000"))
        XCTAssertTrue(joined.contains("lutyuv=y=val*0.600000"))
        XCTAssertTrue(joined.contains("overlay=x=(main_w-overlay_w)/2:y=(main_h-overlay_h)/2:shortest=1:format=auto"))
        XCTAssertTrue(joined.contains("zscale="))
        XCTAssertTrue(joined.contains("gbrpf32le"))
        XCTAssertTrue(joined.contains("zscale=transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc:range=tv:npl=225"))
        XCTAssertFalse(joined.contains("lut3d=file="))
        XCTAssertFalse(joined.contains("pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=black"))
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

    func testCommandBuilderAppliesEndFadeToSingleClipOutput() throws {
        let builder = FFmpegCommandBuilder()
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/single.mov"),
                    durationSeconds: 3.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: false, colorPrimaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2"),
                    sourceDescription: "single"
                )
            ],
            transitionDurationSeconds: 0,
            endFadeToBlackDurationSeconds: 1.5,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: makeCapableResolution())
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("fade=t=out:st=1.500000:d=1.500000:color=black"))
    }

    func testHDRLibx265FinalDeliveryAddsThreadCapsForStability() throws {
        let builder = FFmpegCommandBuilder()
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/hdr.mov"),
                    durationSeconds: 3.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: true, colorPrimaries: "ITU_R_2020", transferFunction: "ITU_R_2100_HLG"),
                    sourceDescription: "hdr"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .hevc,
            dynamicRange: .hdr,
            hdrHEVCEncoderMode: .automatic
        )

        let command = try builder.buildCommand(plan: plan, resolution: makeCapableResolution())
        let joined = command.arguments.joined(separator: " ")
        let expectedThreadLimit = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 4)
        let expectedFrameThreads = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 2)

        XCTAssertTrue(joined.contains("-threads \(expectedThreadLimit)"))
        XCTAssertTrue(joined.contains("pools=\(expectedThreadLimit)"))
        XCTAssertTrue(joined.contains("frame-threads=\(expectedFrameThreads)"))
    }

    func testCommandBuilderClampsEndFadeToOutputDuration() throws {
        let builder = FFmpegCommandBuilder()
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/short.mov"),
                    durationSeconds: 1.0,
                    includeAudio: false,
                    hasAudioTrack: false,
                    colorInfo: ColorInfo(isHDR: false, colorPrimaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2"),
                    sourceDescription: "short"
                )
            ],
            transitionDurationSeconds: 0,
            endFadeToBlackDurationSeconds: 2.0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr
        )

        let command = try builder.buildCommand(plan: plan, resolution: makeCapableResolution())
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("fade=t=out:st=0.000000:d=1.000000:color=black"))
    }

    func testCommandBuilderSkipsEndFadeForIntermediateChunkPlan() throws {
        let builder = FFmpegCommandBuilder()
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/chunk.mov"),
                    durationSeconds: 4.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: true, colorPrimaries: "ITU_R_2020", transferFunction: "ITU_R_2100_HLG"),
                    sourceDescription: "chunk"
                )
            ],
            transitionDurationSeconds: 0,
            endFadeToBlackDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/chunk-out.mov"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mov,
            videoCodec: .hevc,
            dynamicRange: .hdr,
            renderIntent: .intermediateChunk
        )

        let command = try builder.buildCommand(plan: plan, resolution: makeCapableResolution())
        let joined = command.arguments.joined(separator: " ")

        XCTAssertFalse(joined.contains("fade=t=out"))
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

    func testCommandBuilderUsesIntermediateChunkProfileForHDRVideoToolbox() throws {
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
            outputURL: URL(fileURLWithPath: "/tmp/out.mov"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mov,
            videoCodec: .hevc,
            dynamicRange: .hdr,
            hdrHEVCEncoderMode: .automatic,
            renderIntent: .intermediateChunk
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("hevc_videotoolbox"))
        XCTAssertTrue(joined.contains("-profile:v main10"))
        XCTAssertTrue(joined.contains("-pix_fmt p010le"))
        XCTAssertTrue(joined.contains("-b:v 109486080"))
        XCTAssertTrue(joined.contains("-c:a pcm_s16le"))
        XCTAssertFalse(joined.contains("-c:a aac"))
        XCTAssertFalse(joined.contains("-b:a"))
    }

    func testCommandBuilderFallsBackToLibx265ForIntermediateChunkWhenVideoToolboxIsUnavailable() throws {
        let builder = FFmpegCommandBuilder()
        let resolution = FFmpegBinaryResolution(
            selectedBinary: FFmpegBinary(
                ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"),
                ffprobeURL: URL(fileURLWithPath: "/tmp/ffprobe"),
                source: .system
            ),
            selectedCapabilities: FFmpegCapabilities(
                versionDescription: "software-only",
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
                    durationSeconds: 2,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: true, colorPrimaries: "ITU_R_2020", transferFunction: "ITU_R_2100_HLG"),
                    sourceDescription: "clip-a"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mov"),
            renderSize: CGSize(width: 3840, height: 2160),
            frameRate: 60,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mov,
            videoCodec: .hevc,
            dynamicRange: .hdr,
            hdrHEVCEncoderMode: .automatic,
            renderIntent: .intermediateChunk
        )

        let command = try builder.buildCommand(plan: plan, resolution: resolution)
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("libx265"))
        XCTAssertTrue(joined.contains("-b:v 109486080"))
        XCTAssertTrue(joined.contains("-maxrate 109486080"))
        XCTAssertTrue(joined.contains("-bufsize 218972160"))
        XCTAssertTrue(joined.contains("-c:a pcm_s16le"))
        XCTAssertFalse(joined.contains("-crf"))
        XCTAssertFalse(joined.contains("-threads "))
        XCTAssertFalse(joined.contains("frame-threads="))
        XCTAssertFalse(joined.contains("pools="))
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
        XCTAssertTrue(joined.contains("overlay=x=(main_w-overlay_w)/2:y=(main_h-overlay_h)/2:shortest=1:format=auto"))
        XCTAssertTrue(plan.capabilityRequirements.requiresOverlay)
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

    func testStatusLineUsesEffectiveDynamicRangeLabel() {
        let sdrLine = FFmpegHDRRenderer.statusLine(
            dynamicRange: .sdr,
            progress: 0.97,
            elapsed: 80,
            outputSizeBytes: 83_400_000,
            speed: 0.83
        )
        let hdrLine = FFmpegHDRRenderer.statusLine(
            dynamicRange: .hdr,
            progress: 0.97,
            elapsed: 80,
            outputSizeBytes: 83_400_000,
            speed: 0.83
        )

        XCTAssertTrue(sdrLine.hasPrefix("SDR encode: 97%"))
        XCTAssertFalse(sdrLine.contains("HDR encode"))
        XCTAssertTrue(hdrLine.hasPrefix("HDR encode: 97%"))
    }

    func testProcessCPUTimeSecondsReadsCurrentProcessUsage() {
        let cpuTimeSeconds = FFmpegHDRRenderer.processCPUTimeSeconds(for: getpid())

        XCTAssertNotNil(cpuTimeSeconds)
        XCTAssertGreaterThanOrEqual(cpuTimeSeconds ?? -1, 0)
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

    func testCommandBuilderUsesDisplayReferredHLGMappingForBT709SDRInHDROutput() throws {
        let builder = FFmpegCommandBuilder()
        let command = try builder.buildCommand(
            plan: FFmpegRenderPlan(
                clips: [
                    FFmpegRenderClip(
                        url: URL(fileURLWithPath: "/tmp/sdr.mov"),
                        durationSeconds: 2,
                        includeAudio: false,
                        hasAudioTrack: false,
                        colorInfo: ColorInfo(
                            isHDR: false,
                            colorPrimaries: "ITU_R_709_2",
                            transferFunction: "ITU_R_709_2",
                            transferFlavor: .sdr
                        ),
                        sourceDescription: "sdr-bt709"
                    )
                ],
                transitionDurationSeconds: 0,
                outputURL: URL(fileURLWithPath: "/tmp/out.mov"),
                renderSize: CGSize(width: 1920, height: 1080),
                frameRate: 30,
                audioLayout: .stereo,
                bitrateMode: .balanced,
                container: .mov,
                videoCodec: .hevc,
                dynamicRange: .hdr
            ),
            resolution: makeCapableResolution()
        )
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("transferin=bt709:primariesin=bt709:matrixin=bt709:transfer=linear"))
        XCTAssertTrue(joined.contains("format=gbrpf32le"))
        XCTAssertTrue(joined.contains("zscale=transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc:range=tv:npl=225"))
        XCTAssertFalse(joined.contains("lut3d=file="))
        XCTAssertFalse(joined.contains("eq=contrast="))
        XCTAssertFalse(joined.contains("vibrance=intensity="))
    }

    func testCommandBuilderUsesDisplayReferredHLGMappingForP3SDRInHDROutput() throws {
        let builder = FFmpegCommandBuilder()
        let command = try builder.buildCommand(
            plan: FFmpegRenderPlan(
                clips: [
                    FFmpegRenderClip(
                        url: URL(fileURLWithPath: "/tmp/p3.mov"),
                        durationSeconds: 2,
                        includeAudio: false,
                        hasAudioTrack: false,
                        colorInfo: ColorInfo(
                            isHDR: false,
                            colorPrimaries: "P3_D65",
                            transferFunction: "IEC_sRGB",
                            transferFlavor: .sdr
                        ),
                        sourceDescription: "sdr-p3"
                    )
                ],
                transitionDurationSeconds: 0,
                outputURL: URL(fileURLWithPath: "/tmp/out.mov"),
                renderSize: CGSize(width: 1920, height: 1080),
                frameRate: 30,
                audioLayout: .stereo,
                bitrateMode: .balanced,
                container: .mov,
                videoCodec: .hevc,
                dynamicRange: .hdr
            ),
            resolution: makeCapableResolution()
        )
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("transferin=iec61966-2-1:primariesin=smpte432:matrixin=bt709:transfer=linear"))
        XCTAssertTrue(joined.contains("zscale=transfer=arib-std-b67:primaries=bt2020:matrix=bt2020nc:range=tv:npl=225"))
        XCTAssertFalse(joined.contains("lut3d=file="))
        XCTAssertFalse(joined.contains("eq=contrast="))
        XCTAssertFalse(joined.contains("vibrance=intensity="))
    }

    func testFFprobeSourceMetadataParserDetectsDolbyVision() throws {
        let json = """
        {
          "streams": [
            {
              "side_data_list": [
                { "side_data_type": "DOVI configuration record" }
              ]
            }
          ],
          "frames": [
            {
              "side_data_list": [
                { "side_data_type": "Dolby Vision RPU Data" }
              ]
            }
          ]
        }
        """

        let metadata = try FFprobeSourceMetadataProbe.parseVideoSourceMetadata(from: Data(json.utf8))

        XCTAssertEqual(metadata.hdrMetadataFlavor, .dolbyVision)
    }

    func testFFprobeSourceMetadataParserDetectsDolbyVisionFromStreamFields() throws {
        let json = """
        {
          "streams": [
            {
              "dv_profile": 8,
              "dv_bl_signal_compatibility_id": 4
            }
          ]
        }
        """

        let metadata = try FFprobeSourceMetadataProbe.parseVideoSourceMetadata(from: Data(json.utf8))

        XCTAssertEqual(metadata.hdrMetadataFlavor, .dolbyVision)
    }

    func testFFprobeSourceMetadataParserIgnoresPlainHLG() throws {
        let json = """
        {
          "streams": [
            {
              "side_data_list": [
                { "side_data_type": "Ambient viewing environment" }
              ]
            }
          ],
          "frames": [
            {
              "side_data_list": [
                { "side_data_type": "H.26[45] User Data Unregistered SEI message" }
              ]
            }
          ]
        }
        """

        let metadata = try FFprobeSourceMetadataProbe.parseVideoSourceMetadata(from: Data(json.utf8))

        XCTAssertEqual(metadata.hdrMetadataFlavor, .none)
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

    func testCommandBuilderIncludesPlexTVMetadataForFinalMP4() throws {
        let builder = FFmpegCommandBuilder()
        let creationTime = makeMetadataDate(year: 2026, month: 6, day: 28)
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/single.mov"),
                    durationSeconds: 3.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: false, colorPrimaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2"),
                    sourceDescription: "single"
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
            dynamicRange: .sdr,
            embeddedMetadata: EmbeddedOutputMetadata(
                title: "June 2026",
                description: "Fisher Family Monthly Video for June 2026",
                synopsis: "Fisher Family Monthly Video for June 2026",
                comment: "Fisher Family Monthly Video for June 2026",
                show: "Family Videos",
                seasonNumber: 2026,
                episodeSort: 699,
                episodeID: "S2026E0699",
                date: "2026",
                creationTime: creationTime,
                genre: "Family",
                provenance: EmbeddedOutputProvenance(
                    software: "Monthly Video Generator",
                    version: "0.5.0 (20260307200552)",
                    information: "1920x1080, 30 fps, SDR, H.264, AAC Stereo, MP4, Balanced bitrate",
                    customEntries: [
                        "com.jkfisher.monthlyvideogenerator.app_name": "Monthly Video Generator",
                        "com.jkfisher.monthlyvideogenerator.app_version": "0.5.0",
                        "com.jkfisher.monthlyvideogenerator.build_number": "20260307200552",
                        "com.jkfisher.monthlyvideogenerator.export_profile": "container=mp4,videoCodec=h264,audioCodec=aac,dynamicRange=sdr,resolutionPolicy=fixed1080p,resolvedSize=1920x1080,frameRatePolicy=fps30,resolvedFrameRate=30,audioLayout=stereo,bitrateMode=balanced",
                        "com.jkfisher.monthlyvideogenerator.export_json": "{\"appName\":\"Monthly Video Generator\",\"appVersion\":\"0.5.0\",\"buildNumber\":\"20260307200552\"}"
                    ]
                )
            )
        )

        let command = try builder.buildCommand(plan: plan, resolution: makeCapableResolution())
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("-movflags +write_colr+use_metadata_tags"))
        XCTAssertTrue(joined.contains("-metadata title=June 2026"))
        XCTAssertTrue(joined.contains("-metadata show=Family Videos"))
        XCTAssertTrue(joined.contains("-metadata season_number=2026"))
        XCTAssertTrue(joined.contains("-metadata episode_sort=699"))
        XCTAssertTrue(joined.contains("-metadata episode_id=S2026E0699"))
        XCTAssertTrue(joined.contains("-metadata date=2026"))
        XCTAssertTrue(joined.contains("-metadata description=Fisher Family Monthly Video for June 2026"))
        XCTAssertTrue(joined.contains("-metadata synopsis=Fisher Family Monthly Video for June 2026"))
        XCTAssertTrue(joined.contains("-metadata comment=Fisher Family Monthly Video for June 2026"))
        XCTAssertTrue(joined.contains("-metadata genre=Family"))
        XCTAssertTrue(joined.contains("-metadata creation_time=2026-06-28T12:00:00Z"))
        XCTAssertTrue(joined.contains("-metadata software=Monthly Video Generator"))
        XCTAssertTrue(joined.contains("-metadata version=0.5.0 (20260307200552)"))
        XCTAssertTrue(joined.contains("-metadata information=1920x1080, 30 fps, SDR, H.264, AAC Stereo, MP4, Balanced bitrate"))
        XCTAssertTrue(joined.contains("-metadata com.jkfisher.monthlyvideogenerator.app_version=0.5.0"))
        XCTAssertTrue(joined.contains("-metadata com.jkfisher.monthlyvideogenerator.export_json={\"appName\":\"Monthly Video Generator\",\"appVersion\":\"0.5.0\",\"buildNumber\":\"20260307200552\"}"))
    }

    func testCommandBuilderMapsNamedChaptersForFinalMP4() throws {
        let builder = FFmpegCommandBuilder()
        let chapterMetadataURL = URL(fileURLWithPath: "/tmp/chapters.ffmeta")
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/single.mov"),
                    durationSeconds: 3.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: ColorInfo(isHDR: false, colorPrimaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2"),
                    sourceDescription: "single"
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
            dynamicRange: .sdr,
            chapters: [
                RenderChapter(
                    kind: .openingTitle,
                    title: "June 2026",
                    startTimeSeconds: 0,
                    endTimeSeconds: 2.5
                )
            ],
            chapterMetadataURL: chapterMetadataURL
        )

        let command = try builder.buildCommand(plan: plan, resolution: makeCapableResolution())
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("-f ffmetadata -i \(chapterMetadataURL.path)"))
        XCTAssertTrue(joined.contains("-map_chapters 1"))
    }

    func testCommandBuilderOmitsEmbeddedMetadataForIntermediateChunks() throws {
        let builder = FFmpegCommandBuilder()
        let plan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/chunk.mov"),
                    durationSeconds: 3.0,
                    includeAudio: false,
                    hasAudioTrack: false,
                    colorInfo: ColorInfo(isHDR: false, colorPrimaries: "ITU_R_709_2", transferFunction: "ITU_R_709_2"),
                    sourceDescription: "chunk"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/chunk.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr,
            embeddedMetadata: EmbeddedOutputMetadata(
                title: "June 2026",
                description: "Fisher Family Monthly Video for June 2026",
                synopsis: "Fisher Family Monthly Video for June 2026",
                comment: "Fisher Family Monthly Video for June 2026",
                show: "Family Videos",
                seasonNumber: 2026,
                episodeSort: 699,
                episodeID: "S2026E0699",
                date: "2026",
                creationTime: makeMetadataDate(year: 2026, month: 6, day: 28),
                genre: "Family",
                provenance: EmbeddedOutputProvenance(
                    software: "Monthly Video Generator",
                    version: "0.5.0 (20260307200552)",
                    information: "1920x1080, 30 fps, SDR, H.264, AAC Stereo, MP4, Balanced bitrate",
                    customEntries: [
                        "com.jkfisher.monthlyvideogenerator.app_name": "Monthly Video Generator"
                    ]
                )
            ),
            renderIntent: .intermediateChunk
        )

        let command = try builder.buildCommand(plan: plan, resolution: makeCapableResolution())
        let joined = command.arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("-movflags +write_colr"))
        XCTAssertFalse(joined.contains("use_metadata_tags"))
        XCTAssertFalse(joined.contains("-metadata title="))
        XCTAssertFalse(joined.contains("-metadata show="))
    }

    func testCommandBuilderOmitsChapterMappingForNonMP4OrIntermediatePlans() throws {
        let builder = FFmpegCommandBuilder()
        let chapter = RenderChapter(
            kind: .openingTitle,
            title: "June 2026",
            startTimeSeconds: 0,
            endTimeSeconds: 2.5
        )
        let chapterMetadataURL = URL(fileURLWithPath: "/tmp/chapters.ffmeta")
        let movPlan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/mov.mov"),
                    durationSeconds: 3.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: .unknown,
                    sourceDescription: "mov"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/out.mov"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mov,
            videoCodec: .h264,
            dynamicRange: .sdr,
            chapters: [chapter],
            chapterMetadataURL: chapterMetadataURL
        )
        let intermediatePlan = FFmpegRenderPlan(
            clips: [
                FFmpegRenderClip(
                    url: URL(fileURLWithPath: "/tmp/chunk.mov"),
                    durationSeconds: 3.0,
                    includeAudio: true,
                    hasAudioTrack: true,
                    colorInfo: .unknown,
                    sourceDescription: "chunk"
                )
            ],
            transitionDurationSeconds: 0,
            outputURL: URL(fileURLWithPath: "/tmp/chunk-out.mp4"),
            renderSize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            audioLayout: .stereo,
            bitrateMode: .balanced,
            container: .mp4,
            videoCodec: .h264,
            dynamicRange: .sdr,
            chapters: [chapter],
            chapterMetadataURL: chapterMetadataURL,
            renderIntent: .intermediateChunk
        )

        let movCommand = try builder.buildCommand(plan: movPlan, resolution: makeCapableResolution())
        let intermediateCommand = try builder.buildCommand(plan: intermediatePlan, resolution: makeCapableResolution())

        XCTAssertFalse(movCommand.arguments.joined(separator: " ").contains("-map_chapters"))
        XCTAssertFalse(intermediateCommand.arguments.joined(separator: " ").contains("-map_chapters"))
    }

    func testBundledFFmpegPreservesPlexTVTagsInMP4() throws {
        guard
            let ffmpegURL = bundledBinaryURL(named: "ffmpeg"),
            let ffprobeURL = bundledBinaryURL(named: "ffprobe")
        else {
            throw XCTSkip("Bundled FFmpeg binaries are not available in third_party/ffmpeg/bin.")
        }

        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let outputURL = outputDirectory.appendingPathComponent("plex-tags.mp4")
        let description = "Fisher Family Monthly Video for June 2026"
        let creationTime = "2026-06-28T12:00:00Z"
        let provenanceInformation = "16x16, 30 fps, SDR, H.264, AAC Stereo, MP4, Balanced bitrate"
        let exportJSON = "{\"appName\":\"Monthly Video Generator\",\"appVersion\":\"0.5.0\",\"buildNumber\":\"20260307200552\",\"resolvedWidth\":16,\"resolvedHeight\":16,\"resolvedFrameRate\":30}"

        _ = try runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-f", "lavfi",
                "-i", "color=c=black:s=16x16:d=1",
                "-f", "lavfi",
                "-i", "anullsrc=r=48000:cl=stereo",
                "-shortest",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-movflags", "+use_metadata_tags",
                "-metadata", "title=June 2026",
                "-metadata", "show=Family Videos",
                "-metadata", "season_number=2026",
                "-metadata", "episode_sort=699",
                "-metadata", "episode_id=S2026E0699",
                "-metadata", "date=2026",
                "-metadata", "description=\(description)",
                "-metadata", "synopsis=\(description)",
                "-metadata", "comment=\(description)",
                "-metadata", "genre=Family",
                "-metadata", "creation_time=\(creationTime)",
                "-metadata", "software=Monthly Video Generator",
                "-metadata", "version=0.5.0 (20260307200552)",
                "-metadata", "information=\(provenanceInformation)",
                "-metadata", "com.jkfisher.monthlyvideogenerator.app_name=Monthly Video Generator",
                "-metadata", "com.jkfisher.monthlyvideogenerator.app_version=0.5.0",
                "-metadata", "com.jkfisher.monthlyvideogenerator.build_number=20260307200552",
                "-metadata", "com.jkfisher.monthlyvideogenerator.export_profile=container=mp4,videoCodec=h264,audioCodec=aac,dynamicRange=sdr,resolutionPolicy=fixed720p,resolvedSize=16x16,frameRatePolicy=fps30,resolvedFrameRate=30,audioLayout=stereo,bitrateMode=balanced",
                "-metadata", "com.jkfisher.monthlyvideogenerator.export_json=\(exportJSON)",
                outputURL.path
            ]
        )

        let probeOutput = try runProcess(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "quiet",
                "-print_format", "json",
                "-show_entries", "format_tags",
                outputURL.path
            ]
        )
        let data = try XCTUnwrap(probeOutput.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let format = try XCTUnwrap(json?["format"] as? [String: Any])
        let tags = try XCTUnwrap(format["tags"] as? [String: Any])

        XCTAssertEqual(tags["title"] as? String, "June 2026")
        XCTAssertEqual(tags["show"] as? String, "Family Videos")
        XCTAssertEqual(tags["season_number"] as? String, "2026")
        XCTAssertEqual(tags["episode_sort"] as? String, "699")
        XCTAssertEqual(tags["episode_id"] as? String, "S2026E0699")
        XCTAssertEqual(tags["date"] as? String, "2026")
        XCTAssertEqual(tags["description"] as? String, description)
        XCTAssertEqual(tags["synopsis"] as? String, description)
        XCTAssertEqual(tags["comment"] as? String, description)
        XCTAssertEqual(tags["genre"] as? String, "Family")
        XCTAssertEqual(tags["creation_time"] as? String, creationTime)
        XCTAssertEqual(tags["software"] as? String, "Monthly Video Generator")
        XCTAssertEqual(tags["version"] as? String, "0.5.0 (20260307200552)")
        XCTAssertEqual(tags["information"] as? String, provenanceInformation)
        XCTAssertEqual(tags["com.jkfisher.monthlyvideogenerator.app_name"] as? String, "Monthly Video Generator")
        XCTAssertEqual(tags["com.jkfisher.monthlyvideogenerator.app_version"] as? String, "0.5.0")
        XCTAssertEqual(tags["com.jkfisher.monthlyvideogenerator.build_number"] as? String, "20260307200552")
        XCTAssertEqual(tags["com.jkfisher.monthlyvideogenerator.export_profile"] as? String, "container=mp4,videoCodec=h264,audioCodec=aac,dynamicRange=sdr,resolutionPolicy=fixed720p,resolvedSize=16x16,frameRatePolicy=fps30,resolvedFrameRate=30,audioLayout=stereo,bitrateMode=balanced")
        XCTAssertEqual(tags["com.jkfisher.monthlyvideogenerator.export_json"] as? String, exportJSON)
    }

    func testBundledFFmpegPreservesNamedChaptersInMP4() throws {
        guard
            let ffmpegURL = bundledBinaryURL(named: "ffmpeg"),
            let ffprobeURL = bundledBinaryURL(named: "ffprobe")
        else {
            throw XCTSkip("Bundled FFmpeg binaries are not available in third_party/ffmpeg/bin.")
        }

        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let sourceURL = outputDirectory.appendingPathComponent("source.mp4")
        let chapterMetadataURL = outputDirectory.appendingPathComponent("chapters.ffmeta")
        let outputURL = outputDirectory.appendingPathComponent("chaptered.mp4")
        try """
        ;FFMETADATA1
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=500
        title=June 2026
        [CHAPTER]
        TIMEBASE=1/1000
        START=500
        END=1000
        title=June 28 (1 photo)
        """.write(to: chapterMetadataURL, atomically: true, encoding: .utf8)

        _ = try runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-f", "lavfi",
                "-i", "color=c=black:s=16x16:d=1",
                "-f", "lavfi",
                "-i", "anullsrc=r=48000:cl=stereo",
                "-shortest",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                sourceURL.path
            ]
        )

        _ = try runProcess(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", sourceURL.path,
                "-f", "ffmetadata",
                "-i", chapterMetadataURL.path,
                "-map", "0",
                "-map_metadata", "0",
                "-map_chapters", "1",
                "-c", "copy",
                "-movflags", "+use_metadata_tags",
                outputURL.path
            ]
        )

        let probeOutput = try runProcess(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "quiet",
                "-print_format", "json",
                "-show_chapters",
                outputURL.path
            ]
        )
        let data = try XCTUnwrap(probeOutput.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let chapters = try XCTUnwrap(json["chapters"] as? [[String: Any]])
        let firstTags = try XCTUnwrap(chapters[0]["tags"] as? [String: Any])
        let secondTags = try XCTUnwrap(chapters[1]["tags"] as? [String: Any])

        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(firstTags["title"] as? String, "June 2026")
        XCTAssertEqual(secondTags["title"] as? String, "June 28 (1 photo)")
        XCTAssertEqual(chapters[1]["start_time"] as? String, "0.500000")
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

    private func makeMetadataDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    private func bundledBinaryURL(named name: String) -> URL? {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("third_party/ffmpeg/bin", isDirectory: true)
        let url = root.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func runProcess(executableURL: URL, arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let stderrText = String(decoding: stderrData, as: UTF8.self)
            throw XCTSkip("Command failed (\(process.terminationStatus)): \(stderrText)")
        }
        return String(decoding: stdoutData, as: UTF8.self)
    }
}
