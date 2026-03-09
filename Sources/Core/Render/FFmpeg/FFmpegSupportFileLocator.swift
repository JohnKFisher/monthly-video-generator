import Foundation

struct FFmpegSupportFileLocator {
    private static let sdrLumaLiftLUTFilename = "sdr_luma_lift_33.cube"
    private static let sdrLumaLiftLUTSize = 33
    private static let sdrLumaLiftGain = 1.50
    private static let sdrLumaLiftShoulder = 0.70

    private let fileManager: FileManager
    private let temporaryDirectoryOverride: URL?

    init(fileManager: FileManager = .default, temporaryDirectoryOverride: URL? = nil) {
        self.fileManager = fileManager
        self.temporaryDirectoryOverride = temporaryDirectoryOverride
    }

    func sdrLumaLiftLUTURL() throws -> URL {
        let supportDirectory = resolvedSupportDirectory()
        let lutURL = supportDirectory.appendingPathComponent(Self.sdrLumaLiftLUTFilename, isDirectory: false)
        if fileManager.fileExists(atPath: lutURL.path) {
            return lutURL
        }

        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try Self.sdrLumaLiftLUTContents().write(to: lutURL, atomically: true, encoding: .ascii)
            return lutURL
        } catch {
            throw RenderError.exportFailed("FFmpeg support file generation failed: \(error.localizedDescription)")
        }
    }

    private func resolvedSupportDirectory() -> URL {
        let baseDirectory = temporaryDirectoryOverride ?? fileManager.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("MonthlyVideoGeneratorSupport", isDirectory: true)
            .appendingPathComponent("FFmpeg", isDirectory: true)
    }

    private static func sdrLumaLiftLUTContents() -> String {
        var lines: [String] = [
            "TITLE \"Monthly Video Generator SDR Luma Lift\"",
            "LUT_3D_SIZE \(sdrLumaLiftLUTSize)",
            "DOMAIN_MIN 0.0 0.0 0.0",
            "DOMAIN_MAX 1.0 1.0 1.0"
        ]
        lines.reserveCapacity(4 + (sdrLumaLiftLUTSize * sdrLumaLiftLUTSize * sdrLumaLiftLUTSize))

        let divisor = Double(sdrLumaLiftLUTSize - 1)
        for blueIndex in 0..<sdrLumaLiftLUTSize {
            let blue = Double(blueIndex) / divisor
            for greenIndex in 0..<sdrLumaLiftLUTSize {
                let green = Double(greenIndex) / divisor
                for redIndex in 0..<sdrLumaLiftLUTSize {
                    let red = Double(redIndex) / divisor
                    let luma = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
                    let liftedLuma = (sdrLumaLiftGain * luma) / (1.0 + (sdrLumaLiftShoulder * luma))
                    let scale = liftedLuma / max(luma, 0.000001)
                    let liftedRed = min(max(red * scale, 0), 1)
                    let liftedGreen = min(max(green * scale, 0), 1)
                    let liftedBlue = min(max(blue * scale, 0), 1)
                    lines.append(String(format: "%.8f %.8f %.8f", liftedRed, liftedGreen, liftedBlue))
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
