import Core
import Foundation
import Photos
import PhotosIntegration
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

typealias RenderProgressHandler = (@MainActor @Sendable (Double) -> Void)?
typealias RenderStatusHandler = (@MainActor @Sendable (String) -> Void)?

@MainActor
protocol RenderCoordinating: AnyObject, Sendable {
    func prepareFolderRender(request: RenderRequest) async throws -> RenderPreparation
    func prepareFromItems(
        _ items: [MediaItem],
        request: RenderRequest,
        additionalWarnings: [String]
    ) -> RenderPreparation
    func render(
        preparation: RenderPreparation,
        request: RenderRequest,
        photoMaterializer: PhotoAssetMaterializing?,
        writeDiagnosticsLog: Bool,
        progressHandler: RenderProgressHandler,
        statusHandler: RenderStatusHandler
    ) async throws -> RenderResult
    func cancelCurrentRender()
}

extension RenderCoordinator: RenderCoordinating {}

@MainActor
final class MainWindowViewModel: ObservableObject {
    enum SourceMode: String, CaseIterable, Identifiable {
        case folder
        case photos

        var id: String { rawValue }

        var label: String {
            switch self {
            case .folder: return "Folder"
            case .photos: return "Apple Photos"
            }
        }
    }

    enum PhotosFilterMode: String, CaseIterable, Identifiable, Codable {
        case monthYear
        case album

        var id: String { rawValue }

        var label: String {
            switch self {
            case .monthYear:
                return "Month/Year"
            case .album:
                return "Album"
            }
        }
    }

    enum ViewModelError: LocalizedError {
        case missingFolder
        case missingAlbumSelection

        var errorDescription: String? {
            switch self {
            case .missingFolder:
                return "Choose an input folder before rendering."
            case .missingAlbumSelection:
                return "Choose a Photos album before rendering."
            }
        }
    }

    private struct PreparedRenderSession {
        let source: MediaSource
        let monthYear: MonthYear?
        let style: StyleProfile
        let preparation: RenderPreparation
        let usesPhotoMaterializer: Bool
    }

    private struct ResolvedPlexRenderDetails {
        let monthYearContext: ResolvedMonthYearContext
        let metadata: PlexTVMetadata
        let outputBaseFilename: String
    }

    struct RenderCompletionSummary: Equatable {
        struct Row: Equatable {
            let title: String
            let selectedLabel: String
            let actualLabel: String

            var displayValue: String {
                if selectedLabel == actualLabel {
                    return selectedLabel
                }
                return "\(selectedLabel) (\(actualLabel))"
            }

            var displayLine: String {
                "\(title): \(displayValue)"
            }
        }

        let outputPath: String
        let rows: [Row]

        var alertMessage: String {
            var lines: [String] = []
            if outputPath.isEmpty {
                lines.append("The slideshow was exported successfully.")
            } else {
                lines.append(outputPath)
            }

            if !rows.isEmpty {
                lines.append("")
                lines.append(contentsOf: rows.map(\.displayLine))
            }

            return lines.joined(separator: "\n")
        }
    }

    private struct SingleRenderSummarySnapshot: Sendable {
        let requestedProfile: ExportProfile
    }

    @Published var sourceMode: SourceMode = .folder {
        didSet {
            refreshPhotoAlbumsIfNeeded()
            resetManualMonthYearOverride()
            synchronizePlexAutoManagedFieldsIfNeeded()
        }
    }
    @Published var selectedFolderURL: URL?
    @Published var recursiveScan: Bool = true

    @Published var selectedMonth: Int {
        didSet {
            handleRenderSettingChange()
            synchronizePlexAutoManagedFieldsIfNeeded()
        }
    }
    @Published var selectedYear: Int {
        didSet {
            handleRenderSettingChange()
            synchronizePlexAutoManagedFieldsIfNeeded()
        }
    }
    @Published var selectedPhotosFilterMode: PhotosFilterMode = .monthYear {
        didSet {
            handleRenderSettingChange()
            refreshPhotoAlbumsIfNeeded()
            resetManualMonthYearOverride()
            synchronizePlexAutoManagedFieldsIfNeeded()
        }
    }
    @Published var selectedPhotoAlbumID: String = "" {
        didSet {
            handleRenderSettingChange()
            resetManualMonthYearOverride()
            synchronizePlexAutoManagedFieldsIfNeeded()
        }
    }
    @Published private(set) var photoAlbums: [PhotoAlbumSummary] = []
    @Published private(set) var isLoadingPhotoAlbums: Bool = false
    @Published private(set) var photoAlbumsStatusMessage: String = ""

    @Published var outputDirectoryURL: URL
    @Published var plexShowTitle: String = MainWindowViewModel.defaultPlexShowTitle {
        didSet {
            handleRenderSettingChange()
            synchronizeAutoGeneratedOutputFilenameIfNeeded()
        }
    }
    @Published var outputFilename: String = "" {
        didSet { handleOutputFilenameEditedIfNeeded() }
    }
    @Published private(set) var isOutputNameAutoManaged: Bool = true
    @Published var plexDescriptionText: String = "" {
        didSet { handlePlexDescriptionEditedIfNeeded() }
    }
    @Published private(set) var isPlexDescriptionAutoManaged: Bool = true
    @Published private(set) var showsManualMonthYearOverride: Bool = false
    @Published private(set) var manualMonthYearOverrideMessage: String = ""
    @Published var manualMonthYearOverrideMonth: Int {
        didSet { handleManualMonthYearOverrideEdited() }
    }
    @Published var manualMonthYearOverrideYear: Int {
        didSet { handleManualMonthYearOverrideEdited() }
    }

    @Published var includeOpeningTitle: Bool = true {
        didSet { handleRenderSettingChange() }
    }
    @Published var openingTitleText: String {
        didSet { handleRenderSettingChange() }
    }
    @Published var titleDurationSeconds: Double = 2.5 {
        didSet { handleRenderSettingChange() }
    }
    @Published var openingTitleCaptionMode: OpeningTitleCaptionMode = .automatic {
        didSet { handleOpeningTitleCaptionModeChange(previousValue: oldValue) }
    }
    @Published var openingTitleCaptionText: String = "" {
        didSet { handleRenderSettingChange() }
    }
    @Published var crossfadeDurationSeconds: Double = 0.75 {
        didSet { handleRenderSettingChange() }
    }
    @Published var stillImageDurationSeconds: Double = 3.0 {
        didSet { handleRenderSettingChange() }
    }
    @Published var showCaptureDateOverlay: Bool = true {
        didSet { handleRenderSettingChange() }
    }

