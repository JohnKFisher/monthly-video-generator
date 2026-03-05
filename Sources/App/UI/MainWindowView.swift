import Core
import SwiftUI

struct MainWindowView: View {
    @StateObject private var viewModel = MainWindowViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Monthly Video Generator")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(viewModel.appVersionBuildLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Source", selection: $viewModel.sourceMode) {
                ForEach(MainWindowViewModel.SourceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            GroupBox("Input") {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.sourceMode == .folder {
                        HStack {
                            Text(viewModel.selectedFolderURL?.path ?? "No folder selected")
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Choose Folder") {
                                viewModel.chooseInputFolder()
                            }
                        }

                        Toggle("Scan subfolders recursively", isOn: $viewModel.recursiveScan)
                    } else {
                        HStack {
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
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Style") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Opening title card", isOn: $viewModel.includeOpeningTitle)

                    if viewModel.includeOpeningTitle {
                        TextField("Title text", text: $viewModel.openingTitleText)
                        Text("If left blank, uses the selected month/year label.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Crossfade")
                        Slider(value: $viewModel.crossfadeDurationSeconds, in: 0...2, step: 0.05)
                        Text(String(format: "%.2fs", viewModel.crossfadeDurationSeconds))
                            .monospacedDigit()
                    }

                    HStack {
                        Text("Still image duration")
                        Slider(value: $viewModel.stillImageDurationSeconds, in: 1...10, step: 0.25)
                        Text(String(format: "%.2fs", viewModel.stillImageDurationSeconds))
                            .monospacedDigit()
                    }
                }
            }

            GroupBox("Export") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
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

                    HStack {
                        Picker("Resolution", selection: $viewModel.selectedResolutionPolicy) {
                            Text("Match Source").tag(ResolutionPolicy.matchSourceMax)
                            Text("1080p").tag(ResolutionPolicy.fixed1080p)
                            Text("4K").tag(ResolutionPolicy.fixed4K)
                        }

                        Picker("Range", selection: $viewModel.selectedDynamicRange) {
                            ForEach(DynamicRange.allCases, id: \.self) { range in
                                Text(range.rawValue.uppercased()).tag(range)
                            }
                        }
                    }

                    if viewModel.selectedDynamicRange == .hdr {
                        Picker("HDR Engine", selection: $viewModel.selectedHDRBinaryMode) {
                            Text("Auto (System then Bundled)").tag(HDRFFmpegBinaryMode.autoSystemThenBundled)
                            Text("System Only").tag(HDRFFmpegBinaryMode.systemOnly)
                            Text("Bundled Only").tag(HDRFFmpegBinaryMode.bundledOnly)
                        }
                    }

                    HStack {
                        Picker("Audio", selection: $viewModel.selectedAudioLayout) {
                            ForEach(AudioLayout.allCases, id: \.self) { layout in
                                Text(layout == .stereo ? "Stereo" : "5.1").tag(layout)
                            }
                        }
                        .disabled(viewModel.isHDRSelectionLocked)

                        Picker("Bitrate", selection: $viewModel.selectedBitrateMode) {
                            ForEach(BitrateMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                    }

                    if viewModel.isHDRSelectionLocked {
                        Text(viewModel.hdrSelectionLockReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(viewModel.bitrateModeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Write diagnostics log (.log)", isOn: $viewModel.writeDiagnosticsLog)

                    HStack {
                        TextField("Output name", text: $viewModel.outputFilename)
                        Text(viewModel.outputDirectoryURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Output Folder") {
                            viewModel.chooseOutputFolder()
                        }
                    }

                    Button("Reset to Plex Defaults") {
                        viewModel.resetExportSettingsToPlexDefaults()
                    }
                }
            }

            if !viewModel.warnings.isEmpty {
                GroupBox("Warnings") {
                    VStack(alignment: .leading) {
                        ForEach(viewModel.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: viewModel.progress)
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !viewModel.lastOutputPath.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Text(viewModel.lastOutputPath)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open Render Folder") {
                            viewModel.openRenderedOutputFolder()
                        }
                    }
                }
                if !viewModel.lastDiagnosticsPath.isEmpty {
                    Text("Diagnostics log: \(viewModel.lastDiagnosticsPath)")
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !viewModel.lastBackendSummary.isEmpty {
                    Text("Render backend: \(viewModel.lastBackendSummary)")
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

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
        .padding(20)
        .frame(minWidth: 860, minHeight: 760)
        .alert("Render Complete", isPresented: $viewModel.showRenderCompleteAlert) {
            Button("Open Folder") {
                viewModel.openRenderedOutputFolder()
            }
            Button("OK", role: .cancel) {}
        } message: {
            if viewModel.lastOutputPath.isEmpty {
                Text("The slideshow was exported successfully.")
            } else {
                Text(viewModel.lastOutputPath)
            }
        }
    }
}
