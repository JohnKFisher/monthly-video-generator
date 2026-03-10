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
        statusHandler: RenderStatusHandler,
        systemFFmpegFallbackHandler: SystemFFmpegFallbackHandler?
    ) async throws -> RenderResult
    func cancelCurrentRender()
}

extension RenderCoordinator: RenderCoordinating {}

@MainActor
final class MainWindowViewModel: ObservableObject {
    enum SourceMode: String, CaseIterable, Identifiable, Sendable {
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

    enum PhotosFilterMode: String, CaseIterable, Identifiable, Codable, Sendable {
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

    struct SystemFFmpegFallbackConfirmation: Identifiable {
        let id = UUID()
        let reason: String

        var alertMessage: String {
            "\(reason)\n\nUse system FFmpeg for this render? Your saved settings will not change."
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

    private struct QueueRunContext {
        let currentJobNumber: Int
        let totalJobCount: Int
    }

    private struct QueueCompletionSummary: Equatable {
        let completedJobCount: Int
        let totalJobCount: Int
        let lastOutputPath: String

        var alertMessage: String {
            let noun = totalJobCount == 1 ? "job" : "jobs"
            var lines = ["Completed \(completedJobCount) of \(totalJobCount) queued \(noun)."]
            if !lastOutputPath.isEmpty {
                lines.append("")
                lines.append(lastOutputPath)
            }
            return lines.joined(separator: "\n")
        }
    }

    struct QueuedRenderSnapshot: Equatable, Sendable {
        let sourceMode: SourceMode
        let selectedFolderURL: URL?
        let recursiveScan: Bool
        let selectedMonth: Int
        let selectedYear: Int
        let selectedPhotosFilterMode: PhotosFilterMode
        let selectedPhotoAlbumID: String
        let selectedPhotoAlbumTitle: String?
        let outputDirectoryURL: URL
        let plexShowTitle: String
        let outputFilename: String
        let isOutputNameAutoManaged: Bool
        let plexDescriptionText: String
        let isPlexDescriptionAutoManaged: Bool
        let showsManualMonthYearOverride: Bool
        let manualMonthYearOverrideMonth: Int
        let manualMonthYearOverrideYear: Int
        let includeOpeningTitle: Bool
        let openingTitleText: String
        let isOpeningTitleAutoManaged: Bool
        let titleDurationSeconds: Double
        let openingTitleCaptionMode: OpeningTitleCaptionMode
        let openingTitleCaptionText: String
        let crossfadeDurationSeconds: Double
        let stillImageDurationSeconds: Double
        let showCaptureDateOverlay: Bool
        let selectedContainer: ContainerFormat
        let selectedVideoCodec: VideoCodec
        let selectedFrameRatePolicy: FrameRatePolicy
        let selectedResolutionPolicy: ResolutionPolicy
        let selectedDynamicRange: DynamicRange
        let selectedHDRBinaryMode: HDRFFmpegBinaryMode
        let selectedHDRHEVCEncoderMode: HDRHEVCEncoderMode
        let selectedAudioLayout: AudioLayout
        let selectedBitrateMode: BitrateMode
        let writeDiagnosticsLog: Bool
    }

    enum QueuedRenderJobState: String, Equatable, Sendable {
        case queued
        case running
        case completed
        case failed

        var displayLabel: String {
            switch self {
            case .queued:
                return "Queued"
            case .running:
                return "Running"
            case .completed:
                return "Completed"
            case .failed:
                return "Failed"
            }
        }
    }

    struct QueuedRenderJob: Identifiable, Equatable, Sendable {
        let id: UUID
        let snapshot: QueuedRenderSnapshot
        let sourceSummary: String
        let outputNamePreview: String
        var state: QueuedRenderJobState
        var lastResultMessage: String
    }

    @Published var sourceMode: SourceMode = .photos {
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
        didSet { handleOpeningTitleEditedIfNeeded() }
    }
    @Published var titleDurationSeconds: Double = MainWindowViewModel.defaultTitleDurationSeconds {
        didSet { handleRenderSettingChange() }
    }
    @Published var openingTitleCaptionMode: OpeningTitleCaptionMode = .custom {
        didSet { handleRenderSettingChange() }
    }
    @Published var openingTitleCaptionText: String = MainWindowViewModel.defaultOpeningTitleCaptionText {
        didSet { handleRenderSettingChange() }
    }
    @Published var crossfadeDurationSeconds: Double = MainWindowViewModel.defaultCrossfadeDurationSeconds {
        didSet { handleRenderSettingChange() }
    }
    @Published var stillImageDurationSeconds: Double = MainWindowViewModel.defaultStillImageDurationSeconds {
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
    @Published var writeDiagnosticsLog: Bool = false {
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
    @Published private(set) var queuedRenderJobs: [QueuedRenderJob] = []
    @Published private(set) var isQueueRunning: Bool = false
    @Published private(set) var renderCompleteAlertTitle: String = "Render Complete"
    @Published var showRenderCompleteAlert: Bool = false
    @Published var pendingSystemFFmpegFallbackConfirmation: SystemFFmpegFallbackConfirmation?

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
    private let calendar: Calendar
    private let nowProvider: () -> Date
    private var renderTask: Task<Void, Never>?
    private var renderStatusDetail: String?
    private var queueRunContext: QueueRunContext?
    private var systemFFmpegFallbackContinuation: CheckedContinuation<Bool, Never>?
    private var hasApprovedSystemFFmpegFallbackForCurrentRun = false
    private var isApplyingExportConstraints = false
    private var isRestoringPersistedSettings = false
    private var isOpeningTitleAutoManaged = true
    private var isApplyingOpeningTitleProgrammatically = false
    private var isApplyingOutputFilenameProgrammatically = false
    private var isApplyingPlexDescriptionProgrammatically = false
    private var isCancellingRender = false
    private var lastQueueCompletionSummary: QueueCompletionSummary?

    private static let defaultExportProfile = ExportProfileManager().defaultProfile()
    private static let defaultPlexShowTitle = "Family Videos"
    private static let defaultOpeningTitleCaptionText = "Fisher Family Videos"
    private static let defaultTitleDurationSeconds = 7.5
    private static let defaultCrossfadeDurationSeconds = 1.0
    private static let defaultStillImageDurationSeconds = 5.0
    private static let renderSettingsDefaultsKey = "MainWindowViewModel.renderSettings.v1"

    init(
        coordinator: RenderCoordinating = RenderCoordinator(),
        photoDiscovery: PhotoKitMediaDiscoveryService = PhotoKitMediaDiscoveryService(),
        photoMaterializer: PhotoKitAssetMaterializer = PhotoKitAssetMaterializer(),
        exportProfileManager: ExportProfileManager = ExportProfileManager(),
        runReportService: RunReportService = RunReportService(),
        preferencesStore: UserDefaults = .standard,
        filenameGenerator: PlexTVFilenameGenerator = PlexTVFilenameGenerator(),
        exportProvenanceIdentity: OutputProvenanceAppIdentity = AppMetadata.exportProvenanceIdentity,
        calendar: Calendar = .current,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.photoDiscovery = photoDiscovery
        self.photoMaterializer = photoMaterializer
        self.exportProfileManager = exportProfileManager
        self.runReportService = runReportService
        self.preferencesStore = preferencesStore
        self.filenameGenerator = filenameGenerator
        self.exportProvenanceIdentity = exportProvenanceIdentity
        self.calendar = calendar
        self.nowProvider = nowProvider
        appVersionBuildLabel = AppMetadata.versionBuildLabel

        let launchMonthYear = Self.mostRecentlyCompletedMonthYear(
            calendar: calendar,
            now: nowProvider()
        )
        let currentYear = calendar.component(.year, from: nowProvider())
        selectedMonth = launchMonthYear.month
        selectedYear = launchMonthYear.year
        manualMonthYearOverrideMonth = launchMonthYear.month
        manualMonthYearOverrideYear = launchMonthYear.year
        openingTitleText = launchMonthYear.displayLabel
        years = Array((currentYear - 15)...(currentYear + 2)).reversed()

        let moviesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Monthly Video Generator", isDirectory: true)
        outputDirectoryURL = moviesDirectory

        applyPersistedRenderSettings()
        applyLaunchDefaults()
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
            return "VideoToolbox is faster for HDR HEVC on supported Macs, but may trade some compression efficiency and fails explicitly if unavailable for the available FFmpeg toolchain."
        }
    }

    var ffmpegEngineDescription: String {
        "Bundled FFmpeg is used by default. If bundled FFmpeg cannot satisfy the selected export, the app will ask before falling back to system FFmpeg."
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

    var canStartQueue: Bool {
        !isRendering && nextQueuedRenderStartIndex() != nil
    }

    var canClearQueue: Bool {
        !isRendering && !queuedRenderJobs.isEmpty
    }

    var queueStatusDescription: String {
        if queuedRenderJobs.isEmpty {
            return "Snapshot the current form into queued jobs, then start the queue when you're ready."
        }

        let completedCount = queuedRenderJobs.filter { $0.state == .completed }.count
        let failedCount = queuedRenderJobs.filter { $0.state == .failed }.count
        let queuedCount = queuedRenderJobs.filter { $0.state == .queued }.count

        if isQueueRunning {
            return "Queue running. Completed \(completedCount) of \(queuedRenderJobs.count) job(s)."
        }
        if failedCount > 0 {
            return "Queue paused for review. Failed \(failedCount) job(s), queued \(queuedCount) job(s)."
        }
        return "Queued \(queuedCount) job(s). Completed \(completedCount) job(s)."
    }

    var renderCompleteAlertMessage: String {
        if let lastQueueCompletionSummary {
            return lastQueueCompletionSummary.alertMessage
        }
        if let lastSingleRenderCompletionSummary {
            return lastSingleRenderCompletionSummary.alertMessage
        }
        if lastOutputPath.isEmpty {
            return "The slideshow was exported successfully."
        }
        return lastOutputPath
    }

    func monthLabel(for month: Int) -> String {
        let clampedMonth = min(max(month, 1), 12)
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let monthName = formatter.monthSymbols[clampedMonth - 1]
        return "\(clampedMonth) - \(monthName)"
    }

    private static func mostRecentlyCompletedMonthYear(calendar: Calendar, now: Date) -> MonthYear {
        guard let startOfCurrentMonth = calendar.dateInterval(of: .month, for: now)?.start,
              let lastDayOfPreviousMonth = calendar.date(byAdding: .day, value: -1, to: startOfCurrentMonth) else {
            let fallbackMonth = calendar.component(.month, from: now)
            let fallbackYear = calendar.component(.year, from: now)
            return MonthYear(month: fallbackMonth, year: fallbackYear)
        }

        return MonthYear(
            month: calendar.component(.month, from: lastDayOfPreviousMonth),
            year: calendar.component(.year, from: lastDayOfPreviousMonth)
        )
    }

    private static func normalizedOpeningTitleCaptionText(
        mode: OpeningTitleCaptionMode?,
        text: String?
    ) -> String {
        switch mode {
        case .custom:
            if let text {
                return text
            }
            return defaultOpeningTitleCaptionText
        case .automatic, .none:
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                return defaultOpeningTitleCaptionText
            }
            return text ?? defaultOpeningTitleCaptionText
        }
    }

    private static func inferredOpeningTitleAutoManaged(
        savedText: String?,
        calendar: Calendar
    ) -> Bool {
        let trimmed = savedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return true
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        guard let parsedDate = formatter.date(from: trimmed) else {
            return false
        }
        return formatter.string(from: parsedDate) == trimmed
    }

    private func applyLaunchDefaults() {
        let launchMonthYear = Self.mostRecentlyCompletedMonthYear(
            calendar: calendar,
            now: nowProvider()
        )

        isRestoringPersistedSettings = true
        sourceMode = .photos
        selectedPhotosFilterMode = .monthYear
        selectedMonth = launchMonthYear.month
        selectedYear = launchMonthYear.year
        resetManualMonthYearOverride()
        isRestoringPersistedSettings = false

        synchronizePlexAutoManagedFieldsIfNeeded()
        persistRenderSettings()
    }

    func resetExportSettingsToPlexDefaults() {
        let profile = exportProfileManager.defaultProfile()
        isRestoringPersistedSettings = true
        plexShowTitle = Self.defaultPlexShowTitle
        isOpeningTitleAutoManaged = true
        applyOpeningTitleText(defaultOpeningTitleText(), autoManaged: true)
        openingTitleCaptionMode = .custom
        openingTitleCaptionText = Self.defaultOpeningTitleCaptionText
        titleDurationSeconds = Self.defaultTitleDurationSeconds
        crossfadeDurationSeconds = Self.defaultCrossfadeDurationSeconds
        stillImageDurationSeconds = Self.defaultStillImageDurationSeconds
        selectedContainer = profile.container
        selectedVideoCodec = profile.videoCodec
        selectedFrameRatePolicy = profile.frameRate
        selectedResolutionPolicy = profile.resolution.normalized
        selectedDynamicRange = profile.dynamicRange
        selectedHDRBinaryMode = profile.hdrFFmpegBinaryMode
        selectedHDRHEVCEncoderMode = profile.hdrHEVCEncoderMode
        selectedAudioLayout = profile.audioLayout
        selectedBitrateMode = profile.bitrateMode
        writeDiagnosticsLog = false
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

        let snapshot = makeCurrentRenderSnapshot()
        let completionSummarySnapshot = makeSingleRenderSummarySnapshot(snapshot: snapshot)
        renderTask = Task {
            await performSingleRender(
                snapshot: snapshot,
                completionSummarySnapshot: completionSummarySnapshot
            )
            await MainActor.run {
                self.renderTask = nil
            }
        }
    }

    func addCurrentSettingsToQueue() {
        let snapshot = makeCurrentRenderSnapshot()

        do {
            try validateSnapshotForQueue(snapshot)
        } catch {
            statusMessage = formatErrorForDisplay(error)
            return
        }

        queuedRenderJobs.append(
            QueuedRenderJob(
                id: UUID(),
                snapshot: snapshot,
                sourceSummary: queueSourceSummary(for: snapshot),
                outputNamePreview: queueOutputNamePreview(for: snapshot),
                state: .queued,
                lastResultMessage: ""
            )
        )
    }

    func startQueue() {
        guard !isRendering, renderTask == nil, nextQueuedRenderStartIndex() != nil else { return }

        renderTask = Task {
            await performQueuedRenders()
            await MainActor.run {
                self.renderTask = nil
            }
        }
    }

    func removeQueuedRenderJob(id: QueuedRenderJob.ID) {
        guard let index = queuedRenderJobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard queuedRenderJobs[index].state != .running else {
            return
        }
        queuedRenderJobs.remove(at: index)
    }

    func clearQueuedRenderJobs() {
        guard !isRendering else {
            return
        }
        queuedRenderJobs.removeAll()
    }

    func cancelRender() {
        isCancellingRender = true
        renderTask?.cancel()
        resolveSystemFFmpegFallbackConfirmation(approved: false)
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

    func openConfiguredOutputFolder() {
        #if canImport(AppKit)
        NSWorkspace.shared.open(outputDirectoryURL)
        #endif
    }

    func approveSystemFFmpegFallback() {
        resolveSystemFFmpegFallbackConfirmation(approved: true)
    }

    func cancelSystemFFmpegFallback() {
        resolveSystemFFmpegFallbackConfirmation(approved: false)
    }

    private func performSingleRender(
        snapshot: QueuedRenderSnapshot,
        completionSummarySnapshot: SingleRenderSummarySnapshot
    ) async {
        beginRenderRun(status: "Preparing media...", initialProgress: 0.01)

        do {
            try await executeRenderSnapshot(
                snapshot,
                completionSummarySnapshot: completionSummarySnapshot,
                progressMapper: { $0 },
                syncLiveState: true
            )
            finishSuccessfulSingleRun(status: "Render complete")
        } catch {
            finishFailedRun(error)
        }
    }

    private func performQueuedRenders() async {
        let totalJobCount = queuedRenderJobs.count
        let completedCount = queuedRenderJobs.filter { $0.state == .completed }.count
        let initialProgress = totalJobCount == 0 ? 0.01 : max(0.01, Double(completedCount) / Double(totalJobCount))

        beginRenderRun(status: "Preparing queued render...", initialProgress: initialProgress)
        isQueueRunning = true

        while let index = nextQueuedRenderStartIndex() {
            let job = queuedRenderJobs[index]
            let completedBeforeJob = queuedRenderJobs.filter { $0.state == .completed }.count
            let totalCount = max(queuedRenderJobs.count, 1)

            queueRunContext = QueueRunContext(
                currentJobNumber: completedBeforeJob + 1,
                totalJobCount: totalCount
            )
            queuedRenderJobs[index].state = .running
            queuedRenderJobs[index].lastResultMessage = ""
            renderStatusDetail = "Preparing media..."
            updateRenderingStatusMessage()

            do {
                let renderResult = try await executeRenderSnapshot(
                    job.snapshot,
                    completionSummarySnapshot: nil,
                    progressMapper: { reportedProgress in
                        (Double(completedBeforeJob) + min(max(reportedProgress, 0), 1)) / Double(totalCount)
                    },
                    syncLiveState: false
                )
                queuedRenderJobs[index].state = .completed
                queuedRenderJobs[index].lastResultMessage = renderResult.outputURL.lastPathComponent
            } catch {
                if isCancellingRender || Task.isCancelled || error is CancellationError {
                    queuedRenderJobs[index].state = .queued
                    queuedRenderJobs[index].lastResultMessage = ""
                    finishCancelledQueueRun()
                    return
                }

                let message = formatErrorForDisplay(error)
                queuedRenderJobs[index].state = .failed
                queuedRenderJobs[index].lastResultMessage = compactQueueMessage(from: message)
                finishPausedQueueRun(failedJob: queuedRenderJobs[index], errorMessage: message)
                return
            }
        }

        finishSuccessfulQueueRun()
    }

    @discardableResult
    private func executeRenderSnapshot(
        _ snapshot: QueuedRenderSnapshot,
        completionSummarySnapshot: SingleRenderSummarySnapshot?,
        progressMapper: @escaping @Sendable (Double) -> Double,
        syncLiveState: Bool
    ) async throws -> RenderResult {
        let monthYear = MonthYear(month: snapshot.selectedMonth, year: snapshot.selectedYear)
        let style = buildStyle(for: monthYear, snapshot: snapshot)
        let preparedSession = try await prepareRenderSession(
            snapshot: snapshot,
            style: style,
            monthYear: monthYear,
            requiresSmartFrameRateInspection: snapshot.selectedFrameRatePolicy == .smart,
            requiresSmartAudioInspection: snapshot.selectedAudioLayout == .smart,
            progressMapper: progressMapper,
            syncLiveState: syncLiveState
        )
        let exportResolution = resolveExportProfile(
            snapshot: snapshot,
            resolution: snapshot.selectedResolutionPolicy.normalized,
            frameRate: snapshot.selectedFrameRatePolicy,
            dynamicRange: snapshot.selectedDynamicRange,
            audioLayout: snapshot.selectedAudioLayout,
            hdrHEVCEncoderMode: snapshot.selectedHDRHEVCEncoderMode,
            items: preparedSession.preparation.items
        )

        warnings = preparedSession.preparation.warnings + exportResolution.warnings.map(\.message)
        applyReportedRenderProgress(progressMapper(0.08))
        renderStatusDetail = nil
        updateRenderingStatusMessage()

        let plexRenderDetails = try resolvePlexRenderDetails(
            preparedSession: preparedSession,
            fallbackMonthYear: monthYear,
            exportProfile: exportResolution.effectiveProfile,
            outputBaseFilenameOverride: nil,
            snapshot: snapshot,
            syncLiveState: syncLiveState
        )

        let request = makeRenderRequest(
            preparedSession: preparedSession,
            exportProfile: exportResolution.effectiveProfile,
            outputBaseFilename: plexRenderDetails.outputBaseFilename,
            outputDirectory: snapshot.outputDirectoryURL,
            plexTVMetadata: plexRenderDetails.metadata
        )
        let renderResult = try await renderSingleRequest(
            preparedSession: preparedSession,
            request: request,
            writeDiagnosticsLog: snapshot.writeDiagnosticsLog,
            progressMapper: progressMapper
        )

        recordSuccessfulRender(
            renderResult,
            request: request,
            preparation: preparedSession.preparation,
            completionSummarySnapshot: completionSummarySnapshot
        )
        return renderResult
    }

    private func makeCurrentRenderSnapshot() -> QueuedRenderSnapshot {
        QueuedRenderSnapshot(
            sourceMode: sourceMode,
            selectedFolderURL: selectedFolderURL,
            recursiveScan: recursiveScan,
            selectedMonth: selectedMonth,
            selectedYear: selectedYear,
            selectedPhotosFilterMode: selectedPhotosFilterMode,
            selectedPhotoAlbumID: selectedPhotoAlbumID,
            selectedPhotoAlbumTitle: photoAlbums.first(where: { $0.localIdentifier == selectedPhotoAlbumID })?.title,
            outputDirectoryURL: outputDirectoryURL,
            plexShowTitle: plexShowTitle,
            outputFilename: outputFilename,
            isOutputNameAutoManaged: isOutputNameAutoManaged,
            plexDescriptionText: plexDescriptionText,
            isPlexDescriptionAutoManaged: isPlexDescriptionAutoManaged,
            showsManualMonthYearOverride: showsManualMonthYearOverride,
            manualMonthYearOverrideMonth: manualMonthYearOverrideMonth,
            manualMonthYearOverrideYear: manualMonthYearOverrideYear,
            includeOpeningTitle: includeOpeningTitle,
            openingTitleText: openingTitleText,
            isOpeningTitleAutoManaged: isOpeningTitleAutoManaged,
            titleDurationSeconds: titleDurationSeconds,
            openingTitleCaptionMode: openingTitleCaptionMode,
            openingTitleCaptionText: openingTitleCaptionText,
            crossfadeDurationSeconds: crossfadeDurationSeconds,
            stillImageDurationSeconds: stillImageDurationSeconds,
            showCaptureDateOverlay: showCaptureDateOverlay,
            selectedContainer: selectedContainer,
            selectedVideoCodec: selectedVideoCodec,
            selectedFrameRatePolicy: selectedFrameRatePolicy,
            selectedResolutionPolicy: selectedResolutionPolicy.normalized,
            selectedDynamicRange: selectedDynamicRange,
            selectedHDRBinaryMode: selectedHDRBinaryMode,
            selectedHDRHEVCEncoderMode: selectedHDRHEVCEncoderMode,
            selectedAudioLayout: selectedAudioLayout,
            selectedBitrateMode: selectedBitrateMode,
            writeDiagnosticsLog: writeDiagnosticsLog
        )
    }

    private func validateSnapshotForQueue(_ snapshot: QueuedRenderSnapshot) throws {
        switch snapshot.sourceMode {
        case .folder:
            guard snapshot.selectedFolderURL != nil else {
                throw ViewModelError.missingFolder
            }
        case .photos:
            guard snapshot.selectedPhotosFilterMode == .monthYear ||
                    !snapshot.selectedPhotoAlbumID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ViewModelError.missingAlbumSelection
            }
        }
    }

    private func queueSourceSummary(for snapshot: QueuedRenderSnapshot) -> String {
        switch snapshot.sourceMode {
        case .folder:
            let folderLabel = snapshot.selectedFolderURL?.lastPathComponent ?? "No folder selected"
            return snapshot.recursiveScan ? "Folder: \(folderLabel) (recursive)" : "Folder: \(folderLabel)"
        case .photos:
            switch snapshot.selectedPhotosFilterMode {
            case .monthYear:
                return "Photos: \(previewMonthYear(for: snapshot).displayLabel)"
            case .album:
                let albumTitle = snapshot.selectedPhotoAlbumTitle ?? "Selected album"
                return "Photos album: \(albumTitle)"
            }
        }
    }

    private func queueOutputNamePreview(for snapshot: QueuedRenderSnapshot) -> String {
        let trimmed = snapshot.outputFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return generatedOutputName(for: snapshot)
    }

    private func nextQueuedRenderStartIndex() -> Int? {
        if let failedIndex = queuedRenderJobs.firstIndex(where: { $0.state == .failed }) {
            return failedIndex
        }
        return queuedRenderJobs.firstIndex(where: { $0.state == .queued })
    }

    private func buildStyle(for monthYear: MonthYear, snapshot: QueuedRenderSnapshot) -> StyleProfile {
        let openingTitle = snapshot.includeOpeningTitle ? resolvedOpeningTitle(for: monthYear, snapshot: snapshot) : nil
        return StyleProfile(
            openingTitle: openingTitle,
            titleDurationSeconds: snapshot.includeOpeningTitle ? snapshot.titleDurationSeconds : 0,
            crossfadeDurationSeconds: snapshot.crossfadeDurationSeconds,
            stillImageDurationSeconds: snapshot.stillImageDurationSeconds,
            showCaptureDateOverlay: snapshot.showCaptureDateOverlay,
            openingTitleCaptionMode: snapshot.openingTitleCaptionMode,
            openingTitleCaptionText: snapshot.openingTitleCaptionText
        )
    }

    private func previewMonthYear() -> MonthYear {
        previewMonthYear(for: makeCurrentRenderSnapshot())
    }

    private func previewMonthYear(for snapshot: QueuedRenderSnapshot) -> MonthYear {
        if snapshot.showsManualMonthYearOverride {
            return MonthYear(
                month: snapshot.manualMonthYearOverrideMonth,
                year: snapshot.manualMonthYearOverrideYear
            )
        }
        return MonthYear(month: snapshot.selectedMonth, year: snapshot.selectedYear)
    }

    private func resolvedPlexShowTitle() -> String {
        resolvedPlexShowTitle(for: makeCurrentRenderSnapshot())
    }

    private func resolvedPlexShowTitle(for snapshot: QueuedRenderSnapshot) -> String {
        let trimmed = snapshot.plexShowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultPlexShowTitle : trimmed
    }

    private func resolvePlexRenderDetails(
        preparedSession: PreparedRenderSession,
        fallbackMonthYear: MonthYear,
        exportProfile: ExportProfile,
        outputBaseFilenameOverride: String?,
        snapshot: QueuedRenderSnapshot,
        syncLiveState: Bool
    ) throws -> ResolvedPlexRenderDetails {
        let monthYearContext = try resolvePlexMonthYearContext(
            preparedSession: preparedSession,
            fallbackMonthYear: fallbackMonthYear,
            snapshot: snapshot,
            syncLiveState: syncLiveState
        )
        let autoDescription = PlexTVMetadataResolver.defaultDescription(for: monthYearContext.monthYear)
        if syncLiveState, snapshot.isPlexDescriptionAutoManaged {
            applyPlexDescription(autoDescription, autoManaged: true)
        }

        let provenance = EmbeddedOutputProvenanceResolver.resolve(
            exportProfile: exportProfile,
            timeline: preparedSession.preparation.timeline,
            appIdentity: exportProvenanceIdentity
        )
        let metadata = PlexTVMetadataResolver.resolveMetadata(
            showTitle: resolvedPlexShowTitle(for: snapshot),
            monthYear: monthYearContext.monthYear,
            descriptionText: snapshot.isPlexDescriptionAutoManaged ? autoDescription : snapshot.plexDescriptionText,
            creationTime: monthYearContext.latestCaptureDate,
            provenance: provenance
        )
        let autoOutputBaseFilename = metadata.identity.filenameBase
        if syncLiveState, snapshot.isOutputNameAutoManaged {
            applyOutputFilename(autoOutputBaseFilename, autoManaged: true)
        }

        return ResolvedPlexRenderDetails(
            monthYearContext: monthYearContext,
            metadata: metadata,
            outputBaseFilename: outputBaseFilenameOverride ??
                (snapshot.isOutputNameAutoManaged ? autoOutputBaseFilename : snapshot.outputFilename)
        )
    }

    private func resolvePlexMonthYearContext(
        preparedSession: PreparedRenderSession,
        fallbackMonthYear: MonthYear,
        snapshot: QueuedRenderSnapshot,
        syncLiveState: Bool
    ) throws -> ResolvedMonthYearContext {
        let latestCaptureDate = latestCaptureDate(from: preparedSession.preparation.items)
        if snapshot.sourceMode == .photos, snapshot.selectedPhotosFilterMode == .monthYear {
            return ResolvedMonthYearContext(monthYear: fallbackMonthYear, latestCaptureDate: latestCaptureDate)
        }
        if snapshot.showsManualMonthYearOverride {
            return ResolvedMonthYearContext(
                monthYear: MonthYear(
                    month: snapshot.manualMonthYearOverrideMonth,
                    year: snapshot.manualMonthYearOverrideYear
                ),
                latestCaptureDate: latestCaptureDate
            )
        }

        do {
            return try PlexTVMetadataResolver.resolveMonthYear(from: preparedSession.preparation.items)
        } catch {
            if syncLiveState {
                revealManualMonthYearOverride(
                    using: preparedSession.preparation.items,
                    fallbackMonthYear: fallbackMonthYear,
                    error: error
                )
            }
            let message = (error as? LocalizedError)?.errorDescription ??
                "Unable to derive a single month/year for Plex TV naming."
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
        manualMonthYearOverrideMessage = (error as? LocalizedError)?.errorDescription ??
            "Unable to derive a single month/year automatically."
        synchronizePlexAutoManagedFieldsIfNeeded()
    }

    private func latestCaptureDate(from items: [MediaItem]) -> Date? {
        items.compactMap(\.captureDate).max()
    }

    private func makeSingleRenderSummarySnapshot(snapshot: QueuedRenderSnapshot) -> SingleRenderSummarySnapshot {
        SingleRenderSummarySnapshot(
            requestedProfile: buildSelectedExportProfile(
                snapshot: snapshot,
                resolution: snapshot.selectedResolutionPolicy.normalized,
                frameRate: snapshot.selectedFrameRatePolicy,
                dynamicRange: snapshot.selectedDynamicRange,
                audioLayout: snapshot.selectedAudioLayout,
                hdrHEVCEncoderMode: snapshot.selectedHDRHEVCEncoderMode
            )
        )
    }

    private func generatedOutputName() -> String {
        generatedOutputName(for: makeCurrentRenderSnapshot())
    }

    private func generatedOutputName(for snapshot: QueuedRenderSnapshot) -> String {
        filenameGenerator.makeOutputName(
            showTitle: resolvedPlexShowTitle(for: snapshot),
            monthYear: previewMonthYear(for: snapshot)
        )
    }

    private func defaultOpeningTitleText() -> String {
        defaultOpeningTitleText(for: makeCurrentRenderSnapshot())
    }

    private func defaultOpeningTitleText(for snapshot: QueuedRenderSnapshot) -> String {
        previewMonthYear(for: snapshot).displayLabel
    }

    private func defaultPlexDescription() -> String {
        defaultPlexDescription(for: makeCurrentRenderSnapshot())
    }

    private func defaultPlexDescription(for snapshot: QueuedRenderSnapshot) -> String {
        PlexTVMetadataResolver.defaultDescription(for: previewMonthYear(for: snapshot))
    }

    private func applyOpeningTitleText(_ value: String, autoManaged: Bool) {
        isApplyingOpeningTitleProgrammatically = true
        openingTitleText = value
        isOpeningTitleAutoManaged = autoManaged
        isApplyingOpeningTitleProgrammatically = false
    }

    private func handleOpeningTitleEditedIfNeeded() {
        guard !isApplyingOpeningTitleProgrammatically else {
            return
        }
        let trimmed = openingTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        isOpeningTitleAutoManaged = !trimmed.isEmpty && trimmed == defaultOpeningTitleText()
        handleRenderSettingChange()
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
        if isOpeningTitleAutoManaged {
            applyOpeningTitleText(defaultOpeningTitleText(), autoManaged: true)
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

    private func beginRenderRun(status: String, initialProgress: Double) {
        isRendering = true
        isCancellingRender = false
        isQueueRunning = false
        queueRunContext = nil
        progress = initialProgress
        warnings = []
        renderStatusDetail = status
        updateRenderingStatusMessage()
        lastOutputPath = ""
        lastDiagnosticsPath = ""
        lastBackendSummary = ""
        lastSingleRenderCompletionSummary = nil
        lastQueueCompletionSummary = nil
        renderCompleteAlertTitle = "Render Complete"
        showRenderCompleteAlert = false
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
    }

    private func finishSuccessfulSingleRun(status: String) {
        renderStatusDetail = nil
        queueRunContext = nil
        progress = 1.0
        statusMessage = status
        if !lastDiagnosticsPath.isEmpty {
            statusMessage += "\nDiagnostics: \(lastDiagnosticsPath)"
        }
        if !lastBackendSummary.isEmpty {
            statusMessage += "\nBackend: \(lastBackendSummary)"
        }
        renderCompleteAlertTitle = "Render Complete"
        showRenderCompleteAlert = true
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isQueueRunning = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishFailedRun(_ error: Error) {
        renderStatusDetail = nil
        queueRunContext = nil
        progress = 0
        statusMessage = formatErrorForDisplay(error)
        lastSingleRenderCompletionSummary = nil
        lastQueueCompletionSummary = nil
        renderCompleteAlertTitle = "Render Complete"
        showRenderCompleteAlert = false
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isQueueRunning = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishSuccessfulQueueRun() {
        renderStatusDetail = nil
        queueRunContext = nil
        progress = 1.0
        let completedCount = queuedRenderJobs.filter { $0.state == .completed }.count
        let totalCount = queuedRenderJobs.count
        let summary = QueueCompletionSummary(
            completedJobCount: completedCount,
            totalJobCount: totalCount,
            lastOutputPath: lastOutputPath
        )
        lastQueueCompletionSummary = summary
        lastSingleRenderCompletionSummary = nil
        renderCompleteAlertTitle = "Queue Complete"
        statusMessage = "Queue complete"
        if !lastDiagnosticsPath.isEmpty {
            statusMessage += "\nDiagnostics: \(lastDiagnosticsPath)"
        }
        if !lastBackendSummary.isEmpty {
            statusMessage += "\nBackend: \(lastBackendSummary)"
        }
        showRenderCompleteAlert = true
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isQueueRunning = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishPausedQueueRun(failedJob: QueuedRenderJob, errorMessage: String) {
        renderStatusDetail = nil
        queueRunContext = nil
        progress = 0
        statusMessage = "Queue paused after failure\n\(failedJob.sourceSummary)\n\(errorMessage)"
        lastSingleRenderCompletionSummary = nil
        lastQueueCompletionSummary = nil
        renderCompleteAlertTitle = "Queue Complete"
        showRenderCompleteAlert = false
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isQueueRunning = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishCancelledQueueRun() {
        renderStatusDetail = nil
        queueRunContext = nil
        progress = 0
        statusMessage = "Render cancelled"
        lastSingleRenderCompletionSummary = nil
        lastQueueCompletionSummary = nil
        renderCompleteAlertTitle = "Queue Complete"
        showRenderCompleteAlert = false
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isQueueRunning = false
        isCancellingRender = false
        isRendering = false
    }

    private func resolveExportProfile(
        snapshot: QueuedRenderSnapshot,
        resolution: ResolutionPolicy,
        frameRate: FrameRatePolicy,
        dynamicRange: DynamicRange,
        audioLayout: AudioLayout,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode,
        items: [MediaItem]
    ) -> ExportProfileResolution {
        exportProfileManager.resolveProfile(
            for: buildSelectedExportProfile(
                snapshot: snapshot,
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
        snapshot: QueuedRenderSnapshot,
        resolution: ResolutionPolicy,
        frameRate: FrameRatePolicy,
        dynamicRange: DynamicRange,
        audioLayout: AudioLayout,
        hdrHEVCEncoderMode: HDRHEVCEncoderMode
    ) -> ExportProfile {
        ExportProfile(
            container: snapshot.selectedContainer,
            videoCodec: snapshot.selectedVideoCodec,
            audioCodec: .aac,
            frameRate: frameRate,
            resolution: resolution.normalized,
            dynamicRange: dynamicRange,
            hdrFFmpegBinaryMode: snapshot.selectedHDRBinaryMode,
            hdrHEVCEncoderMode: hdrHEVCEncoderMode,
            audioLayout: audioLayout,
            bitrateMode: snapshot.selectedBitrateMode
        )
    }

    private func prepareRenderSession(
        snapshot: QueuedRenderSnapshot,
        style: StyleProfile,
        monthYear: MonthYear,
        requiresSmartFrameRateInspection: Bool,
        requiresSmartAudioInspection: Bool,
        progressMapper: @escaping @Sendable (Double) -> Double,
        syncLiveState: Bool
    ) async throws -> PreparedRenderSession {
        switch snapshot.sourceMode {
        case .folder:
            guard let selectedFolderURL = snapshot.selectedFolderURL else {
                throw ViewModelError.missingFolder
            }

            let request = RenderRequest(
                source: .folder(path: selectedFolderURL, recursive: snapshot.recursiveScan),
                monthYear: nil,
                ordering: .captureDateAscendingStable,
                style: style,
                export: Self.defaultExportProfile,
                output: OutputTarget(directory: snapshot.outputDirectoryURL, baseFilename: snapshot.outputFilename)
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

            switch snapshot.selectedPhotosFilterMode {
            case .monthYear:
                let source: MediaSource = .photosLibrary(scope: .entireLibrary(monthYear: monthYear))
                let discovered = try await photoDiscovery.discover(monthYear: monthYear)
                try Task.checkCancellation()
                let inspection = try await inspectPhotoVideosForSmartPoliciesIfNeeded(
                    discovered,
                    requiresSmartFrameRateInspection: requiresSmartFrameRateInspection,
                    requiresSmartAudioInspection: requiresSmartAudioInspection,
                    progressMapper: progressMapper
                )
                let seedRequest = RenderRequest(
                    source: source,
                    monthYear: monthYear,
                    ordering: .captureDateAscendingStable,
                    style: style,
                    export: Self.defaultExportProfile,
                    output: OutputTarget(directory: snapshot.outputDirectoryURL, baseFilename: snapshot.outputFilename)
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
                var selectedAlbumID = snapshot.selectedPhotoAlbumID.trimmingCharacters(in: .whitespacesAndNewlines)
                if selectedAlbumID.isEmpty {
                    if syncLiveState {
                        let discoveredAlbums = try await photoDiscovery.discoverAlbums()
                        photoAlbums = discoveredAlbums
                        if let firstAlbum = discoveredAlbums.first {
                            selectedPhotoAlbumID = firstAlbum.localIdentifier
                            selectedAlbumID = firstAlbum.localIdentifier
                            photoAlbumsStatusMessage = ""
                        }
                    }
                }

                guard !selectedAlbumID.isEmpty else {
                    throw ViewModelError.missingAlbumSelection
                }

                let selectedAlbumTitle = snapshot.selectedPhotoAlbumTitle ??
                    photoAlbums.first(where: { $0.localIdentifier == selectedAlbumID })?.title
                let source: MediaSource = .photosLibrary(
                    scope: .album(localIdentifier: selectedAlbumID, title: selectedAlbumTitle))
                let discovered = try await photoDiscovery.discover(albumLocalIdentifier: selectedAlbumID)
                try Task.checkCancellation()
                let inspection = try await inspectPhotoVideosForSmartPoliciesIfNeeded(
                    discovered,
                    requiresSmartFrameRateInspection: requiresSmartFrameRateInspection,
                    requiresSmartAudioInspection: requiresSmartAudioInspection,
                    progressMapper: progressMapper
                )
                let seedRequest = RenderRequest(
                    source: source,
                    monthYear: nil,
                    ordering: .captureDateAscendingStable,
                    style: style,
                    export: Self.defaultExportProfile,
                    output: OutputTarget(directory: snapshot.outputDirectoryURL, baseFilename: snapshot.outputFilename)
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
        outputDirectory: URL,
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
            output: OutputTarget(directory: outputDirectory, baseFilename: outputBaseFilename),
            plexTVMetadata: plexTVMetadata,
            chapters: chapters
        )
    }

    private func renderSingleRequest(
        preparedSession: PreparedRenderSession,
        request: RenderRequest,
        writeDiagnosticsLog: Bool,
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
            },
            systemFFmpegFallbackHandler: { [weak self] request in
                guard let self else { return false }
                return await self.confirmSystemFFmpegFallbackIfNeeded(request)
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
        case .bundledPreferred:
            return "Bundled Preferred"
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
        case .bundledPreferred:
            switch backendInfo?.binarySource {
            case .system:
                return "System Fallback"
            case .bundled, nil:
                return hdrBinaryModeLabel(for: selectedMode)
            }
        case .autoSystemThenBundled:
            return backendInfo?.binarySource?.displayLabel ?? hdrBinaryModeLabel(for: selectedMode)
        case .systemOnly, .bundledOnly:
            return hdrBinaryModeLabel(for: selectedMode)
        }
    }

    private func confirmSystemFFmpegFallbackIfNeeded(_ request: SystemFFmpegFallbackRequest) async -> Bool {
        if hasApprovedSystemFFmpegFallbackForCurrentRun {
            return true
        }

        pendingSystemFFmpegFallbackConfirmation = SystemFFmpegFallbackConfirmation(reason: request.reason)
        return await withCheckedContinuation { continuation in
            systemFFmpegFallbackContinuation = continuation
        }
    }

    private func resolveSystemFFmpegFallbackConfirmation(approved: Bool) {
        pendingSystemFFmpegFallbackConfirmation = nil
        if approved {
            hasApprovedSystemFFmpegFallbackForCurrentRun = true
        }

        guard let continuation = systemFFmpegFallbackContinuation else {
            if !approved {
                hasApprovedSystemFFmpegFallbackForCurrentRun = false
            }
            return
        }

        systemFFmpegFallbackContinuation = nil
        if !approved {
            hasApprovedSystemFFmpegFallbackForCurrentRun = false
        }
        continuation.resume(returning: approved)
    }

    func formatErrorForDisplay(_ error: Error) -> String {
        if isCancellingRender || error is CancellationError {
            return "Render cancelled"
        }

        let nsError = error as NSError
        var parts: [String] = []
        var seenParts: Set<String> = []

        func appendUnique(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard seenParts.insert(trimmed).inserted else { return }
            parts.append(trimmed)
        }

        if let renderError = error as? RenderError, let description = renderError.errorDescription {
            appendUnique(description)
        } else {
            appendUnique("The operation could not be completed.")
        }

        appendUnique("Domain: \(nsError.domain) Code: \(nsError.code)")

        if !nsError.localizedDescription.isEmpty,
           nsError.localizedDescription != "The operation could not be completed." {
            appendUnique(nsError.localizedDescription)
        }

        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            appendUnique("Reason: \(reason)")
        }

        if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
            appendUnique("Suggestion: \(suggestion)")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            appendUnique("Underlying: \(underlying.domain) (\(underlying.code)) \(underlying.localizedDescription)")
        }

        return parts.joined(separator: "\n")
    }

    private func inspectPhotoVideosForSmartPoliciesIfNeeded(
        _ items: [MediaItem],
        requiresSmartFrameRateInspection: Bool,
        requiresSmartAudioInspection: Bool,
        progressMapper: @escaping @Sendable (Double) -> Double
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
                    self.applyReportedRenderProgress(
                        progressMapper(0.03 + min(max(fraction, 0), 1) * 0.05)
                    )
                }
            },
            statusHandler: { [weak self] status in
                Task { @MainActor in
                    self?.renderStatusDetail = status
                    self?.updateRenderingStatusMessage()
                }
            }
        )
    }

    private func resolvedOpeningTitle(
        for monthYear: MonthYear,
        snapshot: QueuedRenderSnapshot
    ) -> String {
        let trimmed = snapshot.openingTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return monthYear.displayLabel
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
        let renderMessage: String
        if let renderStatusDetail, !renderStatusDetail.isEmpty {
            renderMessage = "\(renderStatusDetail)\nOverall progress: \(percent)%"
        } else {
            renderMessage = "Rendering... \(percent)%"
        }

        if let queueRunContext {
            statusMessage = "Queue job \(queueRunContext.currentJobNumber) of \(queueRunContext.totalJobCount)\n\(renderMessage)"
            return
        }

        statusMessage = renderMessage
    }

    private func compactQueueMessage(from message: String) -> String {
        message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? message
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
        isOpeningTitleAutoManaged = settings.isOpeningTitleAutoManaged ?? Self.inferredOpeningTitleAutoManaged(
            savedText: settings.openingTitleText,
            calendar: calendar
        )
        applyOpeningTitleText(settings.openingTitleText, autoManaged: isOpeningTitleAutoManaged)
        titleDurationSeconds = min(max(settings.titleDurationSeconds ?? Self.defaultTitleDurationSeconds, 1), 10)
        openingTitleCaptionMode = .custom
        openingTitleCaptionText = Self.normalizedOpeningTitleCaptionText(
            mode: settings.openingTitleCaptionMode,
            text: settings.openingTitleCaptionText
        )
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
        selectedHDRBinaryMode = .bundledPreferred
        selectedHDRHEVCEncoderMode = settings.selectedHDRHEVCEncoderMode ?? .automatic
        selectedAudioLayout = settings.selectedAudioLayout
        selectedBitrateMode = settings.selectedBitrateMode
        writeDiagnosticsLog = settings.writeDiagnosticsLog ?? false
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
            isOpeningTitleAutoManaged: isOpeningTitleAutoManaged,
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
        let isOpeningTitleAutoManaged: Bool?
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
