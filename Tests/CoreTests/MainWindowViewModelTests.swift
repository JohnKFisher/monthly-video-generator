import AVFoundation
import Core
import Foundation
@testable import MonthlyVideoGeneratorApp
import XCTest

@MainActor
final class MainWindowViewModelTests: XCTestCase {
    func testInitialSourceDefaultsToApplePhotos() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore(),
            calendar: makeUTCGregorianCalendar(),
            nowProvider: { self.makeDate(year: 2026, month: 3, day: 9) }
        )

        XCTAssertEqual(viewModel.sourceMode, .photos)
        XCTAssertEqual(viewModel.selectedPhotosFilterMode, .monthYear)
    }

    func testLaunchDefaultsUseMostRecentlyCompletedMonth() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore(),
            calendar: makeUTCGregorianCalendar(),
            nowProvider: { self.makeDate(year: 2026, month: 3, day: 9) }
        )

        XCTAssertEqual(viewModel.selectedMonth, 2)
        XCTAssertEqual(viewModel.selectedYear, 2026)
    }

    func testLaunchDefaultsRollJanuaryBackToPreviousDecember() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore(),
            calendar: makeUTCGregorianCalendar(),
            nowProvider: { self.makeDate(year: 2026, month: 1, day: 9) }
        )

        XCTAssertEqual(viewModel.selectedMonth, 12)
        XCTAssertEqual(viewModel.selectedYear, 2025)
    }

    func testPersistedAlbumFilterIsOverriddenBackToMonthYearOnLaunch() throws {
        let preferencesStore = makePreferencesStore()
        let payload: [String: Any] = [
            "includeOpeningTitle": true,
            "openingTitleText": "June 2026",
            "crossfadeDurationSeconds": 0.75,
            "stillImageDurationSeconds": 3.0,
            "selectedPhotosFilterMode": "album",
            "selectedPhotoAlbumID": "album-123",
            "selectedContainer": "mp4",
            "selectedVideoCodec": "hevc",
            "selectedFrameRatePolicy": "smart",
            "selectedResolutionPolicy": "smart",
            "selectedDynamicRange": "hdr",
            "selectedHDRBinaryMode": "bundledPreferred",
            "selectedHDRHEVCEncoderMode": "automatic",
            "selectedAudioLayout": "smart",
            "selectedBitrateMode": "balanced",
            "writeDiagnosticsLog": true
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        preferencesStore.set(data, forKey: "MainWindowViewModel.renderSettings.v1")

        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore,
            calendar: makeUTCGregorianCalendar(),
            nowProvider: { self.makeDate(year: 2026, month: 3, day: 9) }
        )

        XCTAssertEqual(viewModel.sourceMode, .photos)
        XCTAssertEqual(viewModel.selectedPhotosFilterMode, .monthYear)
        XCTAssertEqual(viewModel.selectedPhotoAlbumID, "album-123")
    }

    func testInitialOutputNameUsesPlexTVFormat() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore()
        )
        let monthYear = MonthYear(month: viewModel.selectedMonth, year: viewModel.selectedYear)

        XCTAssertEqual(viewModel.outputFilename, expectedOutputName(monthYear: monthYear))
        XCTAssertTrue(viewModel.isOutputNameAutoManaged)
        XCTAssertEqual(viewModel.plexDescriptionText, expectedDescription(monthYear: monthYear))
        XCTAssertTrue(viewModel.isPlexDescriptionAutoManaged)
    }

    func testDiagnosticsDefaultToOffWhenUnset() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore()
        )

        XCTAssertFalse(viewModel.writeDiagnosticsLog)
    }

    func testSavedDiagnosticsChoicePersistsAcrossLaunches() {
        let preferencesStore = makePreferencesStore()
        let initialViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        initialViewModel.writeDiagnosticsLog = true

        let restoredViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertTrue(restoredViewModel.writeDiagnosticsLog)
    }

    func testOpeningTitleCaptionDefaultsToFisherFamilyVideos() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore()
        )

        XCTAssertEqual(viewModel.openingTitleCaptionMode, .custom)
        XCTAssertEqual(viewModel.openingTitleCaptionText, "Fisher Family Videos")
    }

    func testStyleDurationDefaultsUseRequestedValues() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore()
        )

        XCTAssertEqual(viewModel.titleDurationSeconds, 7.5, accuracy: 0.0001)
        XCTAssertEqual(viewModel.crossfadeDurationSeconds, 1.0, accuracy: 0.0001)
        XCTAssertEqual(viewModel.stillImageDurationSeconds, 5.0, accuracy: 0.0001)
    }

    func testOpeningTitleDefaultsToSelectedMonthYearAndTracksMonthChanges() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore(),
            calendar: makeUTCGregorianCalendar(),
            nowProvider: { self.makeDate(year: 2026, month: 3, day: 9) }
        )

        XCTAssertEqual(viewModel.openingTitleText, "February 2026")

        viewModel.selectedMonth = 7
        viewModel.selectedYear = 2025

        XCTAssertEqual(viewModel.openingTitleText, "July 2025")
    }

    func testManualOpeningTitleIsPreservedWhenMonthChanges() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore(),
            calendar: makeUTCGregorianCalendar(),
            nowProvider: { self.makeDate(year: 2026, month: 3, day: 9) }
        )

        viewModel.openingTitleText = "Summer Highlights"
        viewModel.selectedMonth = 7
        viewModel.selectedYear = 2025

        XCTAssertEqual(viewModel.openingTitleText, "Summer Highlights")
    }

    func testMonthLabelIncludesNumberAndMonthName() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore()
        )

        XCTAssertEqual(viewModel.monthLabel(for: 1), "1 - January")
        XCTAssertEqual(viewModel.monthLabel(for: 12), "12 - December")
    }

    func testLegacyPersistedEngineSelectionIsNormalizedToBundledPreferred() throws {
        let preferencesStore = makePreferencesStore()
        let legacyPayload: [String: Any] = [
            "includeOpeningTitle": true,
            "openingTitleText": "June 2026",
            "crossfadeDurationSeconds": 0.75,
            "stillImageDurationSeconds": 3.0,
            "selectedPhotosFilterMode": "monthYear",
            "selectedPhotoAlbumID": "",
            "selectedContainer": "mp4",
            "selectedVideoCodec": "hevc",
            "selectedFrameRatePolicy": "smart",
            "selectedResolutionPolicy": "smart",
            "selectedDynamicRange": "hdr",
            "selectedHDRBinaryMode": "systemOnly",
            "selectedHDRHEVCEncoderMode": "automatic",
            "selectedAudioLayout": "smart",
            "selectedBitrateMode": "balanced",
            "writeDiagnosticsLog": true
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPayload)
        preferencesStore.set(data, forKey: "MainWindowViewModel.renderSettings.v1")

        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertEqual(viewModel.selectedHDRBinaryMode, .bundledPreferred)
    }

    func testOutputNameAutoSyncStopsAfterManualEditAndCanBeRestored() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore()
        )

        viewModel.selectedMonth = 6
        viewModel.selectedYear = 2025
        XCTAssertEqual(viewModel.outputFilename, expectedOutputName(monthYear: MonthYear(month: 6, year: 2025)))

        viewModel.outputFilename = "Manual Override"
        XCTAssertFalse(viewModel.isOutputNameAutoManaged)

        viewModel.selectedMonth = 7
        XCTAssertEqual(viewModel.outputFilename, "Manual Override")

        viewModel.useAutoGeneratedOutputName()
        XCTAssertTrue(viewModel.isOutputNameAutoManaged)
        XCTAssertEqual(viewModel.outputFilename, expectedOutputName(monthYear: MonthYear(month: 7, year: 2025)))
    }

    func testShowTitlePersistsAcrossLaunchesAndResetRestoresDefault() {
        let preferencesStore = makePreferencesStore()
        let initialViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        initialViewModel.plexShowTitle = "Fisher Archive"

        let restoredViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertEqual(restoredViewModel.plexShowTitle, "Fisher Archive")

        restoredViewModel.resetExportSettingsToPlexDefaults()

        XCTAssertEqual(restoredViewModel.plexShowTitle, "Family Videos")
    }

    func testResetExportSettingsRestoresCaptionAndDiagnosticsDefaults() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore()
        )

        viewModel.openingTitleCaptionText = "Cape Cod at dusk"
        viewModel.titleDurationSeconds = 3.0
        viewModel.crossfadeDurationSeconds = 0.5
        viewModel.stillImageDurationSeconds = 2.0
        viewModel.writeDiagnosticsLog = true

        viewModel.resetExportSettingsToPlexDefaults()

        XCTAssertEqual(viewModel.openingTitleCaptionMode, .custom)
        XCTAssertEqual(viewModel.openingTitleCaptionText, "Fisher Family Videos")
        XCTAssertEqual(viewModel.titleDurationSeconds, 7.5, accuracy: 0.0001)
        XCTAssertEqual(viewModel.crossfadeDurationSeconds, 1.0, accuracy: 0.0001)
        XCTAssertEqual(viewModel.stillImageDurationSeconds, 5.0, accuracy: 0.0001)
        XCTAssertFalse(viewModel.writeDiagnosticsLog)
    }

    func testPlexDescriptionDefaultsToMonthYearAndCanBeRestored() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore()
        )

        viewModel.selectedMonth = 6
        viewModel.selectedYear = 2025

        XCTAssertEqual(viewModel.plexDescriptionText, expectedDescription(monthYear: MonthYear(month: 6, year: 2025)))
        XCTAssertTrue(viewModel.isPlexDescriptionAutoManaged)

        viewModel.plexDescriptionText = "Summer lake trip"
        XCTAssertFalse(viewModel.isPlexDescriptionAutoManaged)

        viewModel.selectedMonth = 7
        XCTAssertEqual(viewModel.plexDescriptionText, "Summer lake trip")

        viewModel.useDefaultPlexDescription()
        XCTAssertTrue(viewModel.isPlexDescriptionAutoManaged)
        XCTAssertEqual(viewModel.plexDescriptionText, expectedDescription(monthYear: MonthYear(month: 7, year: 2025)))
    }

    func testFolderRenderResolvesMonthYearAtRenderTime() async throws {
        let julyCaptureDate = makeDate(year: 2024, month: 7, day: 12)
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(items: [makeImageItem(id: "image-1", captureDate: julyCaptureDate)])
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore(),
            exportProvenanceIdentity: OutputProvenanceAppIdentity(
                appName: "Monthly Video Generator",
                appVersion: "0.5.0",
                buildNumber: "20260307200552"
            )
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.selectedMonth = 6
        viewModel.selectedYear = 2025
        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory

        XCTAssertEqual(viewModel.outputFilename, expectedOutputName(monthYear: MonthYear(month: 6, year: 2025)))

        viewModel.startRender()
        await waitUntil(
            message: "Timed out waiting for single render to finish."
        ) {
            coordinator.renderRequests.count == 1 && !viewModel.isRendering
        }

        let resolvedMonthYear = MonthYear(month: 7, year: 2024)
        let request = try XCTUnwrap(coordinator.renderRequests.first)
        XCTAssertEqual(viewModel.outputFilename, expectedOutputName(monthYear: resolvedMonthYear))
        XCTAssertEqual(request.output.baseFilename, expectedOutputName(monthYear: resolvedMonthYear))
        XCTAssertEqual(request.plexTVMetadata?.identity.filenameBase, expectedOutputName(monthYear: resolvedMonthYear))
        XCTAssertEqual(request.plexTVMetadata?.embedded.description, expectedDescription(monthYear: resolvedMonthYear))
        XCTAssertEqual(request.plexTVMetadata?.embedded.creationTime, julyCaptureDate)
        XCTAssertFalse(request.chapters.isEmpty)
        XCTAssertEqual(request.chapters.last?.photoCount, 1)
    }

    func testFolderRenderMixedMonthFailureRevealsManualOverride() async throws {
        let juneCaptureDate = makeDate(year: 2025, month: 6, day: 18)
        let julyCaptureDate = makeDate(year: 2025, month: 7, day: 2)
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(
                items: [
                    makeImageItem(id: "image-1", captureDate: juneCaptureDate),
                    makeImageItem(id: "image-2", captureDate: julyCaptureDate)
                ]
            )
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore(),
            exportProvenanceIdentity: OutputProvenanceAppIdentity(
                appName: "Monthly Video Generator",
                appVersion: "0.5.0",
                buildNumber: "20260307200552"
            )
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.selectedMonth = 6
        viewModel.selectedYear = 2025
        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory

        viewModel.startRender()
        await waitUntil(
            message: "Timed out waiting for mixed-month render failure."
        ) {
            coordinator.prepareFolderRequests.count == 1 && !viewModel.isRendering
        }

        XCTAssertTrue(viewModel.showsManualMonthYearOverride)
        XCTAssertTrue(viewModel.manualMonthYearOverrideMessage.contains("span multiple months"))
        XCTAssertEqual(viewModel.manualMonthYearOverrideMonth, 7)
        XCTAssertEqual(viewModel.manualMonthYearOverrideYear, 2025)
        XCTAssertEqual(viewModel.outputFilename, expectedOutputName(monthYear: MonthYear(month: 7, year: 2025)))
        XCTAssertEqual(viewModel.plexDescriptionText, expectedDescription(monthYear: MonthYear(month: 7, year: 2025)))
        XCTAssertTrue(coordinator.renderRequests.isEmpty)
        XCTAssertTrue(viewModel.statusMessage.contains("Review the manual month/year override"))
    }

    func testManualMonthYearOverrideAllowsMixedFolderRender() async throws {
        let juneCaptureDate = makeDate(year: 2025, month: 6, day: 18)
        let julyCaptureDate = makeDate(year: 2025, month: 7, day: 2)
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(
                items: [
                    makeImageItem(id: "image-1", captureDate: juneCaptureDate),
                    makeImageItem(id: "image-2", captureDate: julyCaptureDate)
                ]
            )
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore(),
            exportProvenanceIdentity: OutputProvenanceAppIdentity(
                appName: "Monthly Video Generator",
                appVersion: "0.5.0",
                buildNumber: "20260307200552"
            )
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory

        viewModel.startRender()
        await waitUntil(
            message: "Timed out waiting for mixed-month failure prompt."
        ) {
            !viewModel.isRendering && viewModel.showsManualMonthYearOverride
        }

        viewModel.manualMonthYearOverrideMonth = 8
        viewModel.manualMonthYearOverrideYear = 2025
        viewModel.startRender()
        await waitUntil(
            message: "Timed out waiting for manual month/year override render."
        ) {
            coordinator.renderRequests.count == 1 && !viewModel.isRendering
        }

        let request = try XCTUnwrap(coordinator.renderRequests.first)
        let resolvedMonthYear = MonthYear(month: 8, year: 2025)
        XCTAssertEqual(request.output.baseFilename, expectedOutputName(monthYear: resolvedMonthYear))
        XCTAssertEqual(request.plexTVMetadata?.identity.episodeID, "S2025E0899")
        XCTAssertEqual(request.plexTVMetadata?.embedded.episodeSort, 899)
        XCTAssertEqual(request.plexTVMetadata?.embedded.description, expectedDescription(monthYear: resolvedMonthYear))
    }

    func testSingleRenderCompletionSummaryListsRequestedAndActualExportOptions() async throws {
        let preparation = makePreparation(
            items: [
                makeVideoItem(
                    id: "video-1",
                    captureDate: makeDate(year: 2025, month: 6, day: 15),
                    pixelSize: CGSize(width: 640, height: 360),
                    sourceFrameRate: 60,
                    sourceAudioChannelCount: 6
                )
            ]
        )
        let coordinator = RenderCoordinatorSpy(
            preparation: preparation,
            renderResultBuilder: { _, request, _ in
                let outputURL = request.output.directory
                    .appendingPathComponent(request.output.baseFilename)
                    .appendingPathExtension(request.export.container.fileExtension)
                return RenderResult(
                    outputURL: outputURL,
                    diagnosticsLogURL: nil,
                    backendSummary: "FFmpeg HDR backend [bundled] (encoder: hevcVideoToolbox)",
                    backendInfo: RenderBackendInfo(binarySource: .bundled, encoder: "hevcVideoToolbox"),
                    resolvedVideoInfo: ResolvedRenderVideoInfo(width: 1280, height: 720, frameRate: 60)
                )
            }
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore(),
            exportProvenanceIdentity: OutputProvenanceAppIdentity(
                appName: "Monthly Video Generator",
                appVersion: "0.5.0",
                buildNumber: "20260307200552"
            )
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory
        viewModel.selectedDynamicRange = .hdr
        viewModel.selectedAudioLayout = .smart
        viewModel.selectedResolutionPolicy = .smart
        viewModel.selectedFrameRatePolicy = .smart
        viewModel.selectedHDRHEVCEncoderMode = .automatic

        viewModel.startRender()
        await waitUntil(
            message: "Timed out waiting for single render summary."
        ) {
            !viewModel.isRendering && viewModel.lastSingleRenderCompletionSummary != nil
        }

        let summary = try XCTUnwrap(viewModel.lastSingleRenderCompletionSummary)
        XCTAssertEqual(
            summary.rows.map(\.title),
            ["Container", "Codec", "HDR HEVC Encoder", "Audio", "Bitrate", "Resolution", "Frame Rate", "Range", "Engine"]
        )
        XCTAssertEqual(value(in: summary, forRowNamed: "Container"), "MP4")
        XCTAssertEqual(value(in: summary, forRowNamed: "Codec"), "HEVC")
        XCTAssertEqual(value(in: summary, forRowNamed: "HDR HEVC Encoder"), "Default (VideoToolbox)")
        XCTAssertEqual(value(in: summary, forRowNamed: "Audio"), "Smart (5.1)")
        XCTAssertEqual(value(in: summary, forRowNamed: "Bitrate"), "Balanced")
        XCTAssertEqual(value(in: summary, forRowNamed: "Resolution"), "Smart (720p)")
        XCTAssertEqual(value(in: summary, forRowNamed: "Frame Rate"), "Smart (60 fps)")
        XCTAssertEqual(value(in: summary, forRowNamed: "Range"), "HDR")
        XCTAssertEqual(value(in: summary, forRowNamed: "Engine"), "Bundled Preferred")
        XCTAssertEqual(viewModel.renderCompleteAlertMessage, summary.alertMessage)
        XCTAssertTrue(summary.alertMessage.hasPrefix(summary.outputPath))
    }

    func testSingleRenderRequestKeepsResolvedMetadataSnapshot() async throws {
        let captureDate = makeDate(year: 2024, month: 7, day: 12)
        let preparation = makePreparation(
            items: [
                makeVideoItem(
                    id: "video-2",
                    captureDate: captureDate,
                    pixelSize: CGSize(width: 1280, height: 720),
                    sourceFrameRate: 60,
                    sourceAudioChannelCount: 2
                )
            ]
        )
        let coordinator = RenderCoordinatorSpy(
            preparation: preparation,
            suspendRenderUntilResumed: true,
            renderResultBuilder: { _, request, _ in
                let outputURL = request.output.directory
                    .appendingPathComponent(request.output.baseFilename)
                    .appendingPathExtension(request.export.container.fileExtension)
                return RenderResult(
                    outputURL: outputURL,
                    diagnosticsLogURL: nil,
                    backendSummary: "FFmpeg HDR backend [system] (encoder: libx265)",
                    backendInfo: RenderBackendInfo(binarySource: .system, encoder: "libx265"),
                    resolvedVideoInfo: ResolvedRenderVideoInfo(width: 1920, height: 1080, frameRate: 60)
                )
            }
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore(),
            exportProvenanceIdentity: OutputProvenanceAppIdentity(
                appName: "Monthly Video Generator",
                appVersion: "0.5.0",
                buildNumber: "20260307200552"
            )
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory
        viewModel.selectedDynamicRange = .hdr
        viewModel.selectedAudioLayout = .smart
        viewModel.selectedResolutionPolicy = .smart
        viewModel.selectedFrameRatePolicy = .smart
        viewModel.selectedHDRHEVCEncoderMode = .automatic
        viewModel.selectedMonth = 6
        viewModel.selectedYear = 2025

        viewModel.startRender()
        await waitUntil(
            message: "Timed out waiting for render request to start."
        ) {
            coordinator.renderRequests.count == 1
        }

        let request = try XCTUnwrap(coordinator.renderRequests.first)
        XCTAssertEqual(request.output.baseFilename, "Family Videos - S2024E0799 - July 2024")
        XCTAssertEqual(request.plexTVMetadata?.identity.showTitle, "Family Videos")
        XCTAssertEqual(request.plexTVMetadata?.embedded.description, "Fisher Family Monthly Video for July 2024")
        XCTAssertEqual(request.plexTVMetadata?.embedded.provenance?.software, "Monthly Video Generator")
        XCTAssertEqual(request.plexTVMetadata?.embedded.provenance?.version, "0.5.0 (20260307200552)")
        XCTAssertEqual(
            request.plexTVMetadata?.embedded.provenance?.information,
            "1280x720, 60 fps, HDR (HLG), HEVC, AAC Stereo, MP4, Balanced bitrate"
        )

        viewModel.plexShowTitle = "Changed After Start"
        viewModel.plexDescriptionText = "Changed After Start"
        viewModel.outputFilename = "Changed After Start"
        viewModel.selectedVideoCodec = .hevc
        viewModel.selectedAudioLayout = .mono
        viewModel.selectedResolutionPolicy = .fixed4K
        viewModel.selectedFrameRatePolicy = .fps30
        viewModel.selectedHDRHEVCEncoderMode = .videoToolbox

        coordinator.resumeRender()
        await waitUntil(
            message: "Timed out waiting for suspended render to finish."
        ) {
            !viewModel.isRendering && viewModel.lastSingleRenderCompletionSummary != nil
        }

        let summary = try XCTUnwrap(viewModel.lastSingleRenderCompletionSummary)
        XCTAssertEqual(value(in: summary, forRowNamed: "Codec"), "HEVC")
        XCTAssertEqual(value(in: summary, forRowNamed: "HDR HEVC Encoder"), "Default (libx265)")
        XCTAssertEqual(value(in: summary, forRowNamed: "Audio"), "Smart (Stereo)")
        XCTAssertEqual(value(in: summary, forRowNamed: "Resolution"), "Smart (1080p)")
        XCTAssertEqual(value(in: summary, forRowNamed: "Frame Rate"), "Smart (60 fps)")
        XCTAssertEqual(value(in: summary, forRowNamed: "Engine"), "Bundled Preferred (System Fallback)")

        XCTAssertEqual(request.output.baseFilename, "Family Videos - S2024E0799 - July 2024")
        XCTAssertEqual(request.plexTVMetadata?.identity.showTitle, "Family Videos")
        XCTAssertEqual(request.plexTVMetadata?.embedded.description, "Fisher Family Monthly Video for July 2024")
    }

    func testSystemFFmpegFallbackCanBeCancelled() async throws {
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(
                items: [makeImageItem(id: "image-1", captureDate: makeDate(year: 2025, month: 6, day: 15))]
            ),
            systemFallbackReason: "Bundled FFmpeg missing required features: zscale filter."
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore()
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory

        viewModel.startRender()
        await waitUntilSystemFFmpegFallbackPrompt(viewModel)
        viewModel.cancelSystemFFmpegFallback()
        await waitUntil(
            message: "Timed out waiting for fallback cancellation to finish."
        ) {
            !viewModel.isRendering
        }

        XCTAssertNil(viewModel.pendingSystemFFmpegFallbackConfirmation)
        XCTAssertFalse(viewModel.showRenderCompleteAlert)
        XCTAssertTrue(viewModel.statusMessage.contains("fallback was not approved"))
    }

    func testSystemFFmpegFallbackCanBeApproved() async throws {
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(
                items: [makeImageItem(id: "image-1", captureDate: makeDate(year: 2025, month: 6, day: 15))]
            ),
            systemFallbackReason: "Bundled FFmpeg not found.",
            renderResultBuilder: { _, request, _ in
                let outputURL = request.output.directory
                    .appendingPathComponent(request.output.baseFilename)
                    .appendingPathExtension(request.export.container.fileExtension)
                return RenderResult(
                    outputURL: outputURL,
                    diagnosticsLogURL: nil,
                    backendSummary: "FFmpeg HDR backend [system] (encoder: libx265)",
                    backendInfo: RenderBackendInfo(binarySource: .system, encoder: "libx265"),
                    resolvedVideoInfo: ResolvedRenderVideoInfo(width: 1920, height: 1080, frameRate: 30)
                )
            }
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore()
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory
        viewModel.selectedDynamicRange = .hdr

        viewModel.startRender()
        await waitUntilSystemFFmpegFallbackPrompt(viewModel)
        viewModel.approveSystemFFmpegFallback()
        await waitUntil(
            message: "Timed out waiting for approved fallback render to finish."
        ) {
            !viewModel.isRendering && viewModel.lastSingleRenderCompletionSummary != nil
        }

        let summary = try XCTUnwrap(viewModel.lastSingleRenderCompletionSummary)
        XCTAssertNil(viewModel.pendingSystemFFmpegFallbackConfirmation)
        XCTAssertTrue(viewModel.showRenderCompleteAlert)
        XCTAssertEqual(value(in: summary, forRowNamed: "Engine"), "Bundled Preferred (System Fallback)")
    }

    func testHDRHEVCEncoderSelectionPersistsAndResetRestoresDefault() {
        let preferencesStore = makePreferencesStore()
        let initialViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        initialViewModel.selectedHDRHEVCEncoderMode = .videoToolbox

        let restoredViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertEqual(restoredViewModel.selectedHDRHEVCEncoderMode, .videoToolbox)

        restoredViewModel.resetExportSettingsToPlexDefaults()

        XCTAssertEqual(restoredViewModel.selectedHDRHEVCEncoderMode, .automatic)
    }

    func testCaptureDateOverlayDefaultsToEnabled() {
        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: makePreferencesStore()
        )

        XCTAssertTrue(viewModel.showCaptureDateOverlay)
    }

    func testCaptureDateOverlayPersistsAcrossLaunches() {
        let preferencesStore = makePreferencesStore()
        let initialViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        initialViewModel.showCaptureDateOverlay = false

        let restoredViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertFalse(restoredViewModel.showCaptureDateOverlay)
    }

    func testCaptureDateOverlayMissingPersistedValueDefaultsToEnabled() throws {
        let preferencesStore = makePreferencesStore()
        let legacyPayload: [String: Any] = [
            "includeOpeningTitle": true,
            "openingTitleText": "June 2026",
            "crossfadeDurationSeconds": 0.75,
            "stillImageDurationSeconds": 3.0,
            "selectedPhotosFilterMode": "monthYear",
            "selectedPhotoAlbumID": "",
            "selectedContainer": "mp4",
            "selectedVideoCodec": "hevc",
            "selectedFrameRatePolicy": "smart",
            "selectedResolutionPolicy": "smart",
            "selectedDynamicRange": "hdr",
            "selectedHDRBinaryMode": "autoSystemThenBundled",
            "selectedHDRHEVCEncoderMode": "automatic",
            "selectedAudioLayout": "smart",
            "selectedBitrateMode": "balanced",
            "writeDiagnosticsLog": true
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPayload)
        preferencesStore.set(data, forKey: "MainWindowViewModel.renderSettings.v1")

        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertTrue(viewModel.showCaptureDateOverlay)
    }

    func testTitleDurationPersistsAcrossLaunches() {
        let preferencesStore = makePreferencesStore()
        let initialViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        initialViewModel.titleDurationSeconds = 6.25

        let restoredViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertEqual(restoredViewModel.titleDurationSeconds, 6.25, accuracy: 0.0001)
    }

    func testCrossfadeAndStillDurationPersistAcrossLaunches() {
        let preferencesStore = makePreferencesStore()
        let initialViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        initialViewModel.crossfadeDurationSeconds = 1.25
        initialViewModel.stillImageDurationSeconds = 4.5

        let restoredViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertEqual(restoredViewModel.crossfadeDurationSeconds, 1.25, accuracy: 0.0001)
        XCTAssertEqual(restoredViewModel.stillImageDurationSeconds, 4.5, accuracy: 0.0001)
    }

    func testOpeningTitleCaptionSettingsPersistAcrossLaunches() {
        let preferencesStore = makePreferencesStore()
        let initialViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        initialViewModel.openingTitleCaptionMode = .custom
        initialViewModel.openingTitleCaptionText = "Cape Cod at dusk"

        let restoredViewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertEqual(restoredViewModel.openingTitleCaptionMode, .custom)
        XCTAssertEqual(restoredViewModel.openingTitleCaptionText, "Cape Cod at dusk")
    }

    func testLegacyAutomaticOpeningTitleCaptionNormalizesToCustomDefaultText() throws {
        let preferencesStore = makePreferencesStore()
        let legacyPayload: [String: Any] = [
            "includeOpeningTitle": true,
            "openingTitleText": "June 2026",
            "openingTitleCaptionMode": "automatic",
            "crossfadeDurationSeconds": 0.75,
            "stillImageDurationSeconds": 3.0,
            "selectedPhotosFilterMode": "monthYear",
            "selectedPhotoAlbumID": "",
            "selectedContainer": "mp4",
            "selectedVideoCodec": "hevc",
            "selectedFrameRatePolicy": "smart",
            "selectedResolutionPolicy": "smart",
            "selectedDynamicRange": "hdr",
            "selectedHDRBinaryMode": "autoSystemThenBundled",
            "selectedHDRHEVCEncoderMode": "automatic",
            "selectedAudioLayout": "smart",
            "selectedBitrateMode": "balanced",
            "writeDiagnosticsLog": true
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPayload)
        preferencesStore.set(data, forKey: "MainWindowViewModel.renderSettings.v1")

        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertEqual(viewModel.titleDurationSeconds, 7.5, accuracy: 0.0001)
        XCTAssertEqual(viewModel.openingTitleCaptionMode, .custom)
        XCTAssertEqual(viewModel.openingTitleCaptionText, "Fisher Family Videos")
    }

    func testLegacyAutomaticOpeningTitleCaptionKeepsSavedTextWhenPresent() throws {
        let preferencesStore = makePreferencesStore()
        let legacyPayload: [String: Any] = [
            "includeOpeningTitle": true,
            "openingTitleText": "June 2026",
            "openingTitleCaptionMode": "automatic",
            "openingTitleCaptionText": "Cape Cod at dusk",
            "crossfadeDurationSeconds": 0.75,
            "stillImageDurationSeconds": 3.0,
            "selectedPhotosFilterMode": "monthYear",
            "selectedPhotoAlbumID": "",
            "selectedContainer": "mp4",
            "selectedVideoCodec": "hevc",
            "selectedFrameRatePolicy": "smart",
            "selectedResolutionPolicy": "smart",
            "selectedDynamicRange": "hdr",
            "selectedHDRBinaryMode": "autoSystemThenBundled",
            "selectedHDRHEVCEncoderMode": "automatic",
            "selectedAudioLayout": "smart",
            "selectedBitrateMode": "balanced",
            "writeDiagnosticsLog": false
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPayload)
        preferencesStore.set(data, forKey: "MainWindowViewModel.renderSettings.v1")

        let viewModel = makeViewModel(
            coordinator: RenderCoordinatorSpy(preparation: makePreparation()),
            preferencesStore: preferencesStore
        )

        XCTAssertEqual(viewModel.openingTitleCaptionMode, .custom)
        XCTAssertEqual(viewModel.openingTitleCaptionText, "Cape Cod at dusk")
    }

    func testQueuedRenderUsesSnapshottedSettingsAfterLiveEdits() async throws {
        let captureDate = makeDate(year: 2024, month: 7, day: 12)
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(
                items: [makeImageItem(id: "image-1", captureDate: captureDate)]
            ),
            suspendRenderUntilResumed: true
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore()
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory
        viewModel.plexShowTitle = "Family Videos"
        viewModel.addCurrentSettingsToQueue()

        viewModel.plexShowTitle = "Changed After Queueing"
        viewModel.outputFilename = "Changed After Queueing"
        viewModel.selectedMonth = 8
        viewModel.selectedYear = 2026

        viewModel.startQueue()
        await waitUntil(
            message: "Timed out waiting for queued render request to start."
        ) {
            coordinator.renderRequests.count == 1
        }

        let request = try XCTUnwrap(coordinator.renderRequests.first)
        XCTAssertEqual(request.output.baseFilename, "Family Videos - S2024E0799 - July 2024")
        XCTAssertEqual(request.plexTVMetadata?.identity.showTitle, "Family Videos")

        coordinator.resumeRender()
        await waitUntil(
            message: "Timed out waiting for queued render to finish."
        ) {
            !viewModel.isRendering
        }
    }

    func testQueuedRendersRunInAddOrder() async throws {
        let coordinator = RenderCoordinatorSpy(preparation: makePreparation())
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore()
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory

        viewModel.outputFilename = "First Queue Job"
        viewModel.addCurrentSettingsToQueue()
        viewModel.outputFilename = "Second Queue Job"
        viewModel.addCurrentSettingsToQueue()

        viewModel.startQueue()
        await waitUntil(
            message: "Timed out waiting for queued renders to finish."
        ) {
            coordinator.renderRequests.count == 2 && !viewModel.isRendering
        }

        XCTAssertEqual(
            coordinator.renderRequests.map(\.output.baseFilename),
            ["First Queue Job", "Second Queue Job"]
        )
        XCTAssertEqual(viewModel.queuedRenderJobs.map(\.state), [.completed, .completed])
    }

    func testQueueProgressReflectsOverallCompletion() async throws {
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(),
            suspendRenderUntilResumed: true
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore()
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory
        viewModel.outputFilename = "Queue A"
        viewModel.addCurrentSettingsToQueue()
        viewModel.outputFilename = "Queue B"
        viewModel.addCurrentSettingsToQueue()

        viewModel.startQueue()
        await waitUntil(
            message: "Timed out waiting for first queued render progress."
        ) {
            coordinator.renderRequests.count == 1 && viewModel.progress >= 0.5
        }

        XCTAssertEqual(viewModel.progress, 0.5, accuracy: 0.001)

        coordinator.resumeRender()
        await waitUntil(
            message: "Timed out waiting for second queued render to start."
        ) {
            coordinator.renderRequests.count == 2
        }
        coordinator.resumeRender()
        await waitUntil(
            message: "Timed out waiting for queued progress test to finish."
        ) {
            !viewModel.isRendering
        }
    }

    func testQueueShowsCompletionAlertOnlyAfterFinalJob() async throws {
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(),
            suspendRenderUntilResumed: true
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore()
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory
        viewModel.outputFilename = "Queue One"
        viewModel.addCurrentSettingsToQueue()
        viewModel.outputFilename = "Queue Two"
        viewModel.addCurrentSettingsToQueue()

        viewModel.startQueue()
        await waitUntil(
            message: "Timed out waiting for first queued render."
        ) {
            coordinator.renderRequests.count == 1
        }
        XCTAssertFalse(viewModel.showRenderCompleteAlert)

        coordinator.resumeRender()
        await waitUntil(
            message: "Timed out waiting for second queued render."
        ) {
            coordinator.renderRequests.count == 2
        }
        XCTAssertFalse(viewModel.showRenderCompleteAlert)

        coordinator.resumeRender()
        await waitUntil(
            message: "Timed out waiting for queue completion alert."
        ) {
            !viewModel.isRendering && viewModel.showRenderCompleteAlert
        }

        XCTAssertEqual(viewModel.renderCompleteAlertTitle, "Queue Complete")
        XCTAssertTrue(viewModel.renderCompleteAlertMessage.contains("Completed 2 of 2 queued jobs."))
    }

    func testFailedQueuedJobPausesAndCanRetry() async throws {
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(),
            failedRenderIndices: [0]
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore()
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory
        viewModel.outputFilename = "Retry Me"
        viewModel.addCurrentSettingsToQueue()
        viewModel.outputFilename = "Second Pass"
        viewModel.addCurrentSettingsToQueue()

        viewModel.startQueue()
        await waitUntil(
            message: "Timed out waiting for queued failure."
        ) {
            !viewModel.isRendering && viewModel.queuedRenderJobs.first?.state == .failed
        }

        XCTAssertEqual(viewModel.queuedRenderJobs.map(\.state), [.failed, .queued])

        coordinator.failedRenderIndices = []
        viewModel.startQueue()
        await waitUntil(
            message: "Timed out waiting for queued retry to finish."
        ) {
            !viewModel.isRendering && viewModel.queuedRenderJobs.allSatisfy { $0.state == .completed }
        }

        XCTAssertEqual(coordinator.renderRequests.count, 3)
        XCTAssertEqual(viewModel.queuedRenderJobs.map(\.state), [.completed, .completed])
    }

    func testRemovingFailedQueuedJobAllowsRemainingJobsToContinue() async throws {
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(),
            failedRenderIndices: [0]
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore()
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory
        viewModel.outputFilename = "Will Fail"
        viewModel.addCurrentSettingsToQueue()
        viewModel.outputFilename = "Will Finish"
        viewModel.addCurrentSettingsToQueue()

        viewModel.startQueue()
        await waitUntil(
            message: "Timed out waiting for queued failure before removal."
        ) {
            !viewModel.isRendering && viewModel.queuedRenderJobs.first?.state == .failed
        }

        let failedJobID = try XCTUnwrap(viewModel.queuedRenderJobs.first?.id)
        viewModel.removeQueuedRenderJob(id: failedJobID)
        viewModel.startQueue()
        await waitUntil(
            message: "Timed out waiting for remaining queued job to finish."
        ) {
            !viewModel.isRendering &&
                viewModel.queuedRenderJobs.count == 1 &&
                viewModel.queuedRenderJobs[0].state == .completed
        }

        XCTAssertEqual(coordinator.renderRequests.count, 2)
        XCTAssertEqual(viewModel.queuedRenderJobs.count, 1)
        XCTAssertEqual(viewModel.queuedRenderJobs[0].state, .completed)
        XCTAssertEqual(viewModel.queuedRenderJobs[0].outputNamePreview, "Will Finish")
    }

    func testCancellingQueueLeavesUnfinishedJobsQueued() async throws {
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(),
            renderDelay: .milliseconds(300)
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore()
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory
        viewModel.outputFilename = "Cancel One"
        viewModel.addCurrentSettingsToQueue()
        viewModel.outputFilename = "Cancel Two"
        viewModel.addCurrentSettingsToQueue()

        viewModel.startQueue()
        await waitUntil(
            message: "Timed out waiting for queue to begin before cancellation."
        ) {
            coordinator.renderRequests.count == 1 && viewModel.isRendering
        }

        viewModel.cancelRender()
        await waitUntil(
            timeout: 5.0,
            message: "Timed out waiting for queue cancellation."
        ) {
            !viewModel.isRendering
        }

        XCTAssertEqual(viewModel.queuedRenderJobs.map(\.state), [.queued, .queued])
        XCTAssertEqual(coordinator.cancelCurrentRenderCallCount, 1)
        XCTAssertEqual(viewModel.statusMessage, "Render cancelled")
    }

    func testSystemFFmpegFallbackApprovalLetsQueueContinue() async throws {
        let coordinator = RenderCoordinatorSpy(
            preparation: makePreparation(),
            systemFallbackReason: "Bundled FFmpeg not found."
        )
        let viewModel = makeViewModel(
            coordinator: coordinator,
            preferencesStore: makePreferencesStore()
        )
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        viewModel.sourceMode = .folder
        viewModel.selectedFolderURL = directory
        viewModel.outputDirectoryURL = directory
        viewModel.selectedDynamicRange = .hdr
        viewModel.outputFilename = "Fallback One"
        viewModel.addCurrentSettingsToQueue()
        viewModel.outputFilename = "Fallback Two"
        viewModel.addCurrentSettingsToQueue()

        viewModel.startQueue()
        await waitUntilSystemFFmpegFallbackPrompt(viewModel)
        XCTAssertEqual(coordinator.renderRequests.count, 1)

        viewModel.approveSystemFFmpegFallback()
        await waitUntil(
            message: "Timed out waiting for fallback queue to finish."
        ) {
            !viewModel.isRendering && viewModel.queuedRenderJobs.allSatisfy { $0.state == .completed }
        }

        XCTAssertEqual(coordinator.renderRequests.count, 2)
        XCTAssertTrue(viewModel.showRenderCompleteAlert)
        XCTAssertEqual(viewModel.renderCompleteAlertTitle, "Queue Complete")
    }

    private func makeViewModel(
        coordinator: RenderCoordinating,
        preferencesStore: UserDefaults,
        exportProvenanceIdentity: OutputProvenanceAppIdentity = AppMetadata.exportProvenanceIdentity,
        calendar: Calendar = .current,
        nowProvider: @escaping () -> Date = Date.init
    ) -> MainWindowViewModel {
        MainWindowViewModel(
            coordinator: coordinator,
            preferencesStore: preferencesStore,
            filenameGenerator: PlexTVFilenameGenerator(),
            exportProvenanceIdentity: exportProvenanceIdentity,
            calendar: calendar,
            nowProvider: nowProvider
        )
    }

    private func makePreparation(items: [MediaItem]? = nil) -> RenderPreparation {
        let resolvedItems = items ?? [makeImageItem()]
        let style = StyleProfile.stageOneDefault
        let timeline = TimelineBuilder().buildTimeline(
            items: resolvedItems,
            ordering: .captureDateAscendingStable,
            style: style
        )
        return RenderPreparation(items: resolvedItems, timeline: timeline, warnings: [])
    }

    private func makeImageItem(
        id: String = "image",
        captureDate: Date = Date(),
        pixelSize: CGSize = CGSize(width: 1920, height: 1080)
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: .image,
            captureDate: captureDate,
            duration: nil,
            pixelSize: pixelSize,
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/\(id).jpg")),
            fileSizeBytes: 1_000,
            filename: "\(id).jpg"
        )
    }

    private func makeVideoItem(
        id: String,
        captureDate: Date = Date(),
        pixelSize: CGSize,
        sourceFrameRate: Double?,
        sourceAudioChannelCount: Int?
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: .video,
            captureDate: captureDate,
            duration: CMTime(seconds: 4, preferredTimescale: 600),
            sourceFrameRate: sourceFrameRate,
            sourceAudioChannelCount: sourceAudioChannelCount,
            pixelSize: pixelSize,
            colorInfo: .unknown,
            locator: .file(URL(fileURLWithPath: "/tmp/\(id).mov")),
            fileSizeBytes: 10_000,
            filename: "\(id).mov"
        )
    }

    private func makePreferencesStore() -> UserDefaults {
        let suiteName = "MainWindowViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        let calendar = makeUTCGregorianCalendar()
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    private func makeUTCGregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func expectedOutputName(showTitle: String = "Family Videos", monthYear: MonthYear) -> String {
        PlexTVFilenameGenerator().makeOutputName(showTitle: showTitle, monthYear: monthYear)
    }

    private func expectedDescription(monthYear: MonthYear) -> String {
        "Fisher Family Monthly Video for \(monthYear.displayLabel)"
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        message: String,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), message)
    }

    private func waitUntilSystemFFmpegFallbackPrompt(
        _ viewModel: MainWindowViewModel,
        timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.pendingSystemFFmpegFallbackConfirmation == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(
            viewModel.pendingSystemFFmpegFallbackConfirmation,
            "Timed out waiting for system FFmpeg fallback prompt."
        )
    }

    private func value(
        in summary: MainWindowViewModel.RenderCompletionSummary,
        forRowNamed title: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        guard let row = summary.rows.first(where: { $0.title == title }) else {
            XCTFail("Missing summary row named \(title)", file: file, line: line)
            return ""
        }
        return row.displayValue
    }
}

