@testable import Core
import Foundation
import XCTest

final class RenderDiagnosticsTests: XCTestCase {
    func testRenderDiagnosticsReportIncludesSummarySectionsAndDeterministicAggregates() {
        let diagnostics = AVFoundationRenderEngine.RenderDiagnostics()
        diagnostics.recordPhase(.renderSetup, elapsedSeconds: 1.25)
        diagnostics.recordPhase(.renderSetup, elapsedSeconds: 0.75)
        diagnostics.recordPhase(.directFFmpegExport, elapsedSeconds: 12.5)
        diagnostics.recordPreparationOperation(.stillClipGeneration, detail: "photo-a.jpg", elapsedSeconds: 1.5)
        diagnostics.recordPreparationOperation(.stillClipGeneration, detail: "photo-b.jpg", elapsedSeconds: 0.5)
        diagnostics.recordPreparationOperation(.captureDateOverlayGeneration, detail: "photo-a.jpg", elapsedSeconds: 0.2)
        diagnostics.recordFFmpegCommandSummary(
            FFmpegHDRRenderer.CommandExecutionStats(
                stageLabel: "Presentation intermediate",
                renderIntent: .presentationIntermediate,
                encoder: "hevc_videotoolbox",
                clipAuditBreakdown: [
                    RenderClipAuditBreakdown(
                        kind: .still,
                        hasCaptureDateOverlay: false,
                        clipCount: 1
                    )
                ],
                expectedDurationSeconds: 12,
                elapsedSeconds: 9,
                startupLatencySeconds: 1.2,
                firstOutputGrowthLatencySeconds: 1.5,
                finalOutputSizeBytes: 12_345_678,
                latestOutTimeMicroseconds: 12_000_000,
                latestSpeed: 1.10,
                latestFrameCount: 720,
                effectiveRealtimeFactor: 1.33,
                longestInactivityGapSeconds: 2.4,
                terminationSummary: "exit 0",
                outputPath: "/tmp/presentation-output.mov"
            )
        )
        diagnostics.recordFFmpegCommandSummary(
            FFmpegHDRRenderer.CommandExecutionStats(
                stageLabel: "Final delivery",
                renderIntent: .finalDelivery,
                encoder: "libx265",
                expectedDurationSeconds: 90,
                elapsedSeconds: 120,
                startupLatencySeconds: 3.2,
                firstOutputGrowthLatencySeconds: 4.5,
                finalOutputSizeBytes: 456_789_123,
                latestOutTimeMicroseconds: 90_000_000,
                latestSpeed: 0.82,
                latestFrameCount: 5_400,
                effectiveRealtimeFactor: 0.75,
                longestInactivityGapSeconds: 8.4,
                terminationSummary: "exit 0",
                outputPath: "/tmp/final-output.mov"
            )
        )
        diagnostics.add("Render started")

        let report = diagnostics.renderReport(outcome: "success", error: nil)

        XCTAssertTrue(report.contains("Timing Summary"))
        XCTAssertTrue(report.contains("Clip Preparation Breakdown"))
        XCTAssertTrue(report.contains("Slowest Preparation Operations"))
        XCTAssertTrue(report.contains("FFmpeg Command Summary"))
        XCTAssertTrue(report.contains("Progressive Presentation Clip Audit"))
        XCTAssertTrue(report.contains("- Render setup: count=2 | total=2.00s | avg=1.00s"))
        XCTAssertTrue(report.contains("- FFmpeg/direct export: count=1 | total=12.50s | avg=12.50s"))
        XCTAssertTrue(report.contains("- Still clip generation: count=2 | total=2.00s | avg=1.00s | max=1.50s"))
        XCTAssertTrue(report.contains("- Capture-date overlay generation: count=1 | total=0.20s | avg=0.20s | max=0.20s"))
        XCTAssertTrue(report.contains("By intent:"))
        XCTAssertTrue(report.contains("Commands:"))
        XCTAssertTrue(report.contains("clip_audit=still:plain:1"))
        XCTAssertTrue(report.contains("- still / plain: commands=1 | clips=1 | total=9.00s"))
        XCTAssertTrue(report.contains("Final delivery"))
        XCTAssertTrue(report.contains("output_path=/tmp/final-output.mov"))
        XCTAssertTrue(report.contains("Render started"))
    }

    func testRenderDiagnosticsReportCapsSlowPreparationOperationsAtFiveSortedDescending() {
        let diagnostics = AVFoundationRenderEngine.RenderDiagnostics()
        let operations: [(String, TimeInterval)] = [
            ("slowest-1", 1),
            ("slowest-2", 2),
            ("slowest-3", 3),
            ("slowest-4", 4),
            ("slowest-5", 5),
            ("slowest-6", 6)
        ]

        for (detail, elapsedSeconds) in operations {
            diagnostics.recordPreparationOperation(.clipProbe, detail: detail, elapsedSeconds: elapsedSeconds)
        }

        let report = diagnostics.renderReport(outcome: "success", error: nil)
        let section = section(named: "Slowest Preparation Operations", in: report)

        XCTAssertFalse(section.contains("slowest-1"))
        XCTAssertEqual(section.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 5)
        assertOrdered(in: section, expectedOrder: [
            "slowest-6",
            "slowest-5",
            "slowest-4",
            "slowest-3",
            "slowest-2"
        ])
    }

    private func section(named title: String, in report: String) -> String {
        let parts = report.components(separatedBy: "\n\n")
        return parts.first(where: { $0.hasPrefix(title) }) ?? report
    }

    private func assertOrdered(in text: String, expectedOrder: [String], file: StaticString = #filePath, line: UInt = #line) {
        let ranges = expectedOrder.compactMap { token in
            text.range(of: token)?.lowerBound
        }
        XCTAssertEqual(ranges.count, expectedOrder.count, file: file, line: line)
        for index in 0..<(ranges.count - 1) {
            XCTAssertLessThan(ranges[index], ranges[index + 1], file: file, line: line)
        }
    }
}
