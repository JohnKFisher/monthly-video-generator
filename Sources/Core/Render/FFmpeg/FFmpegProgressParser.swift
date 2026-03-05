import Foundation

struct FFmpegProgressUpdate: Equatable, Sendable {
    let outTimeMicroseconds: Int64
    let totalSizeBytes: Int64?
    let speed: Double?
    let state: String

    var isTerminal: Bool {
        state == "end"
    }
}

struct FFmpegProgressParser {
    private(set) var latestOutTimeMS: Int64 = 0
    private(set) var latestTotalSizeBytes: Int64?
    private(set) var latestSpeed: Double?

    @discardableResult
    mutating func ingest(line: String) -> FFmpegProgressUpdate? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let components = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            return nil
        }

        let key = components[0]
        let value = components[1]
        if (key == "out_time_ms" || key == "out_time_us"), let parsed = Int64(value) {
            latestOutTimeMS = max(parsed, 0)
            return nil
        }
        if key == "total_size", let parsed = Int64(value) {
            latestTotalSizeBytes = max(parsed, 0)
            return nil
        }
        if key == "speed" {
            latestSpeed = parseSpeed(value)
            return nil
        }
        if key == "progress" {
            return FFmpegProgressUpdate(
                outTimeMicroseconds: latestOutTimeMS,
                totalSizeBytes: latestTotalSizeBytes,
                speed: latestSpeed,
                state: value
            )
        }
        return nil
    }

    func progress(totalDurationMicroseconds: Int64) -> Double {
        guard totalDurationMicroseconds > 0 else {
            return 0
        }
        return min(max(Double(latestOutTimeMS) / Double(totalDurationMicroseconds), 0), 1)
    }

    private func parseSpeed(_ value: String) -> Double? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.caseInsensitiveCompare("n/a") != .orderedSame else {
            return nil
        }
        let numeric = cleaned.hasSuffix("x") ? String(cleaned.dropLast()) : cleaned
        return Double(numeric)
    }
}
