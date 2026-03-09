import Foundation

public struct ExportCompatibilityWarning: Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public struct ExportProfileResolution: Equatable {
    public let effectiveProfile: ExportProfile
    public let warnings: [ExportCompatibilityWarning]

    public init(effectiveProfile: ExportProfile, warnings: [ExportCompatibilityWarning]) {
        self.effectiveProfile = effectiveProfile
        self.warnings = warnings
    }
}

public final class ExportProfileManager {
    public init() {}

    public func defaultProfile() -> ExportProfile {
        .plexInfuseAppleTV4KDefault
    }

    public func resolveProfile(for profile: ExportProfile) -> ExportProfileResolution {
        resolveProfile(for: profile, items: nil)
    }

    public func resolveProfile(for profile: ExportProfile, items: [MediaItem]) -> ExportProfileResolution {
        resolveProfile(for: profile, items: Optional(items))
    }

    public func compatibilityWarnings(for profile: ExportProfile) -> [ExportCompatibilityWarning] {
        resolveProfile(for: profile).warnings
    }

    public func compatibilityWarnings(for profile: ExportProfile, items: [MediaItem]) -> [ExportCompatibilityWarning] {
        resolveProfile(for: profile, items: items).warnings
    }

    private func resolveProfile(for profile: ExportProfile, items: [MediaItem]?) -> ExportProfileResolution {
        var warnings: [ExportCompatibilityWarning] = []
        var effectiveProfile = withResolution(profile.resolution.normalized, in: profile)
        let requestedAudioLayout = effectiveProfile.audioLayout
        var smartAudioResolution: SmartAudioResolution?

        if effectiveProfile.dynamicRange == .hdr {
            if effectiveProfile.videoCodec != .hevc {
                effectiveProfile = withVideoCodec(.hevc, in: effectiveProfile)
                warnings.append(
                    ExportCompatibilityWarning(
                        "HDR currently exports as HEVC Main10. Selected codec was adjusted to HEVC."
                    )
                )
            }
        }

        if requestedAudioLayout == .smart, let items {
            smartAudioResolution = resolveSmartAudioLayout(for: items)
            effectiveProfile = withAudioLayout(smartAudioResolution?.resolvedLayout ?? .surround51, in: effectiveProfile)
            warnings.append(
                ExportCompatibilityWarning(
                    "Smart audio resolved to \(effectiveProfile.audioLayout.displayLabel) from the selected source videos."
                )
            )
            if smartAudioResolution?.usedUnknownFallback == true {
                warnings.append(
                    ExportCompatibilityWarning(
                        "Some videos could not be inspected for Smart audio, so output was raised to 5.1 to avoid dropping channels."
                    )
                )
            }
        }

        warnings.append(
            contentsOf: compatibilityWarnings(
                forEffectiveProfile: effectiveProfile,
                requestedAudioLayout: requestedAudioLayout
            )
        )
        return ExportProfileResolution(effectiveProfile: effectiveProfile, warnings: warnings)
    }

    private func compatibilityWarnings(
        forEffectiveProfile profile: ExportProfile,
        requestedAudioLayout: AudioLayout
    ) -> [ExportCompatibilityWarning] {
        var warnings: [ExportCompatibilityWarning] = []

        if profile.dynamicRange == .hdr {
            warnings.append(
                ExportCompatibilityWarning(
                    "HDR output is tuned for Plex + Infuse on Apple TV 4K (HEVC Main10 video + AAC audio)."
                )
            )
            warnings.append(
                ExportCompatibilityWarning(
                    "HDR output requires an HDR-capable display/player. SDR playback may appear tone-mapped or dimmer."
                )
            )
            switch profile.hdrHEVCEncoderMode {
            case .automatic:
                warnings.append(
                    ExportCompatibilityWarning(
                        "HDR HEVC encoder Default mode preserves the current quality-first order: libx265 first, then VideoToolbox if required."
                    )
                )
            case .videoToolbox:
                warnings.append(
                    ExportCompatibilityWarning(
                        "HDR HEVC encoder VideoToolbox mode prioritizes faster hardware encoding and fails explicitly if hevc_videotoolbox is unavailable for the available FFmpeg toolchain."
                    )
                )
            }

        }

        switch profile.hdrFFmpegBinaryMode {
        case .bundledPreferred:
            warnings.append(ExportCompatibilityWarning("FFmpeg uses the bundled toolchain first and will ask before falling back to system ffmpeg if bundled capabilities are missing."))
        case .autoSystemThenBundled:
            warnings.append(ExportCompatibilityWarning("FFmpeg engine Auto mode uses system ffmpeg first, then bundled ffmpeg if required filters or encoders are missing."))
        case .systemOnly:
            warnings.append(ExportCompatibilityWarning("FFmpeg engine System Only mode can fail if local ffmpeg lacks the required zscale/xfade/acrossfade filters or the selected output encoder."))
        case .bundledOnly:
            warnings.append(ExportCompatibilityWarning("FFmpeg engine Bundled Only mode requires bundled ffmpeg binaries in app resources or third_party/ffmpeg."))
        }

        if profile.resolution == .smart {
            warnings.append(
                ExportCompatibilityWarning(
                    "Smart resolution chooses the smallest 16:9 output tier that fits all selected media, up to 4K."
                )
            )
        }

        if requestedAudioLayout == .smart {
            warnings.append(
                ExportCompatibilityWarning(
                    "Smart audio chooses Mono unless any selected video needs Stereo or 5.1; any uninspectable video falls back to 5.1."
                )
            )
        }

        switch profile.frameRate {
        case .smart:
            warnings.append(
                ExportCompatibilityWarning(
                    "Smart frame rate exports at 30 fps unless any selected video is 50 fps or higher, then it exports at 60 fps."
                )
            )
        case .fps60:
            warnings.append(
                ExportCompatibilityWarning(
                    "60 fps output increases render time, CPU load, and file size significantly."
                )
            )
        case .fps30:
            break
        }

        if profile.audioLayout == .surround51 {
            warnings.append(ExportCompatibilityWarning("5.1 output may downmix to stereo on devices without surround playback support."))
        }

        if profile.container == .mov {
            warnings.append(ExportCompatibilityWarning("MP4 is the default container for Plex + Infuse workflows. MOV may require remuxing in some server toolchains."))
        }

        if profile.resolution == .fixed4K {
            warnings.append(ExportCompatibilityWarning("4K output increases render time and file size significantly."))
        }

        return warnings
    }