@MainActor
private final class RenderCoordinatorSpy: RenderCoordinating, @unchecked Sendable {
    let preparation: RenderPreparation
    var failedRenderIndices: Set<Int>
    let suspendRenderUntilResumed: Bool
    let renderDelay: Duration?
    let renderResultBuilder: ((RenderPreparation, RenderRequest, Int) -> RenderResult)?
    let systemFallbackReason: String?
    private(set) var prepareFolderRequests: [RenderRequest] = []
    private(set) var renderRequests: [RenderRequest] = []
    private(set) var cancelCurrentRenderCallCount: Int = 0
    private var suspendedRenderContinuation: CheckedContinuation<Void, Never>?

    init(
        preparation: RenderPreparation,
        failedRenderIndices: Set<Int> = [],
        suspendRenderUntilResumed: Bool = false,
        renderDelay: Duration? = nil,
        systemFallbackReason: String? = nil,
        renderResultBuilder: ((RenderPreparation, RenderRequest, Int) -> RenderResult)? = nil
    ) {
        self.preparation = preparation
        self.failedRenderIndices = failedRenderIndices
        self.suspendRenderUntilResumed = suspendRenderUntilResumed
        self.renderDelay = renderDelay
        self.systemFallbackReason = systemFallbackReason
        self.renderResultBuilder = renderResultBuilder
    }

