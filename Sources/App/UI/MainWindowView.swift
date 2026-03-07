import Core
import SwiftUI

struct MainWindowView: View {
    @StateObject private var viewModel = MainWindowViewModel()
    private let sectionSpacing: CGFloat = 12
    private let rowSpacing: CGFloat = 8

    var body: some View {
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
                    statusSection
                    actionRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .frame(minWidth: 920, minHeight: 700)
        .alert("Render Complete", isPresented: $viewModel.showRenderCompleteAlert) {
            Button("Open Folder") {
                viewModel.openRenderedOutputFolder()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.renderCompleteAlertMessage)
        }
    }

    private var headerBar: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Monthly Video Generator")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(viewModel.appVersionBuildLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Picker("Source", selection: $viewModel.sourceMode) {
                ForEach(MainWindowViewModel.SourceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
        }
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
            megaTestSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var inputSection: some View {
        GroupBox("Input") {
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
                                    Text(String(month)).tag(month)
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
        }
    }

    private var styleSection: some View {
        GroupBox("Style") {
            VStack(alignment: .leading, spacing: rowSpacing) {
                Toggle("Opening title card", isOn: $viewModel.includeOpeningTitle)

                if viewModel.includeOpeningTitle {
                    TextField("Title text", text: $viewModel.openingTitleText)
                    caption("If left blank, uses the selected month/year label. The opener now animates a small collage from upcoming media and may modestly increase export time.")

                    sliderRow(
                        title: "Title card duration",
                        value: $viewModel.titleDurationSeconds,
                        range: 1...10,
                        step: 0.25,
                        displayValue: String(format: "%.2fs", viewModel.titleDurationSeconds)
                    )

                    Picker("Small caption", selection: $viewModel.openingTitleCaptionMode) {
                        ForEach(OpeningTitleCaptionMode.allCases, id: \.self) { mode in
                            Text(mode.displayLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if viewModel.openingTitleCaptionMode == .custom {
                        TextField("Caption text", text: $viewModel.openingTitleCaptionText)
                        caption("Leave blank to hide the smaller caption.")
                    } else {
                        caption("Automatic uses the current album title, month/year label, or date span when available.")
                    }
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
        }
    }

    private var exportSection: some View {
        GroupBox("Export") {
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
                        Picker("Range", selection: $viewModel.selectedDynamicRange) {
                            ForEach(DynamicRange.allCases, id: \.self) { range in
                                Text(range.rawValue.uppercased()).tag(range)
                            }
                        }
                        Color.clear
                    }
                }

                Picker("FFmpeg Engine", selection: $viewModel.selectedHDRBinaryMode) {
                    Text("Auto (System then Bundled)").tag(HDRFFmpegBinaryMode.autoSystemThenBundled)
                    Text("System Only").tag(HDRFFmpegBinaryMode.systemOnly)
                    Text("Bundled Only").tag(HDRFFmpegBinaryMode.bundledOnly)
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
                caption(viewModel.hdrHEVCEncoderDescription)

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
                    HStack(spacing: 10) {
                        TextField("Output name", text: $viewModel.outputFilename)
                        Button(viewModel.isOutputNameAutoManaged ? "Regenerate" : "Use Auto Name") {
                            viewModel.useAutoGeneratedOutputName()
                        }
                        Button("Output Folder") {
                            viewModel.chooseOutputFolder()
                        }
                    }

                    VStack(alignment: .leading, spacing: rowSpacing) {
                        TextField("Output name", text: $viewModel.outputFilename)
                        HStack(spacing: 10) {
                            Button(viewModel.isOutputNameAutoManaged ? "Regenerate" : "Use Auto Name") {
                                viewModel.useAutoGeneratedOutputName()
                            }
                            Button("Output Folder") {
                                viewModel.chooseOutputFolder()
                            }
                        }
                    }
                }

                caption(viewModel.outputDirectoryURL.path)
                    .lineLimit(1)

                caption(
                    viewModel.isOutputNameAutoManaged
                    ? "Temporary testing name stays in sync with Resolution, FPS, Range, and Audio until you edit it."
                    : "Manual output name override is active. Use “Use Auto Name” to restore the temporary testing name."
                )

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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var megaTestSection: some View {
        GroupBox("Mega Test") {
            VStack(alignment: .leading, spacing: rowSpacing) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        Toggle("Resolution", isOn: $viewModel.megaTestVaryResolution)
                        Toggle("FPS", isOn: $viewModel.megaTestVaryFrameRate)
                        Toggle("Range", isOn: $viewModel.megaTestVaryRange)
                        Toggle("Audio", isOn: $viewModel.megaTestVaryAudio)
                        Spacer()
                        Button("Run Mega Test") {
                            viewModel.startMegaTest()
                        }
                        .disabled(viewModel.isRendering)
                    }

                    VStack(alignment: .leading, spacing: rowSpacing) {
                        HStack(spacing: 16) {
                            Toggle("Resolution", isOn: $viewModel.megaTestVaryResolution)
                            Toggle("FPS", isOn: $viewModel.megaTestVaryFrameRate)
                            Toggle("Range", isOn: $viewModel.megaTestVaryRange)
                            Toggle("Audio", isOn: $viewModel.megaTestVaryAudio)
                        }
                        Button("Run Mega Test") {
                            viewModel.startMegaTest()
                        }
                        .disabled(viewModel.isRendering)
                    }
                }

                caption("\(viewModel.megaTestCombinationCountDescription) will be rendered sequentially.")
                caption("Mega test always uses the temporary generated testing filename for each combination and ignores the single-render Output name field.")
                if let megaTestHDRHEVCEncoderDescription = viewModel.megaTestHDRHEVCEncoderDescription {
                    caption(megaTestHDRHEVCEncoderDescription)
                }
                if let megaTestPhotosSmartAudioDescription = viewModel.megaTestPhotosSmartAudioDescription {
                    caption(megaTestPhotosSmartAudioDescription)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(
            "Mega Test Failed",
            isPresented: Binding(
                get: { viewModel.pendingMegaTestFailure != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.stopMegaTestAfterFailure()
                    }
                }
            )
        ) {
            Button("Continue Remaining") {
                viewModel.continueMegaTestAfterFailure()
            }
            Button("Stop Mega Test", role: .destructive) {
                viewModel.stopMegaTestAfterFailure()
            }
        } message: {
            Text(viewModel.pendingMegaTestFailure?.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        if !viewModel.warnings.isEmpty {
            GroupBox("Warnings") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.warnings, id: \.self) { warning in
                        Text("• \(warning)")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var statusSection: some View {
        GroupBox("Status") {
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
        }
    }

    private var actionRow: some View {
        HStack {
            Button("Generate Video") {
                viewModel.startRender()
            }
            .disabled(viewModel.isRendering)

            Button("Cancel") {
                viewModel.cancelRender()
            }
            .disabled(!viewModel.isRendering)
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