    @Published var selectedContainer: ContainerFormat = MainWindowViewModel.defaultExportProfile.container {
        didSet { handleRenderSettingChange() }
    }
    @Published var selectedVideoCodec: VideoCodec = MainWindowViewModel.defaultExportProfile.videoCodec {
        didSet { handleRenderSettingChange(enforceHDRConstraints: true) }
    }
    @Published var selectedFrameRatePolicy: FrameRatePolicy = MainWindowViewModel.defaultExportProfile.frameRate {
        didSet {
            handleRenderSettingChange()
            synchronizeAutoGeneratedOutputFilenameIfNeeded()
        }
    }
    @Published var selectedResolutionPolicy: ResolutionPolicy = MainWindowViewModel.defaultExportProfile.resolution {
        didSet {
            handleRenderSettingChange()
            synchronizeAutoGeneratedOutputFilenameIfNeeded()
        }
    }
    @Published var selectedDynamicRange: DynamicRange = MainWindowViewModel.defaultExportProfile.dynamicRange {
        didSet {
            handleRenderSettingChange(enforceHDRConstraints: true)
            synchronizeAutoGeneratedOutputFilenameIfNeeded()
        }
    }
    @Published var selectedHDRBinaryMode: HDRFFmpegBinaryMode = MainWindowViewModel.defaultExportProfile.hdrFFmpegBinaryMode {
        didSet { handleRenderSettingChange() }
    }
    @Published var selectedHDRHEVCEncoderMode: HDRHEVCEncoderMode = MainWindowViewModel.defaultExportProfile.hdrHEVCEncoderMode {
        didSet { handleRenderSettingChange() }
    }
    @Published var selectedAudioLayout: AudioLayout = MainWindowViewModel.defaultExportProfile.audioLayout {
        didSet {
            handleRenderSettingChange()
            synchronizeAutoGeneratedOutputFilenameIfNeeded()
        }
    }
    @Published var selectedBitrateMode: BitrateMode = MainWindowViewModel.defaultExportProfile.bitrateMode {
        didSet { handleRenderSettingChange() }
    }
    @Published var writeDiagnosticsLog: Bool = true {
        didSet { handleRenderSettingChange() }
    }

    @Published var isRendering: Bool = false
    @Published var progress: Double = 0
    @Published var statusMessage: String = "Idle"
    @Published var warnings: [String] = []
    @Published var lastOutputPath: String = ""
    @Published var lastDiagnosticsPath: String = ""
    @Published var lastBackendSummary: String = ""
    @Published private(set) var lastSingleRenderCompletionSummary: RenderCompletionSummary?
    @Published var showRenderCompleteAlert: Bool = false

    let appVersionBuildLabel: String
    let months = Array(1...12)
    let years: [Int]

    private let coordinator: RenderCoordinating
    private let photoDiscovery: PhotoKitMediaDiscoveryService
    private let photoMaterializer: PhotoKitAssetMaterializer
    private let exportProfileManager: ExportProfileManager
    private let runReportService: RunReportService
    private let preferencesStore: UserDefaults
    private let filenameGenerator: PlexTVFilenameGenerator
    private let exportProvenanceIdentity: OutputProvenanceAppIdentity
    private var renderTask: Task<Void, Never>?
    private var renderStatusDetail: String?
    private var isApplyingExportConstraints = false
    private var isRestoringPersistedSettings = false
    private var isApplyingOutputFilenameProgrammatically = false
    private var isApplyingPlexDescriptionProgrammatically = false

    private static let defaultExportProfile = ExportProfileManager().defaultProfile()
    private static let defaultPlexShowTitle = "Family Videos"
    private static let renderSettingsDefaultsKey = "MainWindowViewModel.renderSettings.v1"

    init(
        coordinator: RenderCoordinating = RenderCoordinator(),
        photoDiscovery: PhotoKitMediaDiscoveryService = PhotoKitMediaDiscoveryService(),
        photoMaterializer: PhotoKitAssetMaterializer = PhotoKitAssetMaterializer(),
        exportProfileManager: ExportProfileManager = ExportProfileManager(),
        runReportService: RunReportService = RunReportService(),
        preferencesStore: UserDefaults = .standard,
        filenameGenerator: PlexTVFilenameGenerator = PlexTVFilenameGenerator(),
        exportProvenanceIdentity: OutputProvenanceAppIdentity = AppMetadata.exportProvenanceIdentity
    ) {
        self.coordinator = coordinator
        self.photoDiscovery = photoDiscovery
        self.photoMaterializer = photoMaterializer
        self.exportProfileManager = exportProfileManager
        self.runReportService = runReportService
        self.preferencesStore = preferencesStore
        self.filenameGenerator = filenameGenerator
        self.exportProvenanceIdentity = exportProvenanceIdentity
        appVersionBuildLabel = AppMetadata.versionBuildLabel

        let now = Date()
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        selectedMonth = currentMonth
        selectedYear = currentYear
        manualMonthYearOverrideMonth = currentMonth
        manualMonthYearOverrideYear = currentYear
        openingTitleText = MonthYear(month: currentMonth, year: currentYear).displayLabel
        years = Array((currentYear - 15)...(currentYear + 2)).reversed()

        let moviesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Monthly Video Generator", isDirectory: true)
        outputDirectoryURL = moviesDirectory

        applyPersistedRenderSettings()
        useAutoGeneratedOutputName()
        synchronizeAutoManagedPlexDescriptionIfNeeded()
    }

    func chooseInputFolder() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.title = "Select Source Folder"