    func prepareFolderRender(request: RenderRequest) async throws -> RenderPreparation {
        prepareFolderRequests.append(request)
        return preparation
    }

    func prepareFromItems(
        _ items: [MediaItem],
        request: RenderRequest,
        additionalWarnings: [String]
    ) -> RenderPreparation {
        RenderPreparation(
            items: items,
            timeline: preparation.timeline,
            warnings: preparation.warnings + additionalWarnings
        )
    }

    func render(
        preparation: RenderPreparation,
        request: RenderRequest,
        photoMaterializer: PhotoAssetMaterializing?,
        writeDiagnosticsLog: Bool,
        progressHandler: RenderProgressHandler,
        statusHandler: RenderStatusHandler,
        systemFFmpegFallbackHandler: SystemFFmpegFallbackHandler?
    ) async throws -> RenderResult {
        let index = renderRequests.count
        renderRequests.append(request)
        statusHandler?(writeDiagnosticsLog ? "Encoding with diagnostics" : "Encoding")
        progressHandler?(1.0)

        if let systemFallbackReason {
            let approved = await systemFFmpegFallbackHandler?(
                SystemFFmpegFallbackRequest(reason: systemFallbackReason)
            ) ?? true
            guard approved else {
                throw RenderError.exportFailed("Render cancelled because system FFmpeg fallback was not approved.")
            }
        }

        if suspendRenderUntilResumed {
            await withCheckedContinuation { continuation in
                suspendedRenderContinuation = continuation
            }
        }

        if let renderDelay {
            try await Task.sleep(for: renderDelay)
        }

        if failedRenderIndices.contains(index) {
            throw RenderError.exportFailed("Simulated failure \(index)")
        }

        let outputURL = request.output.directory
            .appendingPathComponent(request.output.baseFilename)
            .appendingPathExtension(request.export.container.fileExtension)
        if let renderResultBuilder {
            return renderResultBuilder(preparation, request, index)
        }
        return RenderResult(
            outputURL: outputURL,
            diagnosticsLogURL: nil,
            backendSummary: nil,
            backendInfo: RenderBackendInfo(
                binarySource: defaultBinarySource(for: request.export.hdrFFmpegBinaryMode),
                encoder: defaultEncoder(for: request.export)
            ),
            resolvedVideoInfo: ResolvedRenderVideoInfo(
                width: defaultVideoDimensions(for: request.export.resolution).width,
                height: defaultVideoDimensions(for: request.export.resolution).height,
                frameRate: defaultFrameRate(for: request.export.frameRate)
            )
        )
    }