    private func withVideoCodec(_ codec: VideoCodec, in profile: ExportProfile) -> ExportProfile {
        ExportProfile(
            container: profile.container,
            videoCodec: codec,
            audioCodec: profile.audioCodec,
            frameRate: profile.frameRate,
            resolution: profile.resolution,
            dynamicRange: profile.dynamicRange,
            hdrFFmpegBinaryMode: profile.hdrFFmpegBinaryMode,
            hdrHEVCEncoderMode: profile.hdrHEVCEncoderMode,
            audioLayout: profile.audioLayout,
            bitrateMode: profile.bitrateMode
        )
    }

    private func withResolution(_ resolution: ResolutionPolicy, in profile: ExportProfile) -> ExportProfile {
        ExportProfile(
            container: profile.container,
            videoCodec: profile.videoCodec,
            audioCodec: profile.audioCodec,
            frameRate: profile.frameRate,
            resolution: resolution,
            dynamicRange: profile.dynamicRange,
            hdrFFmpegBinaryMode: profile.hdrFFmpegBinaryMode,
            hdrHEVCEncoderMode: profile.hdrHEVCEncoderMode,
            audioLayout: profile.audioLayout,
            bitrateMode: profile.bitrateMode
        )
    }

    private func withAudioLayout(_ audioLayout: AudioLayout, in profile: ExportProfile) -> ExportProfile {
        ExportProfile(
            container: profile.container,
            videoCodec: profile.videoCodec,
            audioCodec: profile.audioCodec,
            frameRate: profile.frameRate,
            resolution: profile.resolution,
            dynamicRange: profile.dynamicRange,
            hdrFFmpegBinaryMode: profile.hdrFFmpegBinaryMode,
            hdrHEVCEncoderMode: profile.hdrHEVCEncoderMode,
            audioLayout: audioLayout,
            bitrateMode: profile.bitrateMode
        )
    }

    private func resolveSmartAudioLayout(for items: [MediaItem]) -> SmartAudioResolution {
        let videoItems = items.filter { $0.type == .video }
        guard !videoItems.isEmpty else {
            return SmartAudioResolution(resolvedLayout: .mono, usedUnknownFallback: false)
        }

        var highestKnownChannelCount = 0
        for item in videoItems {
            guard let sourceAudioChannelCount = item.sourceAudioChannelCount else {
                return SmartAudioResolution(resolvedLayout: .surround51, usedUnknownFallback: true)
            }
            highestKnownChannelCount = max(highestKnownChannelCount, sourceAudioChannelCount)
        }

        if highestKnownChannelCount > 2 {
            return SmartAudioResolution(resolvedLayout: .surround51, usedUnknownFallback: false)
        }
        if highestKnownChannelCount == 2 {
            return SmartAudioResolution(resolvedLayout: .stereo, usedUnknownFallback: false)
        }
        return SmartAudioResolution(resolvedLayout: .mono, usedUnknownFallback: false)
    }
}

private struct SmartAudioResolution {
    let resolvedLayout: AudioLayout
    let usedUnknownFallback: Bool
}
