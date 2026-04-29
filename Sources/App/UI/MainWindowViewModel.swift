import Core
import Combine
import Foundation
import Photos
import PhotosIntegration
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

typealias RenderProgressHandler = (@MainActor @Sendable (Double) -> Void)?
typealias RenderStatusHandler = (@MainActor @Sendable (String) -> Void)?
typealias RenderArtifactSnapshotHandler = RenderArtifactHandler?

protocol PhotoLibraryDiscovering: Sendable {
    func authorizationStatus() -> PHAuthorizationStatus
    func requestAuthorization() async -> PHAuthorizationStatus
    func discover(monthYear: MonthYear, timeZone: TimeZone) async throws -> [MediaItem]
    func discover(albumLocalIdentifier: String) async throws -> [MediaItem]
    func discoverAlbums() async throws -> [PhotoAlbumSummary]
}

extension PhotoKitMediaDiscoveryService: PhotoLibraryDiscovering {}

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
        artifactHandler: RenderArtifactSnapshotHandler,
        systemFFmpegFallbackHandler: SystemFFmpegFallbackHandler?,
        executionOptions: RenderExecutionOptions
    ) async throws -> RenderResult
    func cancelCurrentRender()
    func requestPauseAfterCheckpoint()
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

    struct QueuedRenderJobResultSummary: Equatable, Sendable {
        let elapsedSeconds: TimeInterval?
        let mediaCount: Int
        let outputFileSizeBytes: Int64?
        let outputFilename: String
        let elapsedLabel: String
        let mediaCountLabel: String
        let outputFileSizeLabel: String
        let metricsLine: String
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
        let selectedHDRX265Speed: HDRX265Speed
        let selectedAudioLayout: AudioLayout
        let selectedBitrateMode: BitrateMode
        let writeDiagnosticsLog: Bool
    }

    enum QueuedRenderJobState: String, Equatable, Sendable {
        case queued
        case running
        case paused
        case completed
        case failed

        var displayLabel: String {
            switch self {
            case .queued:
                return "Queued"
            case .running:
                return "Running"
            case .paused:
                return "Paused"
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
        var resultSummary: QueuedRenderJobResultSummary?
    }

    private struct RenderSnapshotExecutionResult {
        let renderResult: RenderResult
        let mediaCount: Int
        let elapsedSeconds: TimeInterval?
        let outputFileSizeBytes: Int64?
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
    @Published var selectedHDRX265Speed: HDRX265Speed = MainWindowViewModel.defaultExportProfile.hdrX265Speed {
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
    @Published private(set) var currentItemProgress: Double = 0
    @Published private(set) var queueProgress: Double = 0
    @Published private(set) var currentItemProgressLabel: String = "0%"
    @Published private(set) var queueProgressLabel: String = "0 of 0"
    @Published var statusMessage: String = "Idle"
    @Published private(set) var statusPhaseLabel: String = "Idle"
    @Published private(set) var statusProgressLabel: String = "0%"
    @Published private(set) var statusElapsedLabel: String = "00:00"
    @Published private(set) var statusQueueLabel: String = "Single render"
    @Published private(set) var statusOutputLabel: String = ""
    @Published private(set) var currentArtifactLabel: String = "No render artifact yet"
    @Published private(set) var currentArtifactPath: String = ""
    @Published private(set) var currentArtifactSizeLabel: String = ""
    @Published private(set) var liveSnapshotStatusMessage: String = "Waiting for the next render."
    @Published private(set) var liveSnapshotImageURL: URL?
    @Published private(set) var liveSnapshotCapturedLabel: String = ""
    @Published private(set) var isPauseRequested: Bool = false
    @Published var warnings: [String] = []
    @Published var lastOutputPath: String = ""
    @Published var lastDiagnosticsPath: String = ""
    @Published var lastBackendSummary: String = ""
    @Published private(set) var lastSingleRenderCompletionSummary: RenderCompletionSummary?
    @Published private(set) var queuedRenderJobs: [QueuedRenderJob] = []
    @Published private(set) var isQueueRunning: Bool = false
    @Published private(set) var isQueuePauseRequested: Bool = false
    @Published private(set) var isPreparingYearQueue: Bool = false
    @Published private(set) var preparingYearQueueTargetYear: Int?
    @Published private(set) var renderCompleteAlertTitle: String = "Render Complete"
    @Published var showRenderCompleteAlert: Bool = false
    @Published var pendingSystemFFmpegFallbackConfirmation: SystemFFmpegFallbackConfirmation?

    let appVersionBuildLabel: String
    let months = Array(1...12)
    let years: [Int]

    private let coordinator: RenderCoordinating
    private let photoDiscovery: any PhotoLibraryDiscovering
    private let photoMaterializer: PhotoKitAssetMaterializer
    private let exportProfileManager: ExportProfileManager
    private let runReportService: RunReportService
    private let preferencesStore: UserDefaults
    private let shellPreferences: AppShellPreferencesStore
    private let folderSelector: any FolderSelecting
    private let workspaceCoordinator: any FileWorkspaceOpening
    private let filenameGenerator: PlexTVFilenameGenerator
    private let exportProvenanceIdentity: OutputProvenanceAppIdentity
    private let liveSnapshotService: LiveRenderSnapshotService
    private let calendar: Calendar
    private let nowProvider: () -> Date
    private var cancellables: Set<AnyCancellable> = []
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
    private var renderStartedAt: Date?
    private var liveSnapshotSessionID = UUID()
    private var liveSnapshotTask: Task<Void, Never>?
    private var lastLiveSnapshotAttemptAt: Date?

    private static let defaultExportProfile = ExportProfileManager().defaultProfile()
    private static let defaultPlexShowTitle = "Family Videos"
    private static let defaultOpeningTitleCaptionText = "Fisher Family Videos"
    private static let defaultTitleDurationSeconds = 10.0
    private static let defaultCrossfadeDurationSeconds = 1.0
    private static let defaultStillImageDurationSeconds = 5.0
    private static let minimumSelectableYear = 2000
    private static let maximumSelectableYear = 2030
    private static let renderSettingsDefaultsKey = "MainWindowViewModel.renderSettings.v1"
    private static let liveSnapshotIntervalSeconds: TimeInterval = 3 * 60

    init(
        coordinator: RenderCoordinating = RenderCoordinator(),
        photoDiscovery: any PhotoLibraryDiscovering = PhotoKitMediaDiscoveryService(),
        photoMaterializer: PhotoKitAssetMaterializer = PhotoKitAssetMaterializer(),
        exportProfileManager: ExportProfileManager = ExportProfileManager(),
        runReportService: RunReportService = RunReportService(),
        preferencesStore: UserDefaults = .standard,
        shellPreferences: AppShellPreferencesStore? = nil,
        folderSelector: any FolderSelecting = OpenPanelFolderSelector(),
        workspaceCoordinator: any FileWorkspaceOpening = AppKitWorkspaceCoordinator(),
        filenameGenerator: PlexTVFilenameGenerator = PlexTVFilenameGenerator(),
        exportProvenanceIdentity: OutputProvenanceAppIdentity = AppMetadata.exportProvenanceIdentity,
        liveSnapshotService: LiveRenderSnapshotService = LiveRenderSnapshotService(),
        calendar: Calendar = .current,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        let resolvedShellPreferences = shellPreferences ?? AppShellPreferencesStore(userDefaults: preferencesStore)

        self.coordinator = coordinator
        self.photoDiscovery = photoDiscovery
        self.photoMaterializer = photoMaterializer
        self.exportProfileManager = exportProfileManager
        self.runReportService = runReportService
        self.preferencesStore = preferencesStore
        self.shellPreferences = resolvedShellPreferences
        self.folderSelector = folderSelector
        self.workspaceCoordinator = workspaceCoordinator
        self.filenameGenerator = filenameGenerator
        self.exportProvenanceIdentity = exportProvenanceIdentity
        self.liveSnapshotService = liveSnapshotService
        self.calendar = calendar
        self.nowProvider = nowProvider
        appVersionBuildLabel = AppMetadata.versionBuildLabel

        let launchMonthYear = Self.mostRecentlyCompletedMonthYear(
            calendar: calendar,
            now: nowProvider()
        )
        selectedMonth = launchMonthYear.month
        selectedYear = launchMonthYear.year
        manualMonthYearOverrideMonth = launchMonthYear.month
        manualMonthYearOverrideYear = launchMonthYear.year
        openingTitleText = launchMonthYear.displayLabel
        years = Array((Self.minimumSelectableYear...Self.maximumSelectableYear)).reversed()

        outputDirectoryURL = resolvedShellPreferences.defaultOutputDirectoryURL

        applyPersistedRenderSettings()
        applyLaunchDefaults()
        useAutoGeneratedOutputName()
        synchronizeAutoManagedPlexDescriptionIfNeeded()
        bindShellPreferences()
    }

    deinit {
        liveSnapshotTask?.cancel()
        let service = liveSnapshotService
        Task {
            await service.removeAllSnapshots()
        }
    }

    func chooseInputFolder() {
        guard canChooseInputFolder else {
            return
        }

        let initialDirectoryURL = selectedFolderURL ?? shellPreferences.lastInputDirectoryURL
        guard let selectedURL = folderSelector.chooseFolder(
            title: "Select Source Folder",
            prompt: "Choose",
            initialDirectoryURL: initialDirectoryURL
        ) else {
            return
        }

        selectedFolderURL = selectedURL
        shellPreferences.rememberInputDirectory(selectedURL)
        resetManualMonthYearOverride()
    }

    func chooseOutputFolder() {
        guard canChooseOutputFolder else {
            return
        }

        let initialDirectoryURL = outputDirectoryURL
        guard let selectedURL = folderSelector.chooseFolder(
            title: "Select Output Folder",
            prompt: "Choose",
            initialDirectoryURL: initialDirectoryURL
        ) else {
            return
        }

        outputDirectoryURL = selectedURL
        shellPreferences.setDefaultOutputDirectory(selectedURL)
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

    var isHDRX265SpeedControlEnabled: Bool {
        selectedDynamicRange == .hdr
    }

    var hdrX265SpeedDescription: String {
        guard selectedDynamicRange == .hdr else {
            return "Applies only to HDR exports that use libx265."
        }

        switch selectedHDRX265Speed {
        case .slow:
            return "Slow uses the most conservative HDR libx265 thread caps (4 pools / 2 frame threads)."
        case .medium:
            return "Medium uses balanced HDR libx265 thread caps (5 pools / 2 frame threads)."
        case .fast:
            return "Fast uses the most aggressive HDR libx265 thread caps (6 pools / 3 frame threads) and is the default for Plex/Infuse HDR exports."
        }
    }

    var hdrX265SpeedCaution: String {
        "Changing HDR libx265 speed can change the encoded HEVC bitstream even when the visible output looks the same."
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
        !isRendering && !isPreparingYearQueue && nextQueuedRenderStartIndex() != nil
    }

    var canStartRender: Bool {
        !isRendering && !isPreparingYearQueue && renderTask == nil
    }

    var canChooseInputFolder: Bool {
        !isRendering && !isPreparingYearQueue
    }

    var canChooseOutputFolder: Bool {
        !isRendering && !isPreparingYearQueue
    }

    var canOpenConfiguredOutputFolder: Bool {
        !outputDirectoryURL.path.isEmpty
    }

    var canRevealLastRenderedOutput: Bool {
        !lastOutputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canResetExportSettings: Bool {
        !isRendering
    }

    var canClearQueue: Bool {
        !isRendering && !isPreparingYearQueue && !queuedRenderJobs.isEmpty
    }

    var canPauseQueueAfterCurrentItem: Bool {
        isQueueRunning && isRendering && !isQueuePauseRequested
    }

    var canAddCurrentSettingsToQueue: Bool {
        !isRendering && !isPreparingYearQueue
    }

    var canAddSelectedYearToQueue: Bool {
        sourceMode == .photos &&
        selectedPhotosFilterMode == .monthYear &&
        !isRendering &&
        !isPreparingYearQueue
    }

    var showsSelectedYearQueueAction: Bool {
        sourceMode == .photos && selectedPhotosFilterMode == .monthYear
    }

    var addCurrentSettingsToQueueLabel: String {
        showsSelectedYearQueueAction ? "Add Selected Month" : "Add Current Settings"
    }

    var selectedYearQueueDescription: String {
        "Scans \(yearQueueLabelYear) and adds one queued job per month that has Photos media. Month-based filenames are generated automatically."
    }

    var yearQueueLabelYear: Int {
        preparingYearQueueTargetYear ?? selectedYear
    }

    var showsQueueProgress: Bool {
        isQueueRunning || queuedRenderJobs.count > 1
    }

    var hasQueuedJobs: Bool {
        !queuedRenderJobs.isEmpty
    }

    var usesFocusedRunLayout: Bool {
        isRendering ||
            isQueueRunning ||
            isQueuePauseRequested ||
            queuedRenderJobs.contains { job in
                switch job.state {
                case .running, .paused, .completed, .failed:
                    return true
                case .queued:
                    return false
                }
            }
    }

    var hasCustomStyleOrExportSettings: Bool {
        includeOpeningTitle != true ||
            !approximatelyEqual(titleDurationSeconds, Self.defaultTitleDurationSeconds) ||
            !approximatelyEqual(crossfadeDurationSeconds, Self.defaultCrossfadeDurationSeconds) ||
            !approximatelyEqual(stillImageDurationSeconds, Self.defaultStillImageDurationSeconds) ||
            showCaptureDateOverlay != true ||
            selectedContainer != Self.defaultExportProfile.container ||
            selectedVideoCodec != Self.defaultExportProfile.videoCodec ||
            selectedFrameRatePolicy != Self.defaultExportProfile.frameRate ||
            selectedResolutionPolicy.normalized != Self.defaultExportProfile.resolution.normalized ||
            selectedDynamicRange != Self.defaultExportProfile.dynamicRange ||
            selectedHDRBinaryMode != Self.defaultExportProfile.hdrFFmpegBinaryMode ||
            selectedHDRHEVCEncoderMode != Self.defaultExportProfile.hdrHEVCEncoderMode ||
            selectedHDRX265Speed != Self.defaultExportProfile.hdrX265Speed ||
            selectedAudioLayout != Self.defaultExportProfile.audioLayout ||
            selectedBitrateMode != Self.defaultExportProfile.bitrateMode ||
            writeDiagnosticsLog
    }

    var settingsSummaryDescription: String {
        let baseline = hasCustomStyleOrExportSettings ? "Custom settings" : "Plex defaults"
        let titleLabel = includeOpeningTitle ? "\(String(format: "%.2fs", titleDurationSeconds)) title" : "no title card"
        let exportLabel = [
            containerLabel(for: selectedContainer),
            videoCodecLabel(for: selectedVideoCodec),
            dynamicRangeLabel(for: selectedDynamicRange),
            resolutionPolicyLabel(for: selectedResolutionPolicy),
            frameRatePolicyLabel(for: selectedFrameRatePolicy),
            selectedAudioLayout.displayLabel
        ].joined(separator: " · ")
        return "\(baseline) · \(titleLabel) · \(exportLabel)"
    }

    var queueStatusDescription: String {
        if queuedRenderJobs.isEmpty {
            return "Snapshot the current form into queued jobs, then start the queue when you're ready."
        }

        let completedCount = queuedRenderJobs.filter { $0.state == .completed }.count
        let failedCount = queuedRenderJobs.filter { $0.state == .failed }.count
        let pausedCount = queuedRenderJobs.filter { $0.state == .paused }.count
        let queuedCount = queuedRenderJobs.filter { $0.state == .queued }.count

        if isQueueRunning {
            if isQueuePauseRequested {
                return "Pausing after this item. Completed \(completedCount) of \(queuedRenderJobs.count) job(s)."
            }
            return "Queue running. Completed \(completedCount) of \(queuedRenderJobs.count) job(s)."
        }
        if pausedCount > 0 {
            return "Queue paused by user. Paused \(pausedCount) job(s), queued \(queuedCount) job(s)."
        }
        if failedCount > 0 {
            return "Queue paused for review. Failed \(failedCount) job(s), queued \(queuedCount) job(s)."
        }
        return "Queued \(queuedCount) job(s). Completed \(completedCount) job(s)."
    }

    var currentRenderSourceSummary: String {
        queueSourceSummary(for: makeCurrentRenderSnapshot())
    }

    var currentRenderOutputNamePreview: String {
        queueOutputNamePreview(for: makeCurrentRenderSnapshot())
    }

    var currentRenderDrawerDescription: String {
        if let queueRunContext {
            return "Queue job \(queueRunContext.currentJobNumber) of \(queueRunContext.totalJobCount)"
        }
        if isRendering {
            return "Single render in progress"
        }
        return "Ready for a single render or queue snapshot."
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

    func containerOptionLabel(for container: ContainerFormat) -> String {
        defaultTaggedLabel(
            containerLabel(for: container),
            isDefault: container == Self.defaultExportProfile.container
        )
    }

    func videoCodecOptionLabel(for codec: VideoCodec) -> String {
        defaultTaggedLabel(
            videoCodecLabel(for: codec),
            isDefault: codec == Self.defaultExportProfile.videoCodec
        )
    }

    func audioLayoutOptionLabel(for audioLayout: AudioLayout) -> String {
        defaultTaggedLabel(
            audioLayout.displayLabel,
            isDefault: audioLayout == Self.defaultExportProfile.audioLayout
        )
    }

    func bitrateModeOptionLabel(for bitrateMode: BitrateMode) -> String {
        defaultTaggedLabel(
            bitrateModeLabel(for: bitrateMode),
            isDefault: bitrateMode == Self.defaultExportProfile.bitrateMode
        )
    }

    func resolutionPolicyOptionLabel(for resolutionPolicy: ResolutionPolicy) -> String {
        defaultTaggedLabel(
            resolutionPolicyLabel(for: resolutionPolicy),
            isDefault: resolutionPolicy.normalized == Self.defaultExportProfile.resolution.normalized
        )
    }

    func frameRatePolicyOptionLabel(for frameRatePolicy: FrameRatePolicy) -> String {
        defaultTaggedLabel(
            frameRatePolicyLabel(for: frameRatePolicy),
            isDefault: frameRatePolicy == Self.defaultExportProfile.frameRate
        )
    }

    func dynamicRangeOptionLabel(for dynamicRange: DynamicRange) -> String {
        defaultTaggedLabel(
            dynamicRangeLabel(for: dynamicRange),
            isDefault: dynamicRange == Self.defaultExportProfile.dynamicRange
        )
    }

    func hdrHEVCEncoderOptionLabel(for hdrHEVCEncoderMode: HDRHEVCEncoderMode) -> String {
        defaultTaggedLabel(
            hdrHEVCEncoderModeLabel(for: hdrHEVCEncoderMode),
            isDefault: hdrHEVCEncoderMode == Self.defaultExportProfile.hdrHEVCEncoderMode
        )
    }

    func hdrX265SpeedOptionLabel(for hdrX265Speed: HDRX265Speed) -> String {
        defaultTaggedLabel(
            hdrX265Speed.displayLabel,
            isDefault: hdrX265Speed == Self.defaultExportProfile.hdrX265Speed
        )
    }

    private func defaultTaggedLabel(_ label: String, isDefault: Bool) -> String {
        isDefault ? "\(label) (Default)" : label
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.0001
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
        selectedHDRX265Speed = profile.hdrX265Speed
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

    func resetStyleAndExportSettingsToPlexDefaults() {
        let profile = exportProfileManager.defaultProfile()
        isRestoringPersistedSettings = true
        includeOpeningTitle = true
        titleDurationSeconds = Self.defaultTitleDurationSeconds
        crossfadeDurationSeconds = Self.defaultCrossfadeDurationSeconds
        stillImageDurationSeconds = Self.defaultStillImageDurationSeconds
        showCaptureDateOverlay = true
        selectedContainer = profile.container
        selectedVideoCodec = profile.videoCodec
        selectedFrameRatePolicy = profile.frameRate
        selectedResolutionPolicy = profile.resolution.normalized
        selectedDynamicRange = profile.dynamicRange
        selectedHDRBinaryMode = profile.hdrFFmpegBinaryMode
        selectedHDRHEVCEncoderMode = profile.hdrHEVCEncoderMode
        selectedHDRX265Speed = profile.hdrX265Speed
        selectedAudioLayout = profile.audioLayout
        selectedBitrateMode = profile.bitrateMode
        writeDiagnosticsLog = false
        isRestoringPersistedSettings = false
        enforceHDRSelectionConstraints()
        synchronizeAutoGeneratedOutputFilenameIfNeeded()
        persistRenderSettings()
        warnings = exportProfileManager.compatibilityWarnings(for: profile).map(\.message)
    }

    func startRender() {
        guard canStartRender else { return }

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

        enqueueRenderSnapshot(snapshot)
    }

    func addSelectedYearToQueue() {
        guard canAddSelectedYearToQueue else { return }

        let baseSnapshot = makeCurrentRenderSnapshot()
        isPreparingYearQueue = true
        preparingYearQueueTargetYear = baseSnapshot.selectedYear
        statusMessage = "Scanning Photos for \(baseSnapshot.selectedYear)..."

        Task {
            await queueSelectedYearRenders(from: baseSnapshot)
        }
    }

    func startQueue() {
        guard !isRendering, !isPreparingYearQueue, renderTask == nil, nextQueuedRenderStartIndex() != nil else { return }

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
        guard !isRendering, !isPreparingYearQueue else {
            return
        }
        queuedRenderJobs.removeAll()
    }

    func cancelRender() {
        isCancellingRender = true
        isPauseRequested = false
        renderTask?.cancel()
        resolveSystemFFmpegFallbackConfirmation(approved: false)
        photoMaterializer.cancelPendingRequests()
        coordinator.cancelCurrentRender()
        statusMessage = "Cancelling render..."
    }

    func pauseQueueAfterCurrentItem() {
        guard canPauseQueueAfterCurrentItem else {
            return
        }
        isQueuePauseRequested = true
        renderStatusDetail = "Pausing after this item..."
        updateRenderingStatusMessage()
    }

    func openRenderedOutputFolder() {
        let outputPath = lastOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryURL: URL
        if outputPath.isEmpty {
            directoryURL = outputDirectoryURL
        } else {
            directoryURL = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        }
        workspaceCoordinator.open(directoryURL)
    }

    func openConfiguredOutputFolder() {
        workspaceCoordinator.open(outputDirectoryURL)
    }

    func revealLastRenderedOutput() {
        let outputPath = lastOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outputPath.isEmpty else {
            openConfiguredOutputFolder()
            return
        }

        workspaceCoordinator.reveal(URL(fileURLWithPath: outputPath))
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
            if case let RenderError.paused(message) = error {
                finishPausedSingleRun(message)
                return
            }
            finishFailedRun(error)
        }
    }

    private func bindShellPreferences() {
        shellPreferences.$defaultOutputDirectoryURL
            .dropFirst()
            .sink { [weak self] url in
                guard let self else {
                    return
                }
                if self.outputDirectoryURL != url {
                    self.outputDirectoryURL = url
                }
            }
            .store(in: &cancellables)
    }

    private func performQueuedRenders() async {
        let totalJobCount = queuedRenderJobs.count
        let completedCount = queuedRenderJobs.filter { $0.state == .completed }.count

        beginRenderRun(status: "Preparing queued render...", initialProgress: 0.01)
        isQueueRunning = true
        isQueuePauseRequested = false
        updateQueueProgress(completedCount: completedCount, totalCount: totalJobCount)

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
            queuedRenderJobs[index].resultSummary = nil
            renderStatusDetail = "Preparing media..."
            setCurrentItemProgress(0.01)
            updateQueueProgress(completedCount: completedBeforeJob, totalCount: totalCount)
            updateRenderingStatusMessage()

            do {
                let renderResult = try await executeRenderSnapshot(
                    job.snapshot,
                    completionSummarySnapshot: nil,
                    progressMapper: { $0 },
                    syncLiveState: false
                )
                queuedRenderJobs[index].state = .completed
                queuedRenderJobs[index].lastResultMessage = ""
                queuedRenderJobs[index].resultSummary = makeQueueResultSummary(from: renderResult)
                updateQueueProgress(completedCount: completedBeforeJob + 1, totalCount: totalCount)
                if isQueuePauseRequested {
                    finishQueuePausedAfterCurrentItem()
                    return
                }
            } catch {
                if isCancellingRender || Task.isCancelled || error is CancellationError {
                    queuedRenderJobs[index].state = .queued
                    queuedRenderJobs[index].lastResultMessage = ""
                    queuedRenderJobs[index].resultSummary = nil
                    finishCancelledQueueRun()
                    return
                }
                if case let RenderError.paused(message) = error {
                    queuedRenderJobs[index].state = .paused
                    queuedRenderJobs[index].lastResultMessage = compactQueueMessage(from: message)
                    queuedRenderJobs[index].resultSummary = nil
                    finishUserPausedQueueRun(pausedJob: queuedRenderJobs[index], message: message)
                    return
                }

                let message = formatErrorForDisplay(error)
                queuedRenderJobs[index].state = .failed
                queuedRenderJobs[index].lastResultMessage = compactQueueMessage(from: message)
                queuedRenderJobs[index].resultSummary = nil
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
    ) async throws -> RenderSnapshotExecutionResult {
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
            hdrX265Speed: snapshot.selectedHDRX265Speed,
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
        let renderStartedAt = nowProvider()
        let renderResult = try await renderSingleRequest(
            preparedSession: preparedSession,
            request: request,
            writeDiagnosticsLog: snapshot.writeDiagnosticsLog,
            progressMapper: progressMapper,
            executionOptions: .default
        )

        recordSuccessfulRender(
            renderResult,
            request: request,
            preparation: preparedSession.preparation,
            writeDiagnosticsLog: snapshot.writeDiagnosticsLog,
            completionSummarySnapshot: completionSummarySnapshot
        )
        return RenderSnapshotExecutionResult(
            renderResult: renderResult,
            mediaCount: preparedSession.preparation.items.count,
            elapsedSeconds: renderResult.executionDetails?.elapsedSeconds ?? nowProvider().timeIntervalSince(renderStartedAt),
            outputFileSizeBytes: renderResult.executionDetails?.outputFileSizeBytes ?? outputFileSizeBytes(at: renderResult.outputURL)
        )
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
            selectedHDRX265Speed: selectedHDRX265Speed,
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

    private func enqueueRenderSnapshot(_ snapshot: QueuedRenderSnapshot) {
        queuedRenderJobs.append(
            QueuedRenderJob(
                id: UUID(),
                snapshot: snapshot,
                sourceSummary: queueSourceSummary(for: snapshot),
                outputNamePreview: queueOutputNamePreview(for: snapshot),
                state: .queued,
                lastResultMessage: "",
                resultSummary: nil
            )
        )
    }

    private func queueSelectedYearRenders(from baseSnapshot: QueuedRenderSnapshot) async {
        defer {
            isPreparingYearQueue = false
            preparingYearQueueTargetYear = nil
        }

        do {
            try await ensurePhotosAuthorizationIfNeeded()

            let targetYear = baseSnapshot.selectedYear
            var addedSnapshots: [QueuedRenderSnapshot] = []

            for month in months {
                let monthYear = MonthYear(month: month, year: targetYear)
                let discovered = try await photoDiscovery.discover(
                    monthYear: monthYear,
                    timeZone: calendar.timeZone
                )
                guard !discovered.isEmpty else {
                    continue
                }

                addedSnapshots.append(
                    makeSelectedYearQueueSnapshot(
                        from: baseSnapshot,
                        monthYear: monthYear
                    )
                )
            }

            guard !addedSnapshots.isEmpty else {
                statusMessage = "No Photos media found for \(targetYear)."
                return
            }

            for snapshot in addedSnapshots {
                enqueueRenderSnapshot(snapshot)
            }

            let skippedCount = months.count - addedSnapshots.count
            statusMessage = "Queued \(addedSnapshots.count) month(s) for \(targetYear). Skipped \(skippedCount) empty month(s)."
        } catch {
            statusMessage = formatErrorForDisplay(error)
        }
    }

    private func nextQueuedRenderStartIndex() -> Int? {
        if let failedIndex = queuedRenderJobs.firstIndex(where: { $0.state == .failed }) {
            return failedIndex
        }
        if let pausedIndex = queuedRenderJobs.firstIndex(where: { $0.state == .paused }) {
            return pausedIndex
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
        let customEpisodeTitleOverride = resolvedCustomPlexEpisodeTitleOverride(
            snapshot: snapshot,
            title: preparedSession.style.openingTitle
        )
        let episodeTitleOverride = customEpisodeTitleOverride ??
            albumEpisodeTitleOverride(for: preparedSession.source)
        let metadata = PlexTVMetadataResolver.resolveMetadata(
            showTitle: resolvedPlexShowTitle(for: snapshot),
            monthYear: monthYearContext.monthYear,
            descriptionText: snapshot.isPlexDescriptionAutoManaged ? autoDescription : snapshot.plexDescriptionText,
            episodeTitleOverride: episodeTitleOverride,
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
        if snapshot.sourceMode == .photos, snapshot.selectedPhotosFilterMode == .album {
            guard let earliestCaptureDate = earliestCaptureDate(from: preparedSession.preparation.items) else {
                throw MonthYearResolutionError.noCaptureDates
            }
            return ResolvedMonthYearContext(
                monthYear: MonthYear(
                    month: calendar.component(.month, from: earliestCaptureDate),
                    year: calendar.component(.year, from: earliestCaptureDate)
                ),
                latestCaptureDate: earliestCaptureDate
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

    private func earliestCaptureDate(from items: [MediaItem]) -> Date? {
        items.compactMap(\.captureDate).min()
    }

    private func makeSingleRenderSummarySnapshot(snapshot: QueuedRenderSnapshot) -> SingleRenderSummarySnapshot {
        SingleRenderSummarySnapshot(
            requestedProfile: buildSelectedExportProfile(
                snapshot: snapshot,
                resolution: snapshot.selectedResolutionPolicy.normalized,
                frameRate: snapshot.selectedFrameRatePolicy,
                dynamicRange: snapshot.selectedDynamicRange,
                audioLayout: snapshot.selectedAudioLayout,
                hdrHEVCEncoderMode: snapshot.selectedHDRHEVCEncoderMode,
                hdrX265Speed: snapshot.selectedHDRX265Speed
            )
        )
    }

    private func generatedOutputName() -> String {
        generatedOutputName(for: makeCurrentRenderSnapshot())
    }

    private func generatedOutputName(for snapshot: QueuedRenderSnapshot) -> String {
        let monthYear = previewMonthYear(for: snapshot)
        return filenameGenerator.makeOutputName(
            showTitle: resolvedPlexShowTitle(for: snapshot),
            monthYear: monthYear,
            episodeTitleOverride: resolvedPlexEpisodeTitleOverride(
                for: monthYear,
                snapshot: snapshot
            )
        )
    }

    private func makeSelectedYearQueueSnapshot(
        from baseSnapshot: QueuedRenderSnapshot,
        monthYear: MonthYear
    ) -> QueuedRenderSnapshot {
        let openingTitleText: String
        if baseSnapshot.isOpeningTitleAutoManaged {
            openingTitleText = monthYear.displayLabel
        } else {
            openingTitleText = baseSnapshot.openingTitleText
        }

        let seededSnapshot = QueuedRenderSnapshot(
            sourceMode: .photos,
            selectedFolderURL: baseSnapshot.selectedFolderURL,
            recursiveScan: baseSnapshot.recursiveScan,
            selectedMonth: monthYear.month,
            selectedYear: monthYear.year,
            selectedPhotosFilterMode: .monthYear,
            selectedPhotoAlbumID: baseSnapshot.selectedPhotoAlbumID,
            selectedPhotoAlbumTitle: baseSnapshot.selectedPhotoAlbumTitle,
            outputDirectoryURL: baseSnapshot.outputDirectoryURL,
            plexShowTitle: baseSnapshot.plexShowTitle,
            outputFilename: "",
            isOutputNameAutoManaged: true,
            plexDescriptionText: baseSnapshot.plexDescriptionText,
            isPlexDescriptionAutoManaged: baseSnapshot.isPlexDescriptionAutoManaged,
            showsManualMonthYearOverride: false,
            manualMonthYearOverrideMonth: monthYear.month,
            manualMonthYearOverrideYear: monthYear.year,
            includeOpeningTitle: baseSnapshot.includeOpeningTitle,
            openingTitleText: openingTitleText,
            isOpeningTitleAutoManaged: baseSnapshot.isOpeningTitleAutoManaged,
            titleDurationSeconds: baseSnapshot.titleDurationSeconds,
            openingTitleCaptionMode: baseSnapshot.openingTitleCaptionMode,
            openingTitleCaptionText: baseSnapshot.openingTitleCaptionText,
            crossfadeDurationSeconds: baseSnapshot.crossfadeDurationSeconds,
            stillImageDurationSeconds: baseSnapshot.stillImageDurationSeconds,
            showCaptureDateOverlay: baseSnapshot.showCaptureDateOverlay,
            selectedContainer: baseSnapshot.selectedContainer,
            selectedVideoCodec: baseSnapshot.selectedVideoCodec,
            selectedFrameRatePolicy: baseSnapshot.selectedFrameRatePolicy,
            selectedResolutionPolicy: baseSnapshot.selectedResolutionPolicy,
            selectedDynamicRange: baseSnapshot.selectedDynamicRange,
            selectedHDRBinaryMode: baseSnapshot.selectedHDRBinaryMode,
            selectedHDRHEVCEncoderMode: baseSnapshot.selectedHDRHEVCEncoderMode,
            selectedHDRX265Speed: baseSnapshot.selectedHDRX265Speed,
            selectedAudioLayout: baseSnapshot.selectedAudioLayout,
            selectedBitrateMode: baseSnapshot.selectedBitrateMode,
            writeDiagnosticsLog: baseSnapshot.writeDiagnosticsLog
        )

        let generatedFilename = generatedOutputName(for: seededSnapshot)
        return QueuedRenderSnapshot(
            sourceMode: seededSnapshot.sourceMode,
            selectedFolderURL: seededSnapshot.selectedFolderURL,
            recursiveScan: seededSnapshot.recursiveScan,
            selectedMonth: seededSnapshot.selectedMonth,
            selectedYear: seededSnapshot.selectedYear,
            selectedPhotosFilterMode: seededSnapshot.selectedPhotosFilterMode,
            selectedPhotoAlbumID: seededSnapshot.selectedPhotoAlbumID,
            selectedPhotoAlbumTitle: seededSnapshot.selectedPhotoAlbumTitle,
            outputDirectoryURL: seededSnapshot.outputDirectoryURL,
            plexShowTitle: seededSnapshot.plexShowTitle,
            outputFilename: generatedFilename,
            isOutputNameAutoManaged: true,
            plexDescriptionText: seededSnapshot.plexDescriptionText,
            isPlexDescriptionAutoManaged: seededSnapshot.isPlexDescriptionAutoManaged,
            showsManualMonthYearOverride: seededSnapshot.showsManualMonthYearOverride,
            manualMonthYearOverrideMonth: seededSnapshot.manualMonthYearOverrideMonth,
            manualMonthYearOverrideYear: seededSnapshot.manualMonthYearOverrideYear,
            includeOpeningTitle: seededSnapshot.includeOpeningTitle,
            openingTitleText: seededSnapshot.openingTitleText,
            isOpeningTitleAutoManaged: seededSnapshot.isOpeningTitleAutoManaged,
            titleDurationSeconds: seededSnapshot.titleDurationSeconds,
            openingTitleCaptionMode: seededSnapshot.openingTitleCaptionMode,
            openingTitleCaptionText: seededSnapshot.openingTitleCaptionText,
            crossfadeDurationSeconds: seededSnapshot.crossfadeDurationSeconds,
            stillImageDurationSeconds: seededSnapshot.stillImageDurationSeconds,
            showCaptureDateOverlay: seededSnapshot.showCaptureDateOverlay,
            selectedContainer: seededSnapshot.selectedContainer,
            selectedVideoCodec: seededSnapshot.selectedVideoCodec,
            selectedFrameRatePolicy: seededSnapshot.selectedFrameRatePolicy,
            selectedResolutionPolicy: seededSnapshot.selectedResolutionPolicy,
            selectedDynamicRange: seededSnapshot.selectedDynamicRange,
            selectedHDRBinaryMode: seededSnapshot.selectedHDRBinaryMode,
            selectedHDRHEVCEncoderMode: seededSnapshot.selectedHDRHEVCEncoderMode,
            selectedHDRX265Speed: seededSnapshot.selectedHDRX265Speed,
            selectedAudioLayout: seededSnapshot.selectedAudioLayout,
            selectedBitrateMode: seededSnapshot.selectedBitrateMode,
            writeDiagnosticsLog: seededSnapshot.writeDiagnosticsLog
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
        isPauseRequested = false
        isQueueRunning = false
        isQueuePauseRequested = false
        queueRunContext = nil
        currentItemProgress = min(max(initialProgress, 0), 1)
        progress = currentItemProgress
        queueProgress = 0
        queueProgressLabel = "0 of 0"
        warnings = []
        renderStatusDetail = status
        renderStartedAt = nowProvider()
        statusOutputLabel = ""
        statusQueueLabel = "Single render"
        currentItemProgressLabel = formattedDetailedPercent(initialProgress)
        statusProgressLabel = currentItemProgressLabel
        statusElapsedLabel = "00:00"
        resetLiveSnapshotForNewRender()
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
        renderStartedAt = nil
        setCurrentItemProgress(1.0)
        statusPhaseLabel = "Complete"
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
        isPauseRequested = false
        isQueueRunning = false
        isQueuePauseRequested = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishFailedRun(_ error: Error) {
        renderStatusDetail = nil
        queueRunContext = nil
        renderStartedAt = nil
        setCurrentItemProgress(0)
        statusPhaseLabel = isCancellingRender || error is CancellationError ? "Cancelled" : "Failed"
        statusMessage = formatErrorForDisplay(error)
        cancelLiveSnapshot(
            removeImage: true,
            status: statusPhaseLabel == "Cancelled" ? "Snapshot stopped after cancellation." : "Snapshot stopped after render failure."
        )
        lastSingleRenderCompletionSummary = nil
        lastQueueCompletionSummary = nil
        renderCompleteAlertTitle = "Render Complete"
        showRenderCompleteAlert = false
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isPauseRequested = false
        isQueueRunning = false
        isQueuePauseRequested = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishPausedSingleRun(_ message: String) {
        renderStatusDetail = nil
        queueRunContext = nil
        renderStartedAt = nil
        setCurrentItemProgress(0)
        statusPhaseLabel = "Paused"
        statusMessage = message
        cancelLiveSnapshot(removeImage: true, status: "Snapshot stopped after render pause.")
        lastSingleRenderCompletionSummary = nil
        lastQueueCompletionSummary = nil
        renderCompleteAlertTitle = "Render Complete"
        showRenderCompleteAlert = false
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isPauseRequested = false
        isQueueRunning = false
        isQueuePauseRequested = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishSuccessfulQueueRun() {
        renderStatusDetail = nil
        queueRunContext = nil
        renderStartedAt = nil
        setCurrentItemProgress(1.0)
        statusPhaseLabel = "Queue complete"
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
        isPauseRequested = false
        isQueueRunning = false
        isQueuePauseRequested = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishPausedQueueRun(failedJob: QueuedRenderJob, errorMessage: String) {
        renderStatusDetail = nil
        queueRunContext = nil
        renderStartedAt = nil
        setCurrentItemProgress(0)
        statusPhaseLabel = "Queue paused"
        statusMessage = "Queue paused after failure\n\(failedJob.sourceSummary)\n\(errorMessage)"
        cancelLiveSnapshot(removeImage: true, status: "Snapshot stopped after queue failure.")
        lastSingleRenderCompletionSummary = nil
        lastQueueCompletionSummary = nil
        renderCompleteAlertTitle = "Queue Complete"
        showRenderCompleteAlert = false
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isPauseRequested = false
        isQueueRunning = false
        isQueuePauseRequested = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishUserPausedQueueRun(pausedJob: QueuedRenderJob, message: String) {
        renderStatusDetail = nil
        queueRunContext = nil
        renderStartedAt = nil
        setCurrentItemProgress(0)
        statusPhaseLabel = "Queue paused"
        statusMessage = "Queue paused by user\n\(pausedJob.sourceSummary)\n\(message)"
        cancelLiveSnapshot(removeImage: true, status: "Snapshot stopped after queue pause.")
        lastSingleRenderCompletionSummary = nil
        lastQueueCompletionSummary = nil
        renderCompleteAlertTitle = "Queue Complete"
        showRenderCompleteAlert = false
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isPauseRequested = false
        isQueueRunning = false
        isQueuePauseRequested = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishQueuePausedAfterCurrentItem() {
        renderStatusDetail = nil
        queueRunContext = nil
        renderStartedAt = nil
        statusPhaseLabel = "Queue paused"
        let completedCount = queuedRenderJobs.filter { $0.state == .completed }.count
        let queuedCount = queuedRenderJobs.filter { $0.state == .queued }.count
        statusMessage = "Queue paused after current item. Completed \(completedCount) job(s), queued \(queuedCount) job(s)."
        cancelLiveSnapshot(removeImage: false, status: "Snapshot preserved after queue pause.")
        lastSingleRenderCompletionSummary = nil
        lastQueueCompletionSummary = nil
        renderCompleteAlertTitle = "Queue Complete"
        showRenderCompleteAlert = false
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isPauseRequested = false
        isQueueRunning = false
        isQueuePauseRequested = false
        isCancellingRender = false
        isRendering = false
    }

    private func finishCancelledQueueRun() {
        renderStatusDetail = nil
        queueRunContext = nil
        renderStartedAt = nil
        setCurrentItemProgress(0)
        statusPhaseLabel = "Cancelled"
        statusMessage = "Render cancelled"
        cancelLiveSnapshot(removeImage: true, status: "Snapshot stopped after cancellation.")
        lastSingleRenderCompletionSummary = nil
        lastQueueCompletionSummary = nil
        renderCompleteAlertTitle = "Queue Complete"
        showRenderCompleteAlert = false
        pendingSystemFFmpegFallbackConfirmation = nil
        systemFFmpegFallbackContinuation = nil
        hasApprovedSystemFFmpegFallbackForCurrentRun = false
        isPauseRequested = false
        isQueueRunning = false
        isQueuePauseRequested = false
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
        hdrX265Speed: HDRX265Speed,
        items: [MediaItem]
    ) -> ExportProfileResolution {
        exportProfileManager.resolveProfile(
            for: buildSelectedExportProfile(
                snapshot: snapshot,
                resolution: resolution.normalized,
                frameRate: frameRate,
                dynamicRange: dynamicRange,
                audioLayout: audioLayout,
                hdrHEVCEncoderMode: hdrHEVCEncoderMode,
                hdrX265Speed: hdrX265Speed
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
        hdrHEVCEncoderMode: HDRHEVCEncoderMode,
        hdrX265Speed: HDRX265Speed
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
            hdrX265Speed: hdrX265Speed,
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
            try await ensurePhotosAuthorizationIfNeeded()

            switch snapshot.selectedPhotosFilterMode {
            case .monthYear:
                let source: MediaSource = .photosLibrary(scope: .entireLibrary(monthYear: monthYear))
                let discovered = try await photoDiscovery.discover(
                    monthYear: monthYear,
                    timeZone: calendar.timeZone
                )
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
                let effectiveStyle = albumStyle(
                    from: style,
                    snapshot: snapshot,
                    albumTitle: selectedAlbumTitle
                )
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
                    style: effectiveStyle,
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
                    style: effectiveStyle,
                    preparation: preparation,
                    usesPhotoMaterializer: true
                )
            }
        }
    }

    private func ensurePhotosAuthorizationIfNeeded() async throws {
        let status = photoDiscovery.authorizationStatus()
        if status == .authorized || status == .limited {
            return
        }

        let newStatus = await photoDiscovery.requestAuthorization()
        guard newStatus == .authorized || newStatus == .limited else {
            throw PhotoKitDiscoveryError.unauthorized(newStatus)
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
        progressMapper: @escaping @Sendable (Double) -> Double,
        executionOptions: RenderExecutionOptions
    ) async throws -> RenderResult {
        renderStatusDetail = nil
        statusOutputLabel = expectedOutputLabel(for: request)
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
            artifactHandler: { [weak self] candidate in
                self?.handleLiveSnapshotCandidate(candidate)
            },
            systemFFmpegFallbackHandler: { [weak self] request in
                guard let self else { return false }
                return await self.confirmSystemFFmpegFallbackIfNeeded(request)
            },
            executionOptions: executionOptions
        )
    }

    private func recordSuccessfulRender(
        _ renderResult: RenderResult,
        request: RenderRequest,
        preparation: RenderPreparation,
        writeDiagnosticsLog: Bool,
        completionSummarySnapshot: SingleRenderSummarySnapshot? = nil
    ) {
        let outputURL = renderResult.outputURL
        if writeDiagnosticsLog {
            let report = runReportService.makeReport(
                request: request,
                preparation: preparation,
                outputURL: outputURL,
                diagnosticsLogURL: renderResult.diagnosticsLogURL,
                renderBackendSummary: renderResult.backendSummary,
                outputFileSizeBytes: renderResult.executionDetails?.outputFileSizeBytes,
                renderElapsedSeconds: renderResult.executionDetails?.elapsedSeconds,
                renderBackendInfo: renderResult.backendInfo,
                resolvedVideoInfo: renderResult.resolvedVideoInfo,
                presentationTimingAudits: renderResult.executionDetails?.presentationTimingAudits ?? []
            )
            let reportURL = outputURL.deletingPathExtension().appendingPathExtension("json")
            try? runReportService.write(report, to: reportURL)
        }

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

    func containerLabel(for container: ContainerFormat) -> String {
        container.rawValue.uppercased()
    }

    func videoCodecLabel(for codec: VideoCodec) -> String {
        switch codec {
        case .hevc:
            return "HEVC"
        case .h264:
            return "H.264"
        }
    }

    func bitrateModeLabel(for bitrateMode: BitrateMode) -> String {
        switch bitrateMode {
        case .balanced:
            return "Balanced"
        case .qualityFirst:
            return "Quality First"
        case .sizeFirst:
            return "Size First"
        }
    }

    func resolutionPolicyLabel(for resolutionPolicy: ResolutionPolicy) -> String {
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

    func frameRatePolicyLabel(for frameRatePolicy: FrameRatePolicy) -> String {
        switch frameRatePolicy {
        case .fps30:
            return "30 fps"
        case .fps60:
            return "60 fps"
        case .smart:
            return "Smart"
        }
    }

    func dynamicRangeLabel(for dynamicRange: DynamicRange) -> String {
        dynamicRange.rawValue.uppercased()
    }

    func hdrBinaryModeLabel(for hdrBinaryMode: HDRFFmpegBinaryMode) -> String {
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

    func hdrHEVCEncoderModeLabel(for hdrHEVCEncoderMode: HDRHEVCEncoderMode) -> String {
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

    private func resolvedPlexEpisodeTitleOverride(
        for monthYear: MonthYear,
        snapshot: QueuedRenderSnapshot
    ) -> String? {
        guard snapshot.includeOpeningTitle, !snapshot.isOpeningTitleAutoManaged else {
            return nil
        }

        return resolvedOpeningTitle(for: monthYear, snapshot: snapshot)
    }

    private func resolvedCustomPlexEpisodeTitleOverride(
        snapshot: QueuedRenderSnapshot,
        title: String?
    ) -> String? {
        guard snapshot.includeOpeningTitle, !snapshot.isOpeningTitleAutoManaged else {
            return nil
        }

        return title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func albumStyle(
        from style: StyleProfile,
        snapshot: QueuedRenderSnapshot,
        albumTitle: String?
    ) -> StyleProfile {
        guard snapshot.includeOpeningTitle,
              snapshot.isOpeningTitleAutoManaged,
              let albumTitle = normalizedAlbumTitle(albumTitle)
        else {
            return style
        }

        return StyleProfile(
            openingTitle: albumTitle,
            titleDurationSeconds: style.titleDurationSeconds,
            crossfadeDurationSeconds: style.crossfadeDurationSeconds,
            stillImageDurationSeconds: style.stillImageDurationSeconds,
            showCaptureDateOverlay: style.showCaptureDateOverlay,
            openingTitleCaptionMode: style.openingTitleCaptionMode,
            openingTitleCaptionText: style.openingTitleCaptionText
        )
    }

    private func albumEpisodeTitleOverride(for source: MediaSource) -> String? {
        guard case let .photosLibrary(scope) = source,
              case let .album(_, title) = scope
        else {
            return nil
        }
        return normalizedAlbumTitle(title)
    }

    private func normalizedAlbumTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyReportedRenderProgress(_ reportedProgress: Double) {
        let clamped = min(max(reportedProgress, 0), 1)
        setCurrentItemProgress(max(currentItemProgress, clamped))
        updateRenderingStatusMessage()
    }

    private func setCurrentItemProgress(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        currentItemProgress = clamped
        progress = clamped
        currentItemProgressLabel = formattedDetailedPercent(clamped)
        statusProgressLabel = currentItemProgressLabel
    }

    private func updateQueueProgress(completedCount: Int, totalCount: Int) {
        let clampedTotal = max(totalCount, 0)
        let clampedCompleted = min(max(completedCount, 0), clampedTotal)
        if clampedTotal == 0 {
            queueProgress = 0
            queueProgressLabel = "0 of 0"
            return
        }
        queueProgress = Double(clampedCompleted) / Double(clampedTotal)
        queueProgressLabel = "\(clampedCompleted) of \(clampedTotal)"
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
        let percentLabel = currentItemProgressLabel
        statusElapsedLabel = formattedElapsedSinceRenderStart()
        statusQueueLabel = queueRunContext.map {
            "Queue job \($0.currentJobNumber) of \($0.totalJobCount)"
        } ?? "Single render"
        let renderMessage: String
        if let renderStatusDetail, !renderStatusDetail.isEmpty {
            statusPhaseLabel = compactStatusLine(from: renderStatusDetail)
            renderMessage = "\(renderStatusDetail)\nCurrent item progress: \(percentLabel)"
        } else {
            statusPhaseLabel = isRendering ? "Rendering" : "Idle"
            renderMessage = "Rendering... \(percentLabel)"
        }

        if let queueRunContext {
            statusMessage = "Queue job \(queueRunContext.currentJobNumber) of \(queueRunContext.totalJobCount)\n\(renderMessage)"
            return
        }

        statusMessage = renderMessage
    }

    private func resetLiveSnapshotForNewRender() {
        liveSnapshotTask?.cancel()
        liveSnapshotTask = nil
        liveSnapshotSessionID = UUID()
        lastLiveSnapshotAttemptAt = nil
        currentArtifactLabel = "Waiting for readable output"
        currentArtifactPath = ""
        currentArtifactSizeLabel = ""
        liveSnapshotStatusMessage = "Waiting for the first completed render artifact."
        liveSnapshotImageURL = nil
        liveSnapshotCapturedLabel = ""
        Task {
            await liveSnapshotService.prepareForNewRender(sessionID: liveSnapshotSessionID)
        }
    }

    private func cancelLiveSnapshot(removeImage: Bool, status: String) {
        liveSnapshotTask?.cancel()
        liveSnapshotTask = nil
        liveSnapshotStatusMessage = status
        currentArtifactSizeLabel = ""
        if removeImage {
            liveSnapshotImageURL = nil
            liveSnapshotCapturedLabel = ""
            Task {
                await liveSnapshotService.removeAllSnapshots()
            }
        }
    }

    private func handleLiveSnapshotCandidate(_ candidate: RenderArtifactSnapshotCandidate) {
        currentArtifactLabel = candidate.label
        currentArtifactPath = candidate.url.path
        currentArtifactSizeLabel = fileSizeLabel(at: candidate.url) ?? "Size unavailable"
        if candidate.isFinalOutput {
            statusOutputLabel = candidate.url.path
        }

        let now = nowProvider()
        guard shouldAttemptLiveSnapshot(now: now) else {
            liveSnapshotStatusMessage = "Watching \(candidate.label). Next snapshot after the 3-minute interval."
            return
        }

        lastLiveSnapshotAttemptAt = now
        liveSnapshotStatusMessage = "Preparing snapshot from \(candidate.label)..."
        let sessionID = liveSnapshotSessionID
        liveSnapshotTask = Task { [weak self, candidate, sessionID, now] in
            guard let self else { return }
            do {
                let result = try await self.liveSnapshotService.makeSnapshot(
                    from: candidate,
                    sessionID: sessionID,
                    capturedAt: now
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.liveSnapshotSessionID == sessionID else { return }
                    self.liveSnapshotImageURL = result.snapshotURL
                    self.currentArtifactPath = result.sourceURL.path
                    self.currentArtifactSizeLabel = Self.formatByteCount(result.sourceFileSizeBytes)
                    self.liveSnapshotCapturedLabel = self.formattedSnapshotTimestamp(now)
                    self.liveSnapshotStatusMessage = "Latest snapshot from \(candidate.label)."
                    self.liveSnapshotTask = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.liveSnapshotSessionID == sessionID else { return }
                    self.liveSnapshotStatusMessage = "Waiting for readable output: \(self.snapshotErrorDescription(error))."
                    self.liveSnapshotTask = nil
                }
            }
        }
    }

    private func shouldAttemptLiveSnapshot(now: Date) -> Bool {
        guard isRendering else { return false }
        guard liveSnapshotTask == nil else { return false }
        guard let lastLiveSnapshotAttemptAt else { return true }
        return now.timeIntervalSince(lastLiveSnapshotAttemptAt) >= Self.liveSnapshotIntervalSeconds
    }

    private func expectedOutputLabel(for request: RenderRequest) -> String {
        request.output.directory
            .appendingPathComponent(request.output.baseFilename)
            .appendingPathExtension(request.export.container.fileExtension)
            .path
    }

    private func compactStatusLine(from message: String) -> String {
        message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .split(separator: "|", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? message
    }

    private func formattedElapsedSinceRenderStart() -> String {
        guard let renderStartedAt else { return "00:00" }
        return Self.formatElapsed(nowProvider().timeIntervalSince(renderStartedAt))
    }

    private func formattedDetailedPercent(_ value: Double) -> String {
        let percent = min(max(value, 0), 1) * 100
        if percent == 0 || percent == 100 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }

    private func fileSizeLabel(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if let size = attributes[.size] as? NSNumber {
            return Self.formatByteCount(size.uint64Value)
        }
        if let size = attributes[.size] as? Int {
            return Self.formatByteCount(UInt64(max(size, 0)))
        }
        return nil
    }

    private func outputFileSizeBytes(at url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        if let size = attributes[.size] as? Int {
            return Int64(max(size, 0))
        }
        return nil
    }

    private func makeQueueResultSummary(
        from result: RenderSnapshotExecutionResult
    ) -> QueuedRenderJobResultSummary {
        let mediaCountLabel = queueMediaCountLabel(result.mediaCount)
        let outputFileSizeLabel = result.outputFileSizeBytes.map {
            Self.formatByteCount(UInt64(max($0, 0)))
        } ?? "Size unavailable"
        return QueuedRenderJobResultSummary(
            elapsedSeconds: result.elapsedSeconds,
            mediaCount: result.mediaCount,
            outputFileSizeBytes: result.outputFileSizeBytes,
            outputFilename: result.renderResult.outputURL.lastPathComponent,
            elapsedLabel: result.elapsedSeconds.map { "Completed in \(Self.formatElapsed($0))" } ?? "Time unavailable",
            mediaCountLabel: mediaCountLabel,
            outputFileSizeLabel: outputFileSizeLabel,
            metricsLine: "\(mediaCountLabel) · \(outputFileSizeLabel)"
        )
    }

    private func queueMediaCountLabel(_ mediaCount: Int) -> String {
        let noun = mediaCount == 1 ? "file" : "files"
        return "\(mediaCount) \(noun)"
    }

    private func formattedSnapshotTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return "Captured \(formatter.string(from: date))"
    }

    private func snapshotErrorDescription(_ error: Error) -> String {
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatElapsed(_ elapsed: TimeInterval) -> String {
        let clampedSeconds = max(Int(elapsed.rounded()), 0)
        let hours = clampedSeconds / 3600
        let minutes = (clampedSeconds % 3600) / 60
        let seconds = clampedSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func formatByteCount(_ bytes: UInt64) -> String {
        let clamped = min(bytes, UInt64(Int64.max))
        return ByteCountFormatter.string(fromByteCount: Int64(clamped), countStyle: .file)
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
        titleDurationSeconds = min(max(settings.titleDurationSeconds ?? Self.defaultTitleDurationSeconds, 1), 20)
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
        selectedHDRX265Speed = settings.selectedHDRX265Speed ?? .medium
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
            selectedHDRX265Speed: selectedHDRX265Speed,
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
        let selectedHDRX265Speed: HDRX265Speed?
        let selectedAudioLayout: AudioLayout
        let selectedBitrateMode: BitrateMode
        let writeDiagnosticsLog: Bool?
        let plexDescriptionText: String?
        let isPlexDescriptionAutoManaged: Bool?
    }
}
