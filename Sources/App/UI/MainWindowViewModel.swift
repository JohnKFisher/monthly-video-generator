import Core
import Foundation
import Photos
import PhotosIntegration
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

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

    @Published var sourceMode: SourceMode = .folder {
        didSet { refreshPhotoAlbumsIfNeeded() }
    }
    @Published var selectedFolderURL: URL?
    @Published var recursiveScan: Bool = true

    @Published var selectedMonth: Int
    @Published var selectedYear: Int
    @Published var selectedPhotosFilterMode: PhotosFilterMode = .monthYear {
        didSet {
            handleRenderSettingChange()
            refreshPhotoAlbumsIfNeeded()
        }
    }
    @Published var selectedPhotoAlbumID: String = "" {
        didSet { handleRenderSettingChange() }
    }
    @Published private(set) var photoAlbums: [PhotoAlbumSummary] = []
    @Published private(set) var isLoadingPhotoAlbums: Bool = false
    @Published private(set) var photoAlbumsStatusMessage: String = ""

    @Published var outputDirectoryURL: URL
    @Published var outputFilename: String = "Monthly Slideshow"

    @Published var includeOpeningTitle: Bool = true {
        didSet { handleRenderSettingChange() }
    }
    @Published var openingTitleText: String {
        didSet { handleRenderSettingChange() }
    }
    @Published var crossfadeDurationSeconds: Double = 0.75 {
        didSet { handleRenderSettingChange() }
    }
    @Published var stillImageDurationSeconds: Double = 3.0 {
        didSet { handleRenderSettingChange() }
    }

    @Published var selectedContainer: ContainerFormat = MainWindowViewModel.defaultExportProfile.container {
        didSet { handleRenderSettingChange() }
    }
    @Published var selectedVideoCodec: VideoCodec = MainWindowViewModel.defaultExportProfile.videoCodec {
        didSet { handleRenderSettingChange(enforceHDRConstraints: true) }
    }
    @Published var selectedResolutionPolicy: ResolutionPolicy = MainWindowViewModel.defaultExportProfile.resolution {
        didSet { handleRenderSettingChange() }
    }
    @Published var selectedDynamicRange: DynamicRange = MainWindowViewModel.defaultExportProfile.dynamicRange {
        didSet { handleRenderSettingChange(enforceHDRConstraints: true) }
    }
    @Published var selectedHDRBinaryMode: HDRFFmpegBinaryMode = MainWindowViewModel.defaultExportProfile.hdrFFmpegBinaryMode {
        didSet { handleRenderSettingChange() }
    }
    @Published var selectedAudioLayout: AudioLayout = MainWindowViewModel.defaultExportProfile.audioLayout {
        didSet { handleRenderSettingChange(enforceHDRConstraints: true) }
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
    @Published var showRenderCompleteAlert: Bool = false

    let appVersionBuildLabel: String
    let months = Array(1...12)
    let years: [Int]

    private let coordinator = RenderCoordinator()
    private let photoDiscovery = PhotoKitMediaDiscoveryService()
    private let photoMaterializer = PhotoKitAssetMaterializer()
    private let exportProfileManager = ExportProfileManager()
    private let runReportService = RunReportService()
    private let preferencesStore = UserDefaults.standard
    private var renderStatusDetail: String?
    private var isApplyingExportConstraints = false
    private var isRestoringPersistedSettings = false

    private static let defaultExportProfile = ExportProfileManager().defaultProfile()
    private static let renderSettingsDefaultsKey = "MainWindowViewModel.renderSettings.v1"

    init() {
        appVersionBuildLabel = AppMetadata.versionBuildLabel
        let now = Date()
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        selectedMonth = currentMonth
        selectedYear = currentYear
        openingTitleText = MonthYear(month: currentMonth, year: currentYear).displayLabel
        years = Array((currentYear - 15)...(currentYear + 2)).reversed()

        let moviesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Monthly Video Generator", isDirectory: true)
        outputDirectoryURL = moviesDirectory

        applyPersistedRenderSettings()
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
            if outputFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let folderName = panel.url?.lastPathComponent,
               !folderName.isEmpty {
                outputFilename = folderName
            }
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

    var hasPhotoAlbums: Bool {
        !photoAlbums.isEmpty
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
        "HDR currently exports as HEVC Main10 video with AAC stereo for Plex + Infuse playback on Apple TV 4K."
    }

    var bitrateModeDescription: String {
        if selectedDynamicRange == .hdr {
            return "Bitrate mode controls HDR FFmpeg encode quality, size, and speed tradeoffs."
        }
        return "Bitrate mode has limited effect on SDR exports that use AVFoundation presets."
    }

    func resetExportSettingsToPlexDefaults() {
        let profile = exportProfileManager.defaultProfile()
        isRestoringPersistedSettings = true
        selectedContainer = profile.container
        selectedVideoCodec = profile.videoCodec
        selectedResolutionPolicy = profile.resolution.normalized
        selectedDynamicRange = profile.dynamicRange
        selectedHDRBinaryMode = profile.hdrFFmpegBinaryMode
        selectedAudioLayout = profile.audioLayout
        selectedBitrateMode = profile.bitrateMode
        writeDiagnosticsLog = true
        isRestoringPersistedSettings = false
        enforceHDRSelectionConstraints()
        persistRenderSettings()
        warnings = exportProfileManager.compatibilityWarnings(for: profile).map(\.message)
    }

    func startRender() {
        guard !isRendering else { return }

        Task {
            await performRender()
        }
    }

    func cancelRender() {
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

    private func performRender() async {
        do {
            isRendering = true
            progress = 0.01
            warnings = []
            renderStatusDetail = nil
            statusMessage = "Preparing media..."
            lastOutputPath = ""
            lastDiagnosticsPath = ""
            lastBackendSummary = ""
            showRenderCompleteAlert = false

            let monthYear = MonthYear(month: selectedMonth, year: selectedYear)
            let openingTitle = includeOpeningTitle ? resolvedOpeningTitle(for: monthYear) : nil

            let style = StyleProfile(
                openingTitle: openingTitle,
                titleDurationSeconds: includeOpeningTitle ? 2.5 : 0,
                crossfadeDurationSeconds: crossfadeDurationSeconds,
                stillImageDurationSeconds: stillImageDurationSeconds
            )

            let selectedExportProfile = ExportProfile(
                container: selectedContainer,
                videoCodec: selectedVideoCodec,
                audioCodec: .aac,
                resolution: selectedResolutionPolicy.normalized,
                dynamicRange: selectedDynamicRange,
                hdrFFmpegBinaryMode: selectedHDRBinaryMode,
                audioLayout: selectedAudioLayout,
                bitrateMode: selectedBitrateMode
            )
            let exportResolution = exportProfileManager.resolveProfile(for: selectedExportProfile)
            let exportProfile = exportResolution.effectiveProfile

            let request: RenderRequest
            let preparation: RenderPreparation

            switch sourceMode {
            case .folder:
                guard let selectedFolderURL else {
                    throw ViewModelError.missingFolder
                }

                request = RenderRequest(
                    source: .folder(path: selectedFolderURL, recursive: recursiveScan),
                    monthYear: nil,
                    ordering: .captureDateAscendingStable,
                    style: style,
                    export: exportProfile,
                    output: OutputTarget(directory: outputDirectoryURL, baseFilename: outputFilename)
                )
                preparation = try await coordinator.prepareFolderRender(request: request)

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
                    request = RenderRequest(
                        source: .photosLibrary(scope: .entireLibrary(monthYear: monthYear)),
                        monthYear: monthYear,
                        ordering: .captureDateAscendingStable,
                        style: style,
                        export: exportProfile,
                        output: OutputTarget(directory: outputDirectoryURL, baseFilename: outputFilename)
                    )
                    let discovered = try await photoDiscovery.discover(monthYear: monthYear)
                    preparation = coordinator.prepareFromItems(discovered, request: request)

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
                    request = RenderRequest(
                        source: .photosLibrary(scope: .album(localIdentifier: selectedAlbumID, title: selectedAlbumTitle)),
                        monthYear: nil,
                        ordering: .captureDateAscendingStable,
                        style: style,
                        export: exportProfile,
                        output: OutputTarget(directory: outputDirectoryURL, baseFilename: outputFilename)
                    )
                    let discovered = try await photoDiscovery.discover(albumLocalIdentifier: selectedAlbumID)
                    preparation = coordinator.prepareFromItems(discovered, request: request)
                }
            }

            warnings = preparation.warnings + exportResolution.warnings.map(\.message)
            progress = max(progress, 0.08)

            renderStatusDetail = nil
            updateRenderingStatusMessage()
            let renderResult = try await coordinator.render(
                preparation: preparation,
                request: request,
                photoMaterializer: sourceMode == .photos ? photoMaterializer : nil,
                writeDiagnosticsLog: writeDiagnosticsLog,
                progressHandler: { [weak self] reportedProgress in
                    self?.applyReportedRenderProgress(reportedProgress)
                },
                statusHandler: { [weak self] status in
                    self?.applyReportedRenderStatus(status)
                }
            )
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
            progress = 1.0
            if lastDiagnosticsPath.isEmpty {
                statusMessage = "Render complete"
            } else {
                statusMessage = "Render complete\nDiagnostics: \(lastDiagnosticsPath)"
            }
            if !lastBackendSummary.isEmpty {
                statusMessage += "\nBackend: \(lastBackendSummary)"
            }
            showRenderCompleteAlert = true
        } catch {
            renderStatusDetail = nil
            progress = 0
            statusMessage = formatErrorForDisplay(error)
            showRenderCompleteAlert = false
        }

        isRendering = false
    }

    private func formatErrorForDisplay(_ error: Error) -> String {
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

    private func resolvedOpeningTitle(for monthYear: MonthYear) -> String {
        let trimmed = openingTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if let renderStatusDetail, !renderStatusDetail.isEmpty {
            statusMessage = "\(renderStatusDetail)\nOverall progress: \(percent)%"
        } else {
            statusMessage = "Rendering... \(percent)%"
        }
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
        if selectedAudioLayout != .stereo {
            selectedAudioLayout = .stereo
        }
    }

    private func applyPersistedRenderSettings() {
        guard let settings = loadPersistedRenderSettings() else {
            return
        }

        isRestoringPersistedSettings = true
        includeOpeningTitle = settings.includeOpeningTitle
        openingTitleText = settings.openingTitleText
        crossfadeDurationSeconds = min(max(settings.crossfadeDurationSeconds, 0), 2)
        stillImageDurationSeconds = min(max(settings.stillImageDurationSeconds, 1), 10)
        selectedPhotosFilterMode = settings.selectedPhotosFilterMode ?? .monthYear
        selectedPhotoAlbumID = settings.selectedPhotoAlbumID ?? ""
        selectedContainer = settings.selectedContainer
        selectedVideoCodec = settings.selectedVideoCodec
        selectedResolutionPolicy = settings.selectedResolutionPolicy.normalized
        selectedDynamicRange = settings.selectedDynamicRange
        selectedHDRBinaryMode = settings.selectedHDRBinaryMode ?? .autoSystemThenBundled
        selectedAudioLayout = settings.selectedAudioLayout
        selectedBitrateMode = settings.selectedBitrateMode
        writeDiagnosticsLog = settings.writeDiagnosticsLog ?? true
        isRestoringPersistedSettings = false
        enforceHDRSelectionConstraints()
        persistRenderSettings()
        refreshPhotoAlbumsIfNeeded()
    }

    private func loadPersistedRenderSettings() -> PersistedRenderSettings? {
        guard let data = preferencesStore.data(forKey: Self.renderSettingsDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedRenderSettings.self, from: data)
    }

    private func persistRenderSettings() {
        let settings = PersistedRenderSettings(
            includeOpeningTitle: includeOpeningTitle,
            openingTitleText: openingTitleText,
            crossfadeDurationSeconds: crossfadeDurationSeconds,
            stillImageDurationSeconds: stillImageDurationSeconds,
            selectedPhotosFilterMode: selectedPhotosFilterMode,
            selectedPhotoAlbumID: selectedPhotoAlbumID,
            selectedContainer: selectedContainer,
            selectedVideoCodec: selectedVideoCodec,
            selectedResolutionPolicy: selectedResolutionPolicy.normalized,
            selectedDynamicRange: selectedDynamicRange,
            selectedHDRBinaryMode: selectedHDRBinaryMode,
            selectedAudioLayout: selectedAudioLayout,
            selectedBitrateMode: selectedBitrateMode,
            writeDiagnosticsLog: writeDiagnosticsLog
        )

        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        preferencesStore.set(data, forKey: Self.renderSettingsDefaultsKey)
    }

    private struct PersistedRenderSettings: Codable {
        let includeOpeningTitle: Bool
        let openingTitleText: String
        let crossfadeDurationSeconds: Double
        let stillImageDurationSeconds: Double
        let selectedPhotosFilterMode: PhotosFilterMode?
        let selectedPhotoAlbumID: String?
        let selectedContainer: ContainerFormat
        let selectedVideoCodec: VideoCodec
        let selectedResolutionPolicy: ResolutionPolicy
        let selectedDynamicRange: DynamicRange
        let selectedHDRBinaryMode: HDRFFmpegBinaryMode?
        let selectedAudioLayout: AudioLayout
        let selectedBitrateMode: BitrateMode
        let writeDiagnosticsLog: Bool?
    }
}
