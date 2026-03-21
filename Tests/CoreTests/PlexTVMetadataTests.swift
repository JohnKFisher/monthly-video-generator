@testable import Core
import Foundation
import XCTest

final class PlexTVMetadataTests: XCTestCase {
    func testResolverBuildsPlexEpisodeIdentityForExplicitMonthYear() {
        let metadata = PlexTVMetadataResolver.resolveMetadata(
            showTitle: "Family Videos",
            monthYear: MonthYear(month: 6, year: 2026),
            descriptionText: "Fisher Family Monthly Video for June 2026",
            creationTime: makeDate(year: 2026, month: 6, day: 28)
        )

        XCTAssertEqual(metadata.identity.showTitle, "Family Videos")
        XCTAssertEqual(metadata.identity.episodeTitle, "June 2026")
        XCTAssertEqual(metadata.identity.seasonNumber, 2026)
        XCTAssertEqual(metadata.identity.episodeSort, 699)
        XCTAssertEqual(metadata.identity.episodeID, "S2026E0699")
        XCTAssertEqual(metadata.identity.filenameBase, "Family Videos - S2026E0699 - June 2026")
        XCTAssertEqual(metadata.embedded.show, "Family Videos")
        XCTAssertEqual(metadata.embedded.title, "June 2026")
        XCTAssertEqual(metadata.embedded.seasonNumber, 2026)
        XCTAssertEqual(metadata.embedded.episodeSort, 699)
        XCTAssertEqual(metadata.embedded.episodeID, "S2026E0699")
        XCTAssertEqual(metadata.embedded.date, "2026")
        XCTAssertEqual(metadata.embedded.genre, "Family")
    }

    func testResolverUsesFallbackCreationTimeAtMonthEndWhenMissing() {
        let monthYear = MonthYear(month: 6, year: 2026)
        let metadata = PlexTVMetadataResolver.resolveMetadata(
            showTitle: "Family Videos",
            monthYear: monthYear,
            descriptionText: "Fisher Family Monthly Video for June 2026",
            creationTime: nil,
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )

        XCTAssertEqual(
            metadata.embedded.creationTime,
            monthYear.dateInterval(in: TimeZone(secondsFromGMT: 0) ?? .current).end.addingTimeInterval(-1)
        )
    }

    func testResolverUsesEmbeddedTitleOverrideWithoutChangingEpisodeIdentity() {
        let metadata = PlexTVMetadataResolver.resolveMetadata(
            showTitle: "Family Videos",
            monthYear: MonthYear(month: 6, year: 2026),
            descriptionText: "Fisher Family Monthly Video for June 2026",
            embeddedTitleOverride: "Summer Highlights",
            creationTime: makeDate(year: 2026, month: 6, day: 28)
        )

        XCTAssertEqual(metadata.identity.episodeTitle, "June 2026")
        XCTAssertEqual(metadata.identity.filenameBase, "Family Videos - S2026E0699 - June 2026")
        XCTAssertEqual(metadata.embedded.title, "Summer Highlights")
    }

