import Core
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct MainWindowView: View {
    @StateObject private var viewModel = MainWindowViewModel()
    @State private var isAdvancedExportSettingsExpanded = false
    @State private var isRenderQueueExpanded = false
    @State private var isNotesExpanded = false
    @State private var isHeaderEasterEggPresented = false
    private let sectionSpacing: CGFloat = 12
    private let rowSpacing: CGFloat = 8
    private let headerCornerRadius: CGFloat = 20

    var body: some View {
        ZStack {
            appBackgroundLayer

            VStack(alignment: .leading, spacing: sectionSpacing) {
                headerBar

                ScrollView {
                    VStack(alignment: .leading, spacing: sectionSpacing) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: sectionSpacing) {
                                leftColumn
                                rightColumn
                            }

                            VStack(alignment: .leading, spacing: sectionSpacing) {
                                leftColumn
                                rightColumn
                            }
                        }

                        warningsSection
                        statusArea
                        actionRow
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 920, minHeight: 700)
        .tint(themeTeal)
        .alert(viewModel.renderCompleteAlertTitle, isPresented: $viewModel.showRenderCompleteAlert) {
            Button("Open Folder") {
                viewModel.openRenderedOutputFolder()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.renderCompleteAlertMessage)
        }
        .alert(
            "Use System FFmpeg?",
            isPresented: Binding(
                get: { viewModel.pendingSystemFFmpegFallbackConfirmation != nil },
                set: { _ in }
            )
        ) {
            Button("Use System FFmpeg") {
                viewModel.approveSystemFFmpegFallback()
            }
            Button("Cancel Render", role: .cancel) {
                viewModel.cancelSystemFFmpegFallback()
            }
        } message: {
            Text(viewModel.pendingSystemFFmpegFallbackConfirmation?.alertMessage ?? "")
        }
    }

    private var headerBar: some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                headerIconView

                VStack(alignment: .leading, spacing: 2) {
                    Text(AppMetadata.appName)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.white.opacity(0.96))
                    Text(viewModel.appVersionBuildLabel)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.78))
                }
            }

            Spacer(minLength: 12)

            Picker("Source", selection: $viewModel.sourceMode) {
                ForEach(MainWindowViewModel.SourceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: headerCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            themeTeal.opacity(0.96),
                            themeNavy.opacity(0.97)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: headerCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            inputSection
            styleSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            exportSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var inputSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: rowSpacing) {
                if viewModel.sourceMode == .folder {
                    HStack(spacing: 10) {
                        Button("Choose Folder") {
                            viewModel.chooseInputFolder()
                        }
                        Toggle("Recursive", isOn: $viewModel.recursiveScan)
                    }

                    Text(viewModel.selectedFolderURL?.path ?? "No folder selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else {
                    Picker("Photos Filter", selection: $viewModel.selectedPhotosFilterMode) {
                        ForEach(MainWindowViewModel.PhotosFilterMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if viewModel.selectedPhotosFilterMode == .monthYear {
                        HStack(spacing: 10) {
                            Picker("Month", selection: $viewModel.selectedMonth) {
                                ForEach(viewModel.months, id: \.self) { month in
                                    Text(viewModel.monthLabel(for: month)).tag(month)
                                }
                            }
                            Picker("Year", selection: $viewModel.selectedYear) {
                                ForEach(viewModel.years, id: \.self) { year in
                                    Text(String(year)).tag(year)
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 10) {
                            Picker("Album", selection: $viewModel.selectedPhotoAlbumID) {
                                if viewModel.photoAlbums.isEmpty {
                                    Text("No Albums Available").tag("")
                                } else {
                                    ForEach(viewModel.photoAlbums) { album in
                                        Text(album.displayLabel).tag(album.localIdentifier)
                                    }
                                }
                            }
                            .disabled(viewModel.isLoadingPhotoAlbums || !viewModel.hasPhotoAlbums)

                            Button("Refresh") {
                                viewModel.refreshPhotoAlbums()
                            }
                            .disabled(viewModel.isLoadingPhotoAlbums)
                        }

                        if viewModel.isLoadingPhotoAlbums {
                            HStack(spacing: 8) {
                                ProgressView()
                                caption("Loading albums...")
                            }
                        } else if !viewModel.photoAlbumsStatusMessage.isEmpty {
                            caption(viewModel.photoAlbumsStatusMessage)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            sectionLabel("Input", accent: themeTeal)
        }
    }

    private var styleSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: rowSpacing) {
                Toggle("Opening title card", isOn: $viewModel.includeOpeningTitle)

                if viewModel.includeOpeningTitle {
                    TextField("Title text", text: $viewModel.openingTitleText)
                    caption("Defaults to the selected month and year until you type a custom title.")
                    TextField("Small caption", text: $viewModel.openingTitleCaptionText)
                    caption("Leave blank to hide the smaller caption.")

                    sliderRow(
                        title: "Title card duration",
                        value: $viewModel.titleDurationSeconds,
                        range: 1...10,
                        step: 0.25,
                        displayValue: String(format: "%.2fs", viewModel.titleDurationSeconds)
                    )
                }

                sliderRow(
                    title: "Crossfade",
                    value: $viewModel.crossfadeDurationSeconds,
                    range: 0...2,
                    step: 0.05,
                    displayValue: String(format: "%.2fs", viewModel.crossfadeDurationSeconds)
                )

                sliderRow(
                    title: "Still image duration",
                    value: $viewModel.stillImageDurationSeconds,
                    range: 1...10,
                    step: 0.25,
                    displayValue: String(format: "%.2fs", viewModel.stillImageDurationSeconds)
                )

                Toggle("Show capture date", isOn: $viewModel.showCaptureDateOverlay)
                caption("Displays each photo or video's capture date in the bottom-right corner using your current local timezone.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            sectionLabel("Style", accent: themePeach)
        }
    }

    private var exportSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: rowSpacing) {
                TextField("Series Title", text: $viewModel.plexShowTitle)
                caption("Used for Plex TV episode filenames and embedded MP4 metadata.")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        TextField("Filename", text: $viewModel.outputFilename)
                        Button(viewModel.isOutputNameAutoManaged ? "Regenerate" : "Use Auto Name") {
                            viewModel.useAutoGeneratedOutputName()
                        }
                        Button("Choose Folder") {
                            viewModel.chooseOutputFolder()
                        }
                        Button("Open Folder") {
                            viewModel.openConfiguredOutputFolder()
                        }
                    }

                    VStack(alignment: .leading, spacing: rowSpacing) {
                        TextField("Filename", text: $viewModel.outputFilename)
                        HStack(spacing: 10) {
                            Button(viewModel.isOutputNameAutoManaged ? "Regenerate" : "Use Auto Name") {
                                viewModel.useAutoGeneratedOutputName()
                            }
                            Button("Choose Folder") {
                                viewModel.chooseOutputFolder()
                            }
                            Button("Open Folder") {
                                viewModel.openConfiguredOutputFolder()
                            }
                        }
                    }
                }

                caption(viewModel.outputDirectoryURL.path)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                caption(viewModel.outputNameAutomationDescription)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("Description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(viewModel.isPlexDescriptionAutoManaged ? "Regenerate" : "Use Default") {
                            viewModel.useDefaultPlexDescription()
                        }
                    }

                    TextEditor(text: $viewModel.plexDescriptionText)
                        .font(.body)
                        .frame(minHeight: 84)

                    caption(viewModel.plexDescriptionAutomationDescription)
                }

                if viewModel.showsManualMonthYearOverride {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        Text("Manual Month/Year Override")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        caption(viewModel.manualMonthYearOverrideMessage)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                Picker("Month", selection: $viewModel.manualMonthYearOverrideMonth) {
                                    ForEach(viewModel.months, id: \.self) { month in
                                        Text(viewModel.monthLabel(for: month)).tag(month)
                                    }
                                }

                                Picker("Year", selection: $viewModel.manualMonthYearOverrideYear) {
                                    ForEach(viewModel.years, id: \.self) { year in
                                        Text(String(year)).tag(year)
                                    }
                                }

                                Button("Clear Override") {
                                    viewModel.clearManualMonthYearOverride()
                                }
                            }

                            VStack(alignment: .leading, spacing: rowSpacing) {
                                Picker("Month", selection: $viewModel.manualMonthYearOverrideMonth) {
                                    ForEach(viewModel.months, id: \.self) { month in
                                        Text(viewModel.monthLabel(for: month)).tag(month)
                                    }
                                }

                                Picker("Year", selection: $viewModel.manualMonthYearOverrideYear) {
                                    ForEach(viewModel.years, id: \.self) { year in
                                        Text(String(year)).tag(year)
                                    }
                                }

                                Button("Clear Override") {
                                    viewModel.clearManualMonthYearOverride()
                                }
                            }
                        }

                        caption("Use this only when folder or album media spans multiple months or is missing capture dates.")
                    }
                }

                DisclosureGroup(
                    "Advanced Export Settings",
                    isExpanded: $isAdvancedExportSettingsExpanded
                ) {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: rowSpacing) {
                            GridRow {
                                Picker("Container", selection: $viewModel.selectedContainer) {
                                    ForEach(ContainerFormat.allCases, id: \.self) { format in
                                        Text(format.rawValue.uppercased()).tag(format)
                                    }
                                }

                                Picker("Codec", selection: $viewModel.selectedVideoCodec) {
                                    ForEach(VideoCodec.allCases, id: \.self) { codec in
                                        Text(codec.rawValue.uppercased()).tag(codec)
                                    }
                                }
                                .disabled(viewModel.isHDRSelectionLocked)
                            }

                            GridRow {
                                Picker("Audio", selection: $viewModel.selectedAudioLayout) {
                                    ForEach(AudioLayout.allCases, id: \.self) { layout in
                                        Text(layout.displayLabel).tag(layout)
                                    }
                                }

                                Picker("Bitrate", selection: $viewModel.selectedBitrateMode) {
                                    ForEach(BitrateMode.allCases, id: \.self) { mode in
                                        Text(mode.rawValue.capitalized).tag(mode)
                                    }
                                }
                            }

                            GridRow {
                                Picker("Resolution", selection: $viewModel.selectedResolutionPolicy) {
                                    Text("720p").tag(ResolutionPolicy.fixed720p)
                                    Text("1080p").tag(ResolutionPolicy.fixed1080p)
                                    Text("4K").tag(ResolutionPolicy.fixed4K)
                                    Text("Smart").tag(ResolutionPolicy.smart)
                                }

                                Picker("Frame Rate", selection: $viewModel.selectedFrameRatePolicy) {
                                    Text("30 fps").tag(FrameRatePolicy.fps30)
                                    Text("60 fps").tag(FrameRatePolicy.fps60)
                                    Text("Smart").tag(FrameRatePolicy.smart)
                                }
                            }

                            GridRow {
                                Picker("Still Images", selection: $viewModel.selectedStillImageProcessingMode) {
                                    ForEach(StillImageProcessingMode.allCases, id: \.self) { mode in
                                        Text(mode.displayLabel).tag(mode)
                                    }
                                }
                                Color.clear
                            }

                            GridRow {
                                Picker("Range", selection: $viewModel.selectedDynamicRange) {
                                    ForEach(DynamicRange.allCases, id: \.self) { range in
                                        Text(range.rawValue.uppercased()).tag(range)
                                    }
                                }
                                Color.clear
                            }
                        }

                        Picker("HDR HEVC Encoder", selection: $viewModel.selectedHDRHEVCEncoderMode) {
                            ForEach(HDRHEVCEncoderMode.allCases, id: \.self) { mode in
                                Text(mode.displayLabel).tag(mode)
                            }
                        }
                        .disabled(viewModel.selectedDynamicRange != .hdr)

                        if viewModel.isHDRSelectionLocked {
                            caption(viewModel.hdrSelectionLockReason)
                        }
                        caption(viewModel.ffmpegEngineDescription)
                        caption(viewModel.hdrHEVCEncoderDescription)
                        caption(viewModel.stillImageProcessingDescription)

                        VStack(alignment: .leading, spacing: 4) {
                            caption(viewModel.bitrateModeDescription)
                            caption(viewModel.frameRateDescription)
                            if let photosSmartFrameRateDescription = viewModel.photosSmartFrameRateDescription {
                                caption(photosSmartFrameRateDescription)
                            }
                            if let photosSmartAudioDescription = viewModel.photosSmartAudioDescription {
                                caption(photosSmartAudioDescription)
                            }
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Toggle("Write diagnostics log (.log)", isOn: $viewModel.writeDiagnosticsLog)
                                Spacer()
                                Button("Reset to Plex Defaults") {
                                    viewModel.resetExportSettingsToPlexDefaults()
                                }
                            }

                            VStack(alignment: .leading, spacing: rowSpacing) {
                                Toggle("Write diagnostics log (.log)", isOn: $viewModel.writeDiagnosticsLog)
                                Button("Reset to Plex Defaults") {
                                    viewModel.resetExportSettingsToPlexDefaults()
                                }
                            }
                        }
                    }
                }

                DisclosureGroup("Render Queue", isExpanded: $isRenderQueueExpanded) {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                Button("Add Current Settings") {
                                    viewModel.addCurrentSettingsToQueue()
                                }
                                .disabled(viewModel.isRendering)

                                Spacer(minLength: 0)

                                Button("Start Queue") {
                                    viewModel.startQueue()
                                }
                                .disabled(!viewModel.canStartQueue)

                                Button("Clear Queue") {
                                    viewModel.clearQueuedRenderJobs()
                                }
                                .disabled(!viewModel.canClearQueue)
                            }

                            VStack(alignment: .leading, spacing: rowSpacing) {
                                Button("Add Current Settings") {
                                    viewModel.addCurrentSettingsToQueue()
                                }
                                .disabled(viewModel.isRendering)

                                HStack(spacing: 10) {
                                    Button("Start Queue") {
                                        viewModel.startQueue()
                                    }
                                    .disabled(!viewModel.canStartQueue)

                                    Button("Clear Queue") {
                                        viewModel.clearQueuedRenderJobs()
                                    }
                                    .disabled(!viewModel.canClearQueue)
                                }
                            }
                        }

                        caption(viewModel.queueStatusDescription)

                        if viewModel.queuedRenderJobs.isEmpty {
                            caption("No queued renders yet.")
                        } else {
                            VStack(alignment: .leading, spacing: rowSpacing) {
                                ForEach(viewModel.queuedRenderJobs) { job in
                                    queueJobRow(job)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            sectionLabel("Export", accent: themeNavy)
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        if !viewModel.warnings.isEmpty {
            GroupBox {
                DisclosureGroup(isExpanded: $isNotesExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } label: {
                    sectionLabel("Notes & Warnings", accent: themeAmber)
                }
            }
        }
    }

    @ViewBuilder
    private var headerIconView: some View {
        #if canImport(AppKit)
        if let headerIconImage = AppMetadata.headerIconImage {
            Image(nsImage: headerIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .onTapGesture {
                    isHeaderEasterEggPresented = true
                }
                .popover(isPresented: $isHeaderEasterEggPresented, arrowEdge: .top) {
                    headerEasterEggPopover
                }
        } else {
            Color.clear
                .frame(width: 48, height: 48)
        }
        #else
        Color.clear
            .frame(width: 48, height: 48)
        #endif
    }

    @ViewBuilder
    private var statusArea: some View {
        if showsCompactIdleStatus {
            compactIdleStatus
        } else {
            statusSection
        }
    }

    private var statusSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: viewModel.progress)
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !viewModel.lastOutputPath.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        statusLine(title: "Output", value: viewModel.lastOutputPath)
                        Button("Open Render Folder") {
                            viewModel.openRenderedOutputFolder()
                        }
                    }
                }

                if !viewModel.lastDiagnosticsPath.isEmpty {
                    statusLine(title: "Diagnostics", value: viewModel.lastDiagnosticsPath)
                }

                if !viewModel.lastBackendSummary.isEmpty {
                    statusLine(title: "Backend", value: viewModel.lastBackendSummary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            sectionLabel("Status", accent: themeNavy)
        }
    }

    private var actionRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Pause After Checkpoint") {
                viewModel.pauseRender()
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canPauseRender)

            Button("Cancel") {
                viewModel.cancelRender()
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.isRendering)

            Button("Generate Video") {
                viewModel.startRender()
            }
            .buttonStyle(.borderedProminent)
            .tint(themePeach)
            .disabled(viewModel.isRendering)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        displayValue: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 120, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(displayValue)
                .frame(width: 56, alignment: .trailing)
                .monospacedDigit()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func queueJobRow(_ job: MainWindowViewModel.QueuedRenderJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text(job.state.displayLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(queueStateColor(job.state), in: Capsule())

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.sourceSummary)
                        .font(.subheadline)
                    caption("Output: \(job.outputNamePreview)")
                }

                Spacer(minLength: 8)

                if job.state != .running {
                    Button("Remove") {
                        viewModel.removeQueuedRenderJob(id: job.id)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if !job.lastResultMessage.isEmpty {
                caption(job.lastResultMessage)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(windowBackgroundColor.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(queueStateColor(job.state).opacity(0.2), lineWidth: 1)
        )
    }

    private var showsCompactIdleStatus: Bool {
        !viewModel.isRendering &&
        viewModel.statusMessage == "Idle" &&
        viewModel.lastOutputPath.isEmpty &&
        viewModel.lastDiagnosticsPath.isEmpty &&
        viewModel.lastBackendSummary.isEmpty
    }

    private var compactIdleStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(themeTeal.opacity(0.85))
                .frame(width: 8, height: 8)

            Text("Status: Idle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var appBackgroundLayer: some View {
        ZStack {
            windowBackgroundColor
            LinearGradient(
                colors: [
                    themeTeal.opacity(0.14),
                    themeNavy.opacity(0.10),
                    themePeach.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var windowBackgroundColor: Color {
        #if canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.white
        #endif
    }

    private var themeTeal: Color {
        Color(red: 0.12, green: 0.56, blue: 0.58)
    }

    private var themeNavy: Color {
        Color(red: 0.15, green: 0.24, blue: 0.46)
    }

    private var themePeach: Color {
        Color(red: 0.94, green: 0.63, blue: 0.43)
    }

    private var themeAmber: Color {
        Color(red: 0.74, green: 0.58, blue: 0.29)
    }

    private func queueStateColor(_ state: MainWindowViewModel.QueuedRenderJobState) -> Color {
        switch state {
        case .queued:
            return themeNavy
        case .running:
            return themeTeal
        case .paused:
            return themeAmber
        case .completed:
            return Color.green.opacity(0.8)
        case .failed:
            return Color.red.opacity(0.8)
        }
    }

    private func sectionLabel(_ title: String, accent: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accent)
                .frame(width: 8, height: 18)

            Text(title)
                .font(.headline)
                .foregroundStyle(accent)
        }
    }

    @ViewBuilder
    private var headerEasterEggPopover: some View {
        VStack(alignment: .center, spacing: 12) {
            #if canImport(AppKit)
            if let easterEggImage = AppMetadata.easterEggImage {
                Image(nsImage: easterEggImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            #endif

            Text("Vibecoded (poorly) by John Kenneth Fisher, 2026.")
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .frame(width: 220)
        .padding(16)
    }

    private func statusLine(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(title):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
