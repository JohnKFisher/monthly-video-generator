import Foundation

struct FFmpegProgressParser {
    private(set) var latestOutTimeMS: Int64 = 0

    mutating func ingest(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let components = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            return
        }

        let key = components[0]
        let value = components[1]
        if (key == "out_time_ms" || key == "out_time_us"), let parsed = Int64(value) {
            latestOutTimeMS = max(parsed, 0)
        }
    }

    func progress(totalDurationMicroseconds: Int64) -> Double {
        guard totalDurationMicroseconds > 0 else {
            return 0
        }
        return min(max(Double(latestOutTimeMS) / Double(totalDurationMicroseconds), 0), 1)
    }
}
