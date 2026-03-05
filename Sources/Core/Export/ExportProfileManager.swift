import Foundation

public struct ExportCompatibilityWarning: Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public final class ExportProfileManager {
    public init() {}

    public func defaultProfile() -> ExportProfile {
        .balancedDefault
    }

    public func compatibilityWarnings(for profile: ExportProfile) -> [ExportCompatibilityWarning] {
        var warnings: [ExportCompatibilityWarning] = []

        if profile.dynamicRange == .hdr {
            warnings.append(ExportCompatibilityWarning("HDR export may not play correctly on older SDR displays and players."))
            switch profile.hdrFFmpegBinaryMode {
            case .autoSystemThenBundled:
                warnings.append(ExportCompatibilityWarning("HDR engine auto mode uses system ffmpeg first, then bundled ffmpeg if required features are missing."))
            case .systemOnly:
                warnings.append(ExportCompatibilityWarning("HDR engine System Only mode can fail if local ffmpeg lacks zscale/xfade/acrossfade/Main10 support."))
            case .bundledOnly:
                warnings.append(ExportCompatibilityWarning("HDR engine Bundled Only mode requires bundled ffmpeg binaries in app resources or third_party/ffmpeg."))
            }
        }

        if profile.audioLayout == .surround51 {
            warnings.append(ExportCompatibilityWarning("5.1 output may downmix to stereo on devices without surround playback support."))
        }

        if profile.videoCodec == .hevc && profile.container == .mp4 {
            warnings.append(ExportCompatibilityWarning("HEVC in MP4 has reduced compatibility on legacy players. Consider MOV or H.264."))
        }

        if profile.resolution == .fixed4K {
            warnings.append(ExportCompatibilityWarning("4K output increases render time and file size significantly."))
        }

        return warnings
    }
}