    func testProvenanceResolverBuildsStandardAndCustomMetadata() throws {
        let item = makeImageItem(id: "image-1", captureDate: makeDate(year: 2026, month: 6, day: 28))
        let timeline = TimelineBuilder().buildTimeline(
            items: [item],
            ordering: .captureDateAscendingStable,
            style: .stageOneDefault
        )
        let exportProfile = ExportProfile(
            container: .mp4,
            videoCodec: .hevc,
            audioCodec: .aac,
            frameRate: .fps60,
            resolution: .fixed720p,
            dynamicRange: .hdr,
            audioLayout: .stereo,
            bitrateMode: .balanced
        )

        let provenance = EmbeddedOutputProvenanceResolver.resolve(
            exportProfile: exportProfile,
            timeline: timeline,
            appIdentity: OutputProvenanceAppIdentity(
                appName: "Monthly Video Generator",
                appVersion: "0.5.0",
                buildNumber: "20260307200552"
            )
        )

        XCTAssertEqual(provenance.software, "Monthly Video Generator")
        XCTAssertEqual(provenance.version, "0.5.0 (20260307200552)")
        XCTAssertEqual(
            provenance.information,
            "1280x720, 60 fps, HDR (HLG), HEVC, AAC Stereo, MP4, Balanced bitrate"
        )
        XCTAssertEqual(
            provenance.customEntries["com.jkfisher.monthlyvideogenerator.app_name"],
            "Monthly Video Generator"
        )
        XCTAssertEqual(
            provenance.customEntries["com.jkfisher.monthlyvideogenerator.app_version"],
            "0.5.0"
        )
        XCTAssertEqual(
            provenance.customEntries["com.jkfisher.monthlyvideogenerator.build_number"],
            "20260307200552"
        )
        XCTAssertEqual(
            provenance.customEntries["com.jkfisher.monthlyvideogenerator.export_profile"],
            "container=mp4,videoCodec=hevc,audioCodec=aac,dynamicRange=hdr,resolutionPolicy=fixed720p,resolvedSize=1280x720,frameRatePolicy=fps60,resolvedFrameRate=60,audioLayout=stereo,bitrateMode=balanced"
        )

        let exportJSON = try XCTUnwrap(
            provenance.customEntries["com.jkfisher.monthlyvideogenerator.export_json"]?.data(using: .utf8)
        )
        let exportPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: exportJSON) as? [String: Any])
        XCTAssertEqual(exportPayload["appName"] as? String, "Monthly Video Generator")
        XCTAssertEqual(exportPayload["appVersion"] as? String, "0.5.0")
        XCTAssertEqual(exportPayload["buildNumber"] as? String, "20260307200552")
        XCTAssertEqual(exportPayload["resolvedWidth"] as? Int, 1280)
        XCTAssertEqual(exportPayload["resolvedHeight"] as? Int, 720)
        XCTAssertEqual(exportPayload["resolvedFrameRate"] as? Int, 60)
    }

    func testResolveMonthYearRejectsMissingCaptureDates() {
        let items = [
            MediaItem(
                id: "image-1",
                type: .image,
                captureDate: nil,
                duration: nil,
                pixelSize: CGSize(width: 1920, height: 1080),
                colorInfo: .unknown,
                locator: .file(URL(fileURLWithPath: "/tmp/image-1.jpg")),
                fileSizeBytes: 1_000,
                filename: "image-1.jpg"
            )
        ]

        XCTAssertThrowsError(try PlexTVMetadataResolver.resolveMonthYear(from: items)) { error in
            XCTAssertEqual(error as? MonthYearResolutionError, .noCaptureDates)
        }
    }

    func testResolveMonthYearRejectsMixedMonths() {
        let items = [
            makeImageItem(id: "image-1", captureDate: makeDate(year: 2025, month: 6, day: 18)),
            makeImageItem(id: "image-2", captureDate: makeDate(year: 2025, month: 7, day: 2))
        ]

        XCTAssertThrowsError(try PlexTVMetadataResolver.resolveMonthYear(from: items)) { error in
            XCTAssertEqual(
                error as? MonthYearResolutionError,
                .multipleMonthYears([
                    MonthYear(month: 6, year: 2025),
                    MonthYear(month: 7, year: 2025)
                ])
            )
        }
    }

    func testResolveMonthYearReturnsSingleBucketAndLatestCaptureDate() throws {
        let older = makeDate(year: 2025, month: 6, day: 2)
        let newer = makeDate(year: 2025, month: 6, day: 28)
        let context = try PlexTVMetadataResolver.resolveMonthYear(
            from: [
                makeImageItem(id: "image-1", captureDate: older),
                makeImageItem(id: "image-2", captureDate: newer)
            ]
        )

        XCTAssertEqual(context.monthYear, MonthYear(month: 6, year: 2025))
        XCTAssertEqual(context.latestCaptureDate, newer)
    }

    func testRunReportIncludesPlexTVMetadataInSerializedJSON() throws {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let metadata = PlexTVMetadataResolver.resolveMetadata(
            showTitle: "Family Videos",
            monthYear: MonthYear(month: 6, year: 2026),
            descriptionText: "Fisher Family Monthly Video for June 2026",
            creationTime: makeDate(year: 2026, month: 6, day: 28),
            provenance: EmbeddedOutputProvenance(
                software: "Monthly Video Generator",
                version: "0.5.0 (20260307200552)",
                information: "1280x720, 60 fps, HDR (HLG), HEVC, AAC Stereo, MP4, Balanced bitrate",
                customEntries: [
                    "com.jkfisher.monthlyvideogenerator.app_name": "Monthly Video Generator",
                    "com.jkfisher.monthlyvideogenerator.app_version": "0.5.0"
                ]
            )
        )
        let request = RenderRequest(
            source: .folder(path: outputDirectory, recursive: true),
            monthYear: nil,
            ordering: .captureDateAscendingStable,
            style: .stageOneDefault,
            export: .plexInfuseAppleTV4KDefault,
            output: OutputTarget(directory: outputDirectory, baseFilename: metadata.identity.filenameBase),
            plexTVMetadata: metadata,
            chapters: [
                RenderChapter(
                    kind: .openingTitle,
                    title: "June 2026",
                    startTimeSeconds: 0,
                    endTimeSeconds: 2.5
                ),
                RenderChapter(
                    kind: .captureDay,
                    title: "June 28 (1 photo)",
                    startTimeSeconds: 2.5,
                    endTimeSeconds: 5.5,
                    photoCount: 1,
                    videoCount: 0,
                    captureDayStart: makeDate(year: 2026, month: 6, day: 28)
                )
            ]
        )
        let preparation = RenderPreparation(
            items: [makeImageItem(id: "image-1", captureDate: makeDate(year: 2026, month: 6, day: 28))],
            timeline: TimelineBuilder().buildTimeline(
                items: [makeImageItem(id: "image-1", captureDate: makeDate(year: 2026, month: 6, day: 28))],
                ordering: .captureDateAscendingStable,
                style: .stageOneDefault
            ),
            warnings: []
        )
        let report = RunReportService().makeReport(
            request: request,
            preparation: preparation,
            outputURL: outputDirectory.appendingPathComponent("out.mp4"),
            diagnosticsLogURL: outputDirectory.appendingPathComponent("out.log"),
            renderBackendSummary: "FFmpeg backend"
        )
        let reportURL = outputDirectory.appendingPathComponent("report.json")

        try RunReportService().write(report, to: reportURL)

        let data = try Data(contentsOf: reportURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let plexJSON = try XCTUnwrap(json?["plexTVMetadata"] as? [String: Any])
        let identityJSON = try XCTUnwrap(plexJSON["identity"] as? [String: Any])
        let embeddedJSON = try XCTUnwrap(plexJSON["embedded"] as? [String: Any])
        let provenanceJSON = try XCTUnwrap(embeddedJSON["provenance"] as? [String: Any])
        let customEntriesJSON = try XCTUnwrap(provenanceJSON["customEntries"] as? [String: Any])
        let chaptersJSON = try XCTUnwrap(json?["chapters"] as? [[String: Any]])

        XCTAssertEqual(identityJSON["showTitle"] as? String, "Family Videos")
        XCTAssertEqual(embeddedJSON["seasonNumber"] as? Int, 2026)
        XCTAssertEqual(embeddedJSON["episodeSort"] as? Int, 699)
        XCTAssertEqual(embeddedJSON["episodeID"] as? String, "S2026E0699")
        XCTAssertEqual(embeddedJSON["description"] as? String, "Fisher Family Monthly Video for June 2026")
        XCTAssertEqual(provenanceJSON["software"] as? String, "Monthly Video Generator")
        XCTAssertEqual(provenanceJSON["version"] as? String, "0.5.0 (20260307200552)")
        XCTAssertEqual(customEntriesJSON["com.jkfisher.monthlyvideogenerator.app_version"] as? String, "0.5.0")
        XCTAssertEqual(chaptersJSON.count, 2)
        XCTAssertEqual(chaptersJSON[0]["title"] as? String, "June 2026")
        XCTAssertEqual(chaptersJSON[1]["title"] as? String, "June 28 (1 photo)")
    }

    private func makeImageItem(id: String, captureDate: Date) -> MediaItem {
        MediaItem(
            id: id,
            type: .image,
            captureDate: captureDate,
            duration: nil,
            pixelSize: CGSize(width: 1920, height: 1080),
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/\(id).jpg")),
            fileSizeBytes: 1_000,
            filename: "\(id).jpg"
        )
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }
}
