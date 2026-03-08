import Foundation

struct FFprobeVideoSourceMetadata: Equatable, Sendable {
    let hdrMetadataFlavor: HDRMetadataFlavor
}

struct FFprobeSourceMetadataProbe {
    private let processFactory: () -> Process

    init(processFactory: @escaping () -> Process = Process.init) {
        self.processFactory = processFactory
    }

    func probeVideoSourceMetadata(at url: URL, ffprobeURL: URL) throws -> FFprobeVideoSourceMetadata {
        let process = processFactory()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_streams",
            "-show_frames",
            "-read_intervals", "0%+0.1",
            "-show_entries", "stream_side_data=side_data_type,dv_profile,dv_bl_signal_compatibility_id:frame_side_data=side_data_type",
            "-of", "json",
            url.path
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "ffprobe failed"
            throw RenderError.exportFailed(stderrText)
        }

        return try Self.parseVideoSourceMetadata(from: stdout)
    }

    static func parseVideoSourceMetadata(from data: Data) throws -> FFprobeVideoSourceMetadata {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let streamEntries = root["streams"] as? [[String: Any]] ?? []
        let frameEntries = root["frames"] as? [[String: Any]] ?? []

        let streamSideData = streamEntries.flatMap { ($0["side_data_list"] as? [[String: Any]]) ?? [] }
        let frameSideData = frameEntries.flatMap { ($0["side_data_list"] as? [[String: Any]]) ?? [] }
        let allSideData = streamSideData + frameSideData

        let hasDolbyVision = allSideData.contains { entry in
            let type = (entry["side_data_type"] as? String ?? "").lowercased()
            return type.contains("dolby vision") || type.contains("dovi")
        }
        || streamEntries.contains { entry in
            entry["dv_profile"] != nil || entry["dv_bl_signal_compatibility_id"] != nil
        }

        return FFprobeVideoSourceMetadata(
            hdrMetadataFlavor: hasDolbyVision ? .dolbyVision : .none
        )
    }
}