    func cancelCurrentRender() {
        cancelCurrentRenderCallCount += 1
    }

    func resumeRender() {
        suspendedRenderContinuation?.resume()
        suspendedRenderContinuation = nil
    }

    private func defaultBinarySource(for mode: HDRFFmpegBinaryMode) -> RenderBackendBinarySource {
        switch mode {
        case .bundledPreferred, .bundledOnly:
            return .bundled
        case .autoSystemThenBundled, .systemOnly:
            return .system
        }
    }

    private func defaultFrameRate(for policy: FrameRatePolicy) -> Int {
        switch policy {
        case .fps30, .smart:
            return 30
        case .fps60:
            return 60
        }
    }

    private func defaultEncoder(for profile: ExportProfile) -> String? {
        switch (profile.dynamicRange, profile.videoCodec, profile.hdrHEVCEncoderMode) {
        case (.hdr, .hevc, .videoToolbox):
            return "hevcVideoToolbox"
        case (.hdr, .hevc, .automatic):
            return "libx265"
        case (.sdr, .hevc, _):
            return "hevcVideoToolbox"
        case (.sdr, .h264, _), (.hdr, .h264, _):
            return "h264VideoToolbox"
        }
    }

    private func defaultVideoDimensions(for policy: ResolutionPolicy) -> (width: Int, height: Int) {
        switch policy.normalized {
        case .fixed720p:
            return (1280, 720)
        case .fixed1080p, .smart:
            return (1920, 1080)
        case .fixed4K:
            return (3840, 2160)
        case .matchSourceMax:
            return (1920, 1080)
        }
    }
}