        if panel.runModal() == .OK {
            selectedFolderURL = panel.url
            resetManualMonthYearOverride()
        }
        #endif
    }

    func chooseOutputFolder() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.title = "Select Output Folder"

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectoryURL = url
        }
        #endif
    }

    func useAutoGeneratedOutputName() {
        applyOutputFilename(generatedOutputName(), autoManaged: true)
    }

    func useDefaultPlexDescription() {
        applyPlexDescription(defaultPlexDescription(), autoManaged: true)
    }

    func clearManualMonthYearOverride() {
        resetManualMonthYearOverride()
        synchronizePlexAutoManagedFieldsIfNeeded()
    }

    var hasPhotoAlbums: Bool {
        !photoAlbums.isEmpty
    }

    var outputNameAutomationDescription: String {
        let baseDescription = isOutputNameAutoManaged
            ? "Auto name uses Plex TV format \(generatedOutputName())."
            : "Manual output name override is active. Use “Use Auto Name” to restore the Plex TV auto name."

        if sourceMode == .folder || (sourceMode == .photos && selectedPhotosFilterMode == .album) {
            if showsManualMonthYearOverride {
                return "\(baseDescription) Folder and album renders are currently using the manual month/year override."
            }
            return "\(baseDescription) Folder and album renders finalize the month/year from media capture dates at render start."
        }
        return baseDescription
    }

    var plexDescriptionAutomationDescription: String {
        if isPlexDescriptionAutoManaged {
            return "Default text stays synced to the resolved month/year until you edit it."
        }
        return "Manual description override is active. Use “Use Default” to restore the month/year-based text."
    }

    func refreshPhotoAlbums() {
        Task {
            await loadPhotoAlbums(requestAuthorizationIfNeeded: true)
        }
    }

    var isHDRSelectionLocked: Bool {
        selectedDynamicRange == .hdr
    }

    var hdrSelectionLockReason: String {
        "HDR currently exports as HEVC Main10 video for Plex + Infuse playback on Apple TV 4K."
    }

    var hdrHEVCEncoderDescription: String {
        guard selectedDynamicRange == .hdr else {
            return "Applies only to HDR HEVC exports."
        }

        switch selectedHDRHEVCEncoderMode {
        case .automatic:
            return "Default preserves the current quality-first HDR order: libx265 first, then VideoToolbox if required."
        case .videoToolbox:
            return "VideoToolbox is faster for HDR HEVC on supported Macs, but may trade some compression efficiency and fails explicitly if unavailable for the selected FFmpeg engine."
        }
    }

    var bitrateModeDescription: String {
        "Bitrate mode controls FFmpeg encode quality, size, and speed tradeoffs for both SDR and HDR exports."
    }

    var frameRateDescription: String {
        switch selectedFrameRatePolicy {
        case .fps30:
            return "30 fps is the most compatible choice and keeps renders faster for photo-heavy slideshows."
        case .fps60:
            return "60 fps increases render time, CPU load, and file size significantly."
        case .smart:
            return "Smart exports at 30 fps unless any selected video is 50 fps or higher, then it exports at 60 fps."
        }
    }

    var photosSmartFrameRateDescription: String? {
        guard sourceMode == .photos, selectedFrameRatePolicy == .smart else {
            return nil
        }
        return "In Apple Photos mode, Smart fps may inspect/download selected videos before rendering to decide between 30 and 60 fps."
    }

    var photosSmartAudioDescription: String? {
        guard sourceMode == .photos, selectedAudioLayout == .smart else {
            return nil
        }
        return "In Apple Photos mode, Smart audio may inspect/download selected videos before rendering to choose Mono, Stereo, or 5.1."
    }

    var renderCompleteAlertMessage: String {
        if let lastSingleRenderCompletionSummary {
            return lastSingleRenderCompletionSummary.alertMessage
        }
        if lastOutputPath.isEmpty {
            return "The slideshow was exported successfully."
        }
        return lastOutputPath
    }

    func resetExportSettingsToPlexDefaults() {
        let profile = exportProfileManager.defaultProfile()
        isRestoringPersistedSettings = true
        plexShowTitle = Self.defaultPlexShowTitle
        selectedContainer = profile.container
        selectedVideoCodec = profile.videoCodec
        selectedFrameRatePolicy = profile.frameRate
        selectedResolutionPolicy = profile.resolution.normalized
        selectedDynamicRange = profile.dynamicRange
        selectedHDRBinaryMode = profile.hdrFFmpegBinaryMode
        selectedHDRHEVCEncoderMode = profile.hdrHEVCEncoderMode
        selectedAudioLayout = profile.audioLayout
        selectedBitrateMode = profile.bitrateMode
        writeDiagnosticsLog = true
        isRestoringPersistedSettings = false
        enforceHDRSelectionConstraints()
        resetManualMonthYearOverride()
        useAutoGeneratedOutputName()
        useDefaultPlexDescription()
        persistRenderSettings()
        warnings = exportProfileManager.compatibilityWarnings(for: profile).map(\.message)
    }

    func startRender() {
        guard !isRendering, renderTask == nil else { return }

        let completionSummarySnapshot = makeSingleRenderSummarySnapshot()
        renderTask = Task {
            await performSingleRender(completionSummarySnapshot: completionSummarySnapshot)
            await MainActor.run {
                self.renderTask = nil
            }
        }
    }

    func cancelRender() {
        renderTask?.cancel()
        photoMaterializer.cancelPendingRequests()
        coordinator.cancelCurrentRender()
        statusMessage = "Cancelling render..."
    }

    func openRenderedOutputFolder() {
        #if canImport(AppKit)
        let outputPath = lastOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryURL: URL
        if outputPath.isEmpty {
            directoryURL = outputDirectoryURL
        } else {
            directoryURL = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        }
        NSWorkspace.shared.open(directoryURL)
        #endif
    }

    private func performSingleRender(completionSummarySnapshot: SingleRenderSummarySnapshot) async {
        beginRenderRun(status: "Preparing media...")

        do {
            let monthYear = MonthYear(month: selectedMonth, year: selectedYear)
            let style = buildStyle(for: monthYear)
            let preparedSession = try await prepareRenderSession(
                style: style,
                monthYear: monthYear,
                requiresSmartFrameRateInspection: selectedFrameRatePolicy == .smart,
                requiresSmartAudioInspection: selectedAudioLayout == .smart
            )
            let exportResolution = resolveExportProfile(
                resolution: selectedResolutionPolicy.normalized,
                frameRate: selectedFrameRatePolicy,
                dynamicRange: selectedDynamicRange,
                audioLayout: selectedAudioLayout,
                hdrHEVCEncoderMode: selectedHDRHEVCEncoderMode,
                items: preparedSession.preparation.items
            )

            warnings = preparedSession.preparation.warnings + exportResolution.warnings.map(\.message)
            progress = max(progress, 0.08)
            renderStatusDetail = nil
            updateRenderingStatusMessage()

            let plexRenderDetails = try resolvePlexRenderDetails(
                preparedSession: preparedSession,
                fallbackMonthYear: monthYear,
                exportProfile: exportResolution.effectiveProfile,
                outputBaseFilenameOverride: nil
            )

            let request = makeRenderRequest(
                preparedSession: preparedSession,
                exportProfile: exportResolution.effectiveProfile,
                outputBaseFilename: plexRenderDetails.outputBaseFilename,
                plexTVMetadata: plexRenderDetails.metadata
            )
            let renderResult = try await renderSingleRequest(
                preparedSession: preparedSession,
                request: request,
                progressMapper: { $0 }
            )

            recordSuccessfulRender(
                renderResult,
                request: request,
                preparation: preparedSession.preparation,
                completionSummarySnapshot: completionSummarySnapshot
            )
            finishSuccessfulRun(status: "Render complete")
        } catch {
            finishFailedRun(error)
        }
    }

    private func buildStyle(for monthYear: MonthYear) -> StyleProfile {
        let openingTitle = includeOpeningTitle ? resolvedOpeningTitle(for: monthYear) : nil
        return StyleProfile(
            openingTitle: openingTitle,
            titleDurationSeconds: includeOpeningTitle ? titleDurationSeconds : 0,
            crossfadeDurationSeconds: crossfadeDurationSeconds,
            stillImageDurationSeconds: stillImageDurationSeconds,
            showCaptureDateOverlay: showCaptureDateOverlay,
            openingTitleCaptionMode: openingTitleCaptionMode,
            openingTitleCaptionText: openingTitleCaptionText
        )
    }

    private func previewMonthYear() -> MonthYear {
        if showsManualMonthYearOverride {
            return MonthYear(month: manualMonthYearOverrideMonth, year: manualMonthYearOverrideYear)
        }
        return MonthYear(month: selectedMonth, year: selectedYear)
    }

    private func resolvedPlexShowTitle() -> String {
        let trimmed = plexShowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultPlexShowTitle : trimmed
    }

    private func resolvePlexRenderDetails(
        preparedSession: PreparedRenderSession,
        fallbackMonthYear: MonthYear,
        exportProfile: ExportProfile,
        outputBaseFilenameOverride: String?
    ) throws -> ResolvedPlexRenderDetails {
        let monthYearContext = try resolvePlexMonthYearContext(
            preparedSession: preparedSession,
            fallbackMonthYear: fallbackMonthYear
        )
        let autoDescription = PlexTVMetadataResolver.defaultDescription(for: monthYearContext.monthYear)
        if isPlexDescriptionAutoManaged {
            applyPlexDescription(autoDescription, autoManaged: true)
        }

        let provenance = EmbeddedOutputProvenanceResolver.resolve(
            exportProfile: exportProfile,
            timeline: preparedSession.preparation.timeline,
            appIdentity: exportProvenanceIdentity
        )
        let metadata = PlexTVMetadataResolver.resolveMetadata(
            showTitle: resolvedPlexShowTitle(),
            monthYear: monthYearContext.monthYear,
            descriptionText: isPlexDescriptionAutoManaged ? autoDescription : plexDescriptionText,
            creationTime: monthYearContext.latestCaptureDate,
            provenance: provenance
        )
        let autoOutputBaseFilename = metadata.identity.filenameBase
        if isOutputNameAutoManaged {
            applyOutputFilename(autoOutputBaseFilename, autoManaged: true)
        }

        return ResolvedPlexRenderDetails(
            monthYearContext: monthYearContext,
            metadata: metadata,
            outputBaseFilename: outputBaseFilenameOverride ?? (isOutputNameAutoManaged ? autoOutputBaseFilename : outputFilename)
        )
    }

    private func resolvePlexMonthYearContext(
        preparedSession: PreparedRenderSession,
        fallbackMonthYear: MonthYear
    ) throws -> ResolvedMonthYearContext {
        let latestCaptureDate = latestCaptureDate(from: preparedSession.preparation.items)
        if sourceMode == .photos, selectedPhotosFilterMode == .monthYear {
            return ResolvedMonthYearContext(monthYear: fallbackMonthYear, latestCaptureDate: latestCaptureDate)
        }
        if showsManualMonthYearOverride {
            return ResolvedMonthYearContext(
                monthYear: MonthYear(month: manualMonthYearOverrideMonth, year: manualMonthYearOverrideYear),
                latestCaptureDate: latestCaptureDate
            )
        }

        do {
            return try PlexTVMetadataResolver.resolveMonthYear(from: preparedSession.preparation.items)
        } catch {
            revealManualMonthYearOverride(
                using: preparedSession.preparation.items,
                fallbackMonthYear: fallbackMonthYear,
                error: error
            )
            let message = (error as? LocalizedError)?.errorDescription ?? "Unable to derive a single month/year for Plex TV naming."
            throw RenderError.exportFailed("\(message)\nReview the manual month/year override in Export and render again.")
        }
    }

    private func revealManualMonthYearOverride(
        using items: [MediaItem],
        fallbackMonthYear: MonthYear,
        error: Error
    ) {
        let suggestedMonthYear: MonthYear
        if let latestCaptureDate = latestCaptureDate(from: items) {
            let calendar = Calendar.current
            suggestedMonthYear = MonthYear(
                month: calendar.component(.month, from: latestCaptureDate),
                year: calendar.component(.year, from: latestCaptureDate)
            )
        } else {
            suggestedMonthYear = fallbackMonthYear
        }

        showsManualMonthYearOverride = false
        manualMonthYearOverrideMonth = suggestedMonthYear.month
        manualMonthYearOverrideYear = suggestedMonthYear.year
        showsManualMonthYearOverride = true
        manualMonthYearOverrideMessage = (error as? LocalizedError)?.errorDescription ?? "Unable to derive a single month/year automatically."
        synchronizePlexAutoManagedFieldsIfNeeded()
    }

    private func latestCaptureDate(from items: [MediaItem]) -> Date? {
        items.compactMap(\.captureDate).max()
    }

    private func makeSingleRenderSummarySnapshot() -> SingleRenderSummarySnapshot {
        SingleRenderSummarySnapshot(
            requestedProfile: buildSelectedExportProfile(
                resolution: selectedResolutionPolicy.normalized,
                frameRate: selectedFrameRatePolicy,
                dynamicRange: selectedDynamicRange,
                audioLayout: selectedAudioLayout,
                hdrHEVCEncoderMode: selectedHDRHEVCEncoderMode
            )
        )
    }

    private func generatedOutputName() -> String {
        filenameGenerator.makeOutputName(
            showTitle: resolvedPlexShowTitle(),
            monthYear: previewMonthYear()
        )
    }

    private func defaultPlexDescription() -> String {
        PlexTVMetadataResolver.defaultDescription(for: previewMonthYear())
    }

    private func applyOutputFilename(_ value: String, autoManaged: Bool) {
        isApplyingOutputFilenameProgrammatically = true
        outputFilename = value
        isOutputNameAutoManaged = autoManaged
        isApplyingOutputFilenameProgrammatically = false
    }

    private func handleOutputFilenameEditedIfNeeded() {
        guard !isApplyingOutputFilenameProgrammatically else {
            return
        }
        isOutputNameAutoManaged = false
        handleRenderSettingChange()
    }

    private func applyPlexDescription(_ value: String, autoManaged: Bool) {
        isApplyingPlexDescriptionProgrammatically = true
        plexDescriptionText = value
        isPlexDescriptionAutoManaged = autoManaged
        isApplyingPlexDescriptionProgrammatically = false
        if !isRestoringPersistedSettings {
            persistRenderSettings()
        }
    }

    private func handlePlexDescriptionEditedIfNeeded() {
        guard !isApplyingPlexDescriptionProgrammatically else {
            return
        }
        isPlexDescriptionAutoManaged = false
        handleRenderSettingChange()
    }

    private func synchronizeAutoGeneratedOutputFilenameIfNeeded() {
        guard isOutputNameAutoManaged else {
            return
        }
        applyOutputFilename(generatedOutputName(), autoManaged: true)
    }

    private func synchronizeAutoManagedPlexDescriptionIfNeeded() {
        guard isPlexDescriptionAutoManaged else {
            return
        }
        applyPlexDescription(defaultPlexDescription(), autoManaged: true)
    }

    private func synchronizePlexAutoManagedFieldsIfNeeded() {
        guard !isRestoringPersistedSettings else {
            return
        }
        synchronizeAutoGeneratedOutputFilenameIfNeeded()
        synchronizeAutoManagedPlexDescriptionIfNeeded()
    }

    private func handleManualMonthYearOverrideEdited() {
        guard showsManualMonthYearOverride else {
            return
        }
        synchronizePlexAutoManagedFieldsIfNeeded()
    }

    private func resetManualMonthYearOverride() {
        showsManualMonthYearOverride = false
        manualMonthYearOverrideMessage = ""
        manualMonthYearOverrideMonth = selectedMonth
        manualMonthYearOverrideYear = selectedYear
    }

    private func beginRenderRun(status: String) {
        isRendering = true
        progress = 0.01
        warnings = []
        renderStatusDetail = nil
        statusMessage = status
        lastOutputPath = ""
        lastDiagnosticsPath = ""
        lastBackendSummary = ""
        lastSingleRenderCompletionSummary = nil
        showRenderCompleteAlert = false
    }

    private func finishSuccessfulRun(status: String) {
        renderStatusDetail = nil
        progress = 1.0
        statusMessage = status
        if !lastDiagnosticsPath.isEmpty {
            statusMessage += "\nDiagnostics: \(lastDiagnosticsPath)"
        }
        if !lastBackendSummary.isEmpty {
            statusMessage += "\nBackend: \(lastBackendSummary)"
        }
        showRenderCompleteAlert = true
        isRendering = false
    }

    private func finishFailedRun(_ error: Error) {
        renderStatusDetail = nil
        progress = 0
        statusMessage = formatErrorForDisplay(error)
        lastSingleRenderCompletionSummary = nil
        showRenderCompleteAlert = false
        isRendering = false
    }

    private func resolveExportProfile(
        resolution: ResolutionPolicy,
        frameRate: FrameRatePolicy,
        dynamicRange: DynamicRange,
        audioLayout: AudioLayout,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode,
        items: [MediaItem]
    ) -> ExportProfileResolution {
        exportProfileManager.resolveProfile(
            for: buildSelectedExportProfile(
                resolution: resolution.normalized,
                frameRate: frameRate,
                dynamicRange: dynamicRange,
                audioLayout: audioLayout,
                hdrHEVCEncoderMode: hdrHEVCEncoderMode
            ),
            items: items
        )
    }

    private func buildSelectedExportProfile(
        resolution: ResolutionPolicy,
        frameRate: FrameRatePolicy,
        dynamicRange: DynamicRange,
        audioLayout: AudioLayout,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode
    ) -> ExportProfile {
        ExportProfile(
            container: selectedContainer,
            videoCodec: selectedVideoCodec,
            audioCodec: .aac,
            frameRate: frameRate,
            resolution: resolution.normalized,
            dynamicRange: dynamicRange,
            hdrFFmpegBinaryMode: selectedHDRBinaryMode,
            hdrHEVCEncoderMode: hdrHEVCEncoderMode,
            audioLayout: audioLayout,
            bitrateMode: selectedBitrateMode
        )
    }

    private func prepareRenderSession(
        style: StyleProfile,
        monthYear: MonthYear,
        requiresSmartFrameRateInspection: Bool,
        requiresSmartAudioInspection: Bool
    ) async throws -> PreparedRenderSession {
        switch sourceMode {
        case .folder:
            guard let selectedFolderURL else {
                throw ViewModelError.missingFolder
            }

            let request = RenderRequest(
                source: .folder(path: selectedFolderURL, recursive: recursiveScan),
                monthYear: nil,
                ordering: .captureDateAscendingStable,
                style: style,
                export: Self.defaultExportProfile,
                output: OutputTarget(directory: outputDirectoryURL, baseFilename: outputFilename)
            )
            let preparation = try await coordinator.prepareFolderRender(request: request)
            try Task.checkCancellation()
            return PreparedRenderSession(
                source: request.source,
                monthYear: request.monthYear,
                style: style,
                preparation: preparation,
                usesPhotoMaterializer: false
            )

        case .photos:
            let status = photoDiscovery.authorizationStatus()
            if status != .authorized && status != .limited {
                let newStatus = await photoDiscovery.requestAuthorization()
                if newStatus != .authorized && newStatus != .limited {
                    throw PhotoKitDiscoveryError.unauthorized(newStatus)
                }
            }

            switch selectedPhotosFilterMode {
            case .monthYear:
                let source: MediaSource = .photosLibrary(scope: .entireLibrary(monthYear: monthYear))
                let discovered = try await photoDiscovery.discover(monthYear: monthYear)
                try Task.checkCancellation()
                let inspection = try await inspectPhotoVideosForSmartPoliciesIfNeeded(
                    discovered,
                    requiresSmartFrameRateInspection: requiresSmartFrameRateInspection,
                    requiresSmartAudioInspection: requiresSmartAudioInspection
                )
                let seedRequest = RenderRequest(
                    source: source,
                    monthYear: monthYear,
                    ordering: .captureDateAscendingStable,
                    style: style,
                    export: Self.defaultExportProfile,
                    output: OutputTarget(directory: outputDirectoryURL, baseFilename: outputFilename)
                )
                let preparation = coordinator.prepareFromItems(
                    inspection.items,
                    request: seedRequest,
                    additionalWarnings: inspection.warnings
                )
                return PreparedRenderSession(
                    source: source,
                    monthYear: monthYear,
                    style: style,
                    preparation: preparation,
                    usesPhotoMaterializer: true
                )

            case .album:
                var selectedAlbumID = selectedPhotoAlbumID.trimmingCharacters(in: .whitespacesAndNewlines)
                if selectedAlbumID.isEmpty {
                    let discoveredAlbums = try await photoDiscovery.discoverAlbums()
                    photoAlbums = discoveredAlbums
                    if let firstAlbum = discoveredAlbums.first {
                        selectedPhotoAlbumID = firstAlbum.localIdentifier
                        selectedAlbumID = firstAlbum.localIdentifier
                        photoAlbumsStatusMessage = ""
                    }
                }

                guard !selectedAlbumID.isEmpty else {
                    throw ViewModelError.missingAlbumSelection
                }

                let selectedAlbumTitle = photoAlbums.first(where: { $0.localIdentifier == selectedAlbumID })?.title
                let source: MediaSource = .photosLibrary(
                    scope: .album(localIdentifier: selectedAlbumID, title: selectedAlbumTitle))
                let discovered = try await photoDiscovery.discover(albumLocalIdentifier: selectedAlbumID)
                try Task.checkCancellation()
                let inspection = try await inspectPhotoVideosForSmartPoliciesIfNeeded(
                    discovered,
                    requiresSmartFrameRateInspection: requiresSmartFrameRateInspection,
                    requiresSmartAudioInspection: requiresSmartAudioInspection
                )
                let seedRequest = RenderRequest(
                    source: source,
                    monthYear: nil,
                    ordering: .captureDateAscendingStable,
                    style: style,
                    export: Self.defaultExportProfile,
                    output: OutputTarget(directory: outputDirectoryURL, baseFilename: outputFilename)
                )
                let preparation = coordinator.prepareFromItems(
                    inspection.items,
                    request: seedRequest,
                    additionalWarnings: inspection.warnings
                )
                return PreparedRenderSession(
                    source: source,
                    monthYear: nil,
                    style: style,
                    preparation: preparation,
                    usesPhotoMaterializer: true
                )
            }
        }
    }

    private func makeRenderRequest(
        preparedSession: PreparedRenderSession,
        exportProfile: ExportProfile,
        outputBaseFilename: String,
        plexTVMetadata: PlexTVMetadata
    ) -> RenderRequest {
        let chapters = exportProfile.container == .mp4
            ? MP4ChapterResolver.resolve(
                timeline: preparedSession.preparation.timeline,
                requestedTransitionDurationSeconds: preparedSession.style.crossfadeDurationSeconds
            )
            : []
        return RenderRequest(
            source: preparedSession.source,
            monthYear: preparedSession.monthYear,
            ordering: .captureDateAscendingStable,
            style: preparedSession.style,
            export: exportProfile,
            output: OutputTarget(directory: outputDirectoryURL, baseFilename: outputBaseFilename),
            plexTVMetadata: plexTVMetadata,
            chapters: chapters
        )
    }

    private func renderSingleRequest(
        preparedSession: PreparedRenderSession,
        request: RenderRequest,
        progressMapper: @escaping @Sendable (Double) -> Double
    ) async throws -> RenderResult {
        renderStatusDetail = nil
        updateRenderingStatusMessage()
        return try await coordinator.render(
            preparation: preparedSession.preparation,
            request: request,
            photoMaterializer: preparedSession.usesPhotoMaterializer ? photoMaterializer : nil,
            writeDiagnosticsLog: writeDiagnosticsLog,
            progressHandler: { [weak self] reportedProgress in
                self?.applyReportedRenderProgress(progressMapper(reportedProgress))
            },
            statusHandler: { [weak self] status in
                self?.applyReportedRenderStatus(status)
            }
        )
    }

    private func recordSuccessfulRender(
        _ renderResult: RenderResult,
        request: RenderRequest,
        preparation: RenderPreparation,
        completionSummarySnapshot: SingleRenderSummarySnapshot? = nil
    ) {
        let outputURL = renderResult.outputURL
        let report = runReportService.makeReport(
            request: request,
            preparation: preparation,
            outputURL: outputURL,
            diagnosticsLogURL: renderResult.diagnosticsLogURL,
            renderBackendSummary: renderResult.backendSummary
        )
        let reportURL = outputURL.deletingPathExtension().appendingPathExtension("json")
        try? runReportService.write(report, to: reportURL)

        lastOutputPath = outputURL.path
        lastDiagnosticsPath = renderResult.diagnosticsLogURL?.path ?? ""
        lastBackendSummary = renderResult.backendSummary ?? ""
        if let completionSummarySnapshot {
            lastSingleRenderCompletionSummary = makeRenderCompletionSummary(
                outputPath: outputURL.path,
                requestedProfile: completionSummarySnapshot.requestedProfile,
                actualProfile: request.export,
                renderResult: renderResult
            )
        }
    }

    private func makeRenderCompletionSummary(
        outputPath: String,
        requestedProfile: ExportProfile,
        actualProfile: ExportProfile,
        renderResult: RenderResult
    ) -> RenderCompletionSummary {
        var rows = [
            makeRenderCompletionSummaryRow(
                title: "Container",
                selectedLabel: containerLabel(for: requestedProfile.container),
                actualLabel: containerLabel(for: actualProfile.container)
            ),
            makeRenderCompletionSummaryRow(
                title: "Codec",
                selectedLabel: videoCodecLabel(for: requestedProfile.videoCodec),
                actualLabel: videoCodecLabel(for: actualProfile.videoCodec)
            ),
        ]

        if actualProfile.dynamicRange == .hdr, actualProfile.videoCodec == .hevc {
            rows.append(
                makeRenderCompletionSummaryRow(
                    title: "HDR HEVC Encoder",
                    selectedLabel: hdrHEVCEncoderModeLabel(for: requestedProfile.hdrHEVCEncoderMode),
                    actualLabel: resolvedHDRHEVCEncoderLabel(
                        renderResult: renderResult,
                        fallbackMode: actualProfile.hdrHEVCEncoderMode
                    )
                )
            )
        }

        rows.append(
            contentsOf: [
                makeRenderCompletionSummaryRow(
                    title: "Audio",
                    selectedLabel: requestedProfile.audioLayout.displayLabel,
                    actualLabel: actualProfile.audioLayout.displayLabel
                ),
                makeRenderCompletionSummaryRow(
                    title: "Bitrate",
                    selectedLabel: bitrateModeLabel(for: requestedProfile.bitrateMode),
                    actualLabel: bitrateModeLabel(for: actualProfile.bitrateMode)
                ),
                makeRenderCompletionSummaryRow(
                    title: "Resolution",
                    selectedLabel: resolutionPolicyLabel(for: requestedProfile.resolution),
                    actualLabel: resolvedResolutionLabel(renderResult: renderResult, fallbackPolicy: actualProfile.resolution)
                ),
                makeRenderCompletionSummaryRow(
                    title: "Frame Rate",
                    selectedLabel: frameRatePolicyLabel(for: requestedProfile.frameRate),
                    actualLabel: resolvedFrameRateLabel(renderResult: renderResult, fallbackPolicy: actualProfile.frameRate)
                ),
                makeRenderCompletionSummaryRow(
                    title: "Range",
                    selectedLabel: dynamicRangeLabel(for: requestedProfile.dynamicRange),
                    actualLabel: dynamicRangeLabel(for: actualProfile.dynamicRange)
                ),
                makeRenderCompletionSummaryRow(
                    title: "Engine",
                    selectedLabel: hdrBinaryModeLabel(for: requestedProfile.hdrFFmpegBinaryMode),
                    actualLabel: resolvedEngineLabel(
                        selectedMode: actualProfile.hdrFFmpegBinaryMode,
                        backendInfo: renderResult.backendInfo
                    )
                )
            ]
        )

        return RenderCompletionSummary(outputPath: outputPath, rows: rows)
    }

    private func makeRenderCompletionSummaryRow(
        title: String,
        selectedLabel: String,
        actualLabel: String
    ) -> RenderCompletionSummary.Row {
        RenderCompletionSummary.Row(
            title: title,
            selectedLabel: selectedLabel,
            actualLabel: actualLabel
        )
    }

    private func containerLabel(for container: ContainerFormat) -> String {
        container.rawValue.uppercased()
    }

    private func videoCodecLabel(for codec: VideoCodec) -> String {
        switch codec {
        case .hevc:
            return "HEVC"
        case .h264:
            return "H.264"
        }
    }

    private func bitrateModeLabel(for bitrateMode: BitrateMode) -> String {
        switch bitrateMode {
        case .balanced:
            return "Balanced"
        case .qualityFirst:
            return "Quality First"
        case .sizeFirst:
            return "Size First"
        }
    }

    private func resolutionPolicyLabel(for resolutionPolicy: ResolutionPolicy) -> String {
        switch resolutionPolicy.normalized {
        case .fixed720p:
            return "720p"
        case .fixed1080p:
            return "1080p"
        case .fixed4K:
            return "4K"
        case .smart, .matchSourceMax:
            return "Smart"
        }
    }

    private func frameRatePolicyLabel(for frameRatePolicy: FrameRatePolicy) -> String {
        switch frameRatePolicy {
        case .fps30:
            return "30 fps"
        case .fps60:
            return "60 fps"
        case .smart:
            return "Smart"
        }
    }

    private func dynamicRangeLabel(for dynamicRange: DynamicRange) -> String {
        dynamicRange.rawValue.uppercased()
    }

    private func hdrBinaryModeLabel(for hdrBinaryMode: HDRFFmpegBinaryMode) -> String {
        switch hdrBinaryMode {
        case .autoSystemThenBundled:
            return "Auto"
        case .systemOnly:
            return "System Only"
        case .bundledOnly:
            return "Bundled Only"
        }
    }

    private func hdrHEVCEncoderModeLabel(for hdrHEVCEncoderMode: HDRHEVCEncoderMode) -> String {
        hdrHEVCEncoderMode.displayLabel
    }

    private func resolvedResolutionLabel(
        renderResult: RenderResult,
        fallbackPolicy: ResolutionPolicy
    ) -> String {
        if let resolvedVideoInfo = renderResult.resolvedVideoInfo {
            return resolutionLabel(width: resolvedVideoInfo.width, height: resolvedVideoInfo.height)
        }
        return resolutionPolicyLabel(for: fallbackPolicy)
    }

    private func resolutionLabel(width: Int, height: Int) -> String {
        switch (width, height) {
        case (1280, 720):
            return "720p"
        case (1920, 1080):
            return "1080p"
        case (3840, 2160):
            return "4K"
        default:
            return "\(width)x\(height)"
        }
    }

    private func resolvedFrameRateLabel(
        renderResult: RenderResult,
        fallbackPolicy: FrameRatePolicy
    ) -> String {
        if let resolvedVideoInfo = renderResult.resolvedVideoInfo {
            return "\(resolvedVideoInfo.frameRate) fps"
        }
        return frameRatePolicyLabel(for: fallbackPolicy)
    }

    private func resolvedHDRHEVCEncoderLabel(
        renderResult: RenderResult,
        fallbackMode: HDRHEVCEncoderMode
    ) -> String {
        if let backendEncoder = renderResult.backendInfo?.encoder {
            return hdrHEVCEncoderActualLabel(for: backendEncoder)
        }
        return hdrHEVCEncoderModeLabel(for: fallbackMode)
    }

    private func hdrHEVCEncoderActualLabel(for backendEncoder: String) -> String {
        switch backendEncoder {
        case "libx265":
            return "libx265"
        case "hevcVideoToolbox":
            return "VideoToolbox"
        default:
            let lowered = backendEncoder.lowercased()
            if lowered.contains("videotoolbox") {
                return "VideoToolbox"
            }
            return backendEncoder
        }
    }

    private func resolvedEngineLabel(
        selectedMode: HDRFFmpegBinaryMode,
        backendInfo: RenderBackendInfo?
    ) -> String {
        switch selectedMode {
        case .autoSystemThenBundled:
            return backendInfo?.binarySource?.displayLabel ?? hdrBinaryModeLabel(for: selectedMode)
        case .systemOnly, .bundledOnly:
            return hdrBinaryModeLabel(for: selectedMode)
        }
    }

    private func formatErrorForDisplay(_ error: Error) -> String {
        if error is CancellationError {
            return "Render cancelled"
        }

        let nsError = error as NSError
        var parts: [String] = []

        if let renderError = error as? RenderError, let description = renderError.errorDescription {
            parts.append(description)
        } else {
            parts.append("The operation could not be completed.")
        }

        parts.append("Domain: \(nsError.domain) Code: \(nsError.code)")

        if !nsError.localizedDescription.isEmpty,
           nsError.localizedDescription != "The operation could not be completed." {
            parts.append(nsError.localizedDescription)
        }

        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            parts.append("Reason: \(reason)")
        }

        if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
            parts.append("Suggestion: \(suggestion)")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("Underlying: \(underlying.domain) (\(underlying.code)) \(underlying.localizedDescription)")
        }

        return parts.joined(separator: "\n")
    }

    private func inspectPhotoVideosForSmartPoliciesIfNeeded(
        _ items: [MediaItem],
        requiresSmartFrameRateInspection: Bool,
        requiresSmartAudioInspection: Bool
    ) async throws -> SmartMediaInspectionResult {
        guard requiresSmartFrameRateInspection || requiresSmartAudioInspection else {
            return SmartMediaInspectionResult(items: items, warnings: [])
        }

        return try await photoMaterializer.prepareItemsForSmartMedia(
            items,
            inspectFrameRate: requiresSmartFrameRateInspection,
            inspectAudioChannels: requiresSmartAudioInspection,
            progressHandler: { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    self.progress = max(self.progress, 0.03 + min(max(fraction, 0), 1) * 0.05)
                }
            },
            statusHandler: { [weak self] status in
                Task { @MainActor in
                    self?.statusMessage = status
                }
            }
        )
    }

    private func resolvedOpeningTitle(for monthYear: MonthYear) -> String {
        let trimmed = openingTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return monthYear.displayLabel
    }

    private func automaticOpeningTitleCaption(for monthYear: MonthYear) -> String? {
        let source: MediaSource?
        let resolverMonthYear: MonthYear?

        switch sourceMode {
        case .folder:
            if let selectedFolderURL {
                source = .folder(path: selectedFolderURL, recursive: recursiveScan)
            } else {
                source = nil
            }
            resolverMonthYear = nil
        case .photos:
            switch selectedPhotosFilterMode {
            case .monthYear:
                source = .photosLibrary(scope: .entireLibrary(monthYear: monthYear))
                resolverMonthYear = monthYear
            case .album:
                let selectedAlbumTitle = photoAlbums.first(where: { $0.localIdentifier == selectedPhotoAlbumID })?.title
                let trimmedAlbumID = selectedPhotoAlbumID.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedAlbumID.isEmpty {
                    source = nil
                } else {
                    source = .photosLibrary(scope: .album(localIdentifier: trimmedAlbumID, title: selectedAlbumTitle))
                }
                resolverMonthYear = nil
            }
        }

        return OpeningTitleCardContextResolver.resolveAutomaticContextLine(
            title: resolvedOpeningTitle(for: monthYear),
            source: source,
            monthYear: resolverMonthYear,
            dateSpanText: nil
        )
    }

    private func applyReportedRenderProgress(_ reportedProgress: Double) {
        let clamped = min(max(reportedProgress, 0), 1)
        progress = max(progress, clamped)
        updateRenderingStatusMessage()
    }

    private func applyReportedRenderStatus(_ status: String) {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        renderStatusDetail = trimmed
        updateRenderingStatusMessage()
    }

    private func updateRenderingStatusMessage() {
        let percent = Int((progress * 100).rounded())
        if let renderStatusDetail, !renderStatusDetail.isEmpty {
            statusMessage = "\(renderStatusDetail)\nOverall progress: \(percent)%"
            return
        }

        statusMessage = "Rendering... \(percent)%"
    }

    private func handleRenderSettingChange(enforceHDRConstraints: Bool = false) {
        guard !isRestoringPersistedSettings else {
            return
        }
        if enforceHDRConstraints {
            enforceHDRSelectionConstraints()
        }
        persistRenderSettings()
    }

    private func handleOpeningTitleCaptionModeChange(previousValue: OpeningTitleCaptionMode) {
        if !isRestoringPersistedSettings,
           previousValue != .custom,
           openingTitleCaptionMode == .custom,
           openingTitleCaptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let monthYear = MonthYear(month: selectedMonth, year: selectedYear)
            openingTitleCaptionText = automaticOpeningTitleCaption(for: monthYear) ?? ""
        }
        handleRenderSettingChange()
    }

    private func refreshPhotoAlbumsIfNeeded() {
        guard sourceMode == .photos, selectedPhotosFilterMode == .album else {
            return
        }
        guard !isLoadingPhotoAlbums else {
            return
        }
        guard photoAlbums.isEmpty else {
            return
        }

        Task {
            await loadPhotoAlbums(requestAuthorizationIfNeeded: false)
        }
    }

    private func loadPhotoAlbums(requestAuthorizationIfNeeded: Bool) async {
        guard !isLoadingPhotoAlbums else {
            return
        }

        isLoadingPhotoAlbums = true
        defer { isLoadingPhotoAlbums = false }

        var status = photoDiscovery.authorizationStatus()
        if status != .authorized && status != .limited {
            if requestAuthorizationIfNeeded {
                status = await photoDiscovery.requestAuthorization()
            }
        }

        guard status == .authorized || status == .limited else {
            photoAlbums = []
            selectedPhotoAlbumID = ""
            photoAlbumsStatusMessage = "Allow Photos access to load albums."
            return
        }

        do {
            let discoveredAlbums = try await photoDiscovery.discoverAlbums()
            photoAlbums = discoveredAlbums
            if discoveredAlbums.isEmpty {
                selectedPhotoAlbumID = ""
                photoAlbumsStatusMessage = "No photo/video albums were found."
                return
            }

            if !discoveredAlbums.contains(where: { $0.localIdentifier == selectedPhotoAlbumID }) {
                selectedPhotoAlbumID = discoveredAlbums[0].localIdentifier
            }
            photoAlbumsStatusMessage = ""
        } catch {
            photoAlbums = []
            selectedPhotoAlbumID = ""
            photoAlbumsStatusMessage = error.localizedDescription
        }
    }

    private func enforceHDRSelectionConstraints() {
        guard selectedDynamicRange == .hdr else {
            return
        }
        guard !isApplyingExportConstraints else {
            return
        }

        isApplyingExportConstraints = true
        defer { isApplyingExportConstraints = false }

        if selectedVideoCodec != .hevc {
            selectedVideoCodec = .hevc
        }
    }

    private func applyPersistedRenderSettings() {
        guard let settings = loadPersistedRenderSettings() else {
            return
        }

        isRestoringPersistedSettings = true
        plexShowTitle = settings.plexShowTitle ?? Self.defaultPlexShowTitle
        includeOpeningTitle = settings.includeOpeningTitle
        openingTitleText = settings.openingTitleText
        titleDurationSeconds = min(max(settings.titleDurationSeconds ?? 2.5, 1), 10)
        openingTitleCaptionMode = settings.openingTitleCaptionMode ?? .automatic
        openingTitleCaptionText = settings.openingTitleCaptionText ?? ""
        crossfadeDurationSeconds = min(max(settings.crossfadeDurationSeconds, 0), 2)
        stillImageDurationSeconds = min(max(settings.stillImageDurationSeconds, 1), 10)
        showCaptureDateOverlay = settings.showCaptureDateOverlay ?? true
        selectedPhotosFilterMode = settings.selectedPhotosFilterMode ?? .monthYear
        selectedPhotoAlbumID = settings.selectedPhotoAlbumID ?? ""
        selectedContainer = settings.selectedContainer
        selectedVideoCodec = settings.selectedVideoCodec
        selectedFrameRatePolicy = settings.selectedFrameRatePolicy ?? .smart
        selectedResolutionPolicy = settings.selectedResolutionPolicy.normalized
        selectedDynamicRange = settings.selectedDynamicRange
        selectedHDRBinaryMode = settings.selectedHDRBinaryMode ?? .autoSystemThenBundled
        selectedHDRHEVCEncoderMode = settings.selectedHDRHEVCEncoderMode ?? .automatic
        selectedAudioLayout = settings.selectedAudioLayout
        selectedBitrateMode = settings.selectedBitrateMode
        writeDiagnosticsLog = settings.writeDiagnosticsLog ?? true
        plexDescriptionText = settings.plexDescriptionText ?? ""
        isPlexDescriptionAutoManaged = settings.isPlexDescriptionAutoManaged ?? true
        isRestoringPersistedSettings = false
        enforceHDRSelectionConstraints()
        resetManualMonthYearOverride()
        persistRenderSettings()
        refreshPhotoAlbumsIfNeeded()
        synchronizeAutoManagedPlexDescriptionIfNeeded()
    }

    private func loadPersistedRenderSettings() -> PersistedRenderSettings? {
        guard let data = preferencesStore.data(forKey: Self.renderSettingsDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedRenderSettings.self, from: data)
    }

    private func persistRenderSettings() {
        let settings = PersistedRenderSettings(
            plexShowTitle: plexShowTitle,
            includeOpeningTitle: includeOpeningTitle,
            openingTitleText: openingTitleText,
            titleDurationSeconds: titleDurationSeconds,
            openingTitleCaptionMode: openingTitleCaptionMode,
            openingTitleCaptionText: openingTitleCaptionText,
            crossfadeDurationSeconds: crossfadeDurationSeconds,
            stillImageDurationSeconds: stillImageDurationSeconds,
            showCaptureDateOverlay: showCaptureDateOverlay,
            selectedPhotosFilterMode: selectedPhotosFilterMode,
            selectedPhotoAlbumID: selectedPhotoAlbumID,
            selectedContainer: selectedContainer,
            selectedVideoCodec: selectedVideoCodec,
            selectedFrameRatePolicy: selectedFrameRatePolicy,
            selectedResolutionPolicy: selectedResolutionPolicy.normalized,
            selectedDynamicRange: selectedDynamicRange,
            selectedHDRBinaryMode: selectedHDRBinaryMode,
            selectedHDRHEVCEncoderMode: selectedHDRHEVCEncoderMode,
            selectedAudioLayout: selectedAudioLayout,
            selectedBitrateMode: selectedBitrateMode,
            writeDiagnosticsLog: writeDiagnosticsLog,
            plexDescriptionText: plexDescriptionText,
            isPlexDescriptionAutoManaged: isPlexDescriptionAutoManaged
        )

        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        preferencesStore.set(data, forKey: Self.renderSettingsDefaultsKey)
    }

    private struct PersistedRenderSettings: Codable {
        let plexShowTitle: String?
        let includeOpeningTitle: Bool
        let openingTitleText: String
        let titleDurationSeconds: Double?
        let openingTitleCaptionMode: OpeningTitleCaptionMode?
        let openingTitleCaptionText: String?
        let crossfadeDurationSeconds: Double
        let stillImageDurationSeconds: Double
        let showCaptureDateOverlay: Bool?
        let selectedPhotosFilterMode: PhotosFilterMode?
        let selectedPhotoAlbumID: String?
        let selectedContainer: ContainerFormat
        let selectedVideoCodec: VideoCodec
        let selectedFrameRatePolicy: FrameRatePolicy?
        let selectedResolutionPolicy: ResolutionPolicy
        let selectedDynamicRange: DynamicRange
        let selectedHDRBinaryMode: HDRFFmpegBinaryMode?
        let selectedHDRHEVCEncoderMode: HDRHEVCEncoderMode?
        let selectedAudioLayout: AudioLayout
        let selectedBitrateMode: BitrateMode
        let writeDiagnosticsLog: Bool?
        let plexDescriptionText: String?
        let isPlexDescriptionAutoManaged: Bool?
    }
}
