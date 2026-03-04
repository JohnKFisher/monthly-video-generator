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

    enum ViewModelError: LocalizedError {
        case missingFolder

        var errorDescription: String? {
            switch self {
            case .missingFolder:
                return "Choose an input folder before rendering."
            }
        }
    }

    @Published var sourceMode: SourceMode = .folder
    @Published var selectedFolderURL: URL?
    @Published var recursiveScan: Bool = true

    @Published var selectedMonth: Int
    @Published var selectedYear: Int

    @Published var outputDirectoryURL: URL
    @Published var outputFilename: String = "Monthly Slideshow"

    @Published var includeOpeningTitle: Bool = true
    @Published var crossfadeDurationSeconds: Double = 0.75
    @Published var stillImageDurationSeconds: Double = 3.0

    @Published var selectedContainer: ContainerFormat = .mov
    @Published var selectedVideoCodec: VideoCodec = .hevc
    @Published var selectedResolutionPolicy: ResolutionPolicy = .matchSourceMax
    @Published var selectedDynamicRange: DynamicRange = .sdr
    @Published var selectedAudioLayout: AudioLayout = .stereo
    @Published var selectedBitrateMode: BitrateMode = .balanced

    @Published var isRendering: Bool = false
    @Published var progress: Double = 0
    @Published var statusMessage: String = "Idle"
    @Published var warnings: [String] = []
    @Published var lastOutputPath: String = ""

    let appVersionBuildLabel: String
    let months = Array(1...12)
    let years: [Int]

    private let coordinator = RenderCoordinator()
    private let photoDiscovery = PhotoKitMediaDiscoveryService()
    private let photoMaterializer = PhotoKitAssetMaterializer()
    private let exportProfileManager = ExportProfileManager()
    private let runReportService = RunReportService()

    init() {
        appVersionBuildLabel = AppMetadata.versionBuildLabel
        let now = Date()
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        selectedMonth = calendar.component(.month, from: now)
        selectedYear = currentYear
        years = Array((currentYear - 15)...(currentYear + 2)).reversed()

        let moviesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Monthly Video Generator", isDirectory: true)
        outputDirectoryURL = moviesDirectory
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

    private func performRender() async {
        do {
            isRendering = true
            progress = 0
            warnings = []
            statusMessage = "Preparing media..."
            lastOutputPath = ""

            let monthYear = MonthYear(month: selectedMonth, year: selectedYear)
            let openingTitle = includeOpeningTitle ? monthYear.displayLabel : nil

            let style = StyleProfile(
                openingTitle: openingTitle,
                titleDurationSeconds: includeOpeningTitle ? 2.5 : 0,
                crossfadeDurationSeconds: crossfadeDurationSeconds,
                stillImageDurationSeconds: stillImageDurationSeconds
            )

            let exportProfile = ExportProfile(
                container: selectedContainer,
                videoCodec: selectedVideoCodec,
                audioCodec: .aac,
                resolution: selectedResolutionPolicy,
                dynamicRange: selectedDynamicRange,
                audioLayout: selectedAudioLayout,
                bitrateMode: selectedBitrateMode
            )

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
            }

            warnings = preparation.warnings + exportProfileManager.compatibilityWarnings(for: exportProfile).map(\.message)

            statusMessage = "Rendering..."
            progress = 0.01
            let outputURL = try await coordinator.render(
                preparation: preparation,
                request: request,
                photoMaterializer: sourceMode == .photos ? photoMaterializer : nil,
                progressHandler: nil
            )

            let report = runReportService.makeReport(request: request, preparation: preparation, outputURL: outputURL)
            let reportURL = outputURL.deletingPathExtension().appendingPathExtension("json")
            try? runReportService.write(report, to: reportURL)

            lastOutputPath = outputURL.path
            progress = 1.0
            statusMessage = "Render complete"
        } catch {
            progress = 0
            statusMessage = error.localizedDescription
        }

        isRendering = false
    }
}
