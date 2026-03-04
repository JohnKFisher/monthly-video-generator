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

                    HStack {
                        Picker("Audio", selection: $viewModel.selectedAudioLayout) {
                            ForEach(AudioLayout.allCases, id: \.self) { layout in
                                Text(layout == .stereo ? "Stereo" : "5.1").tag(layout)
                            }
                        }

                        Picker("Bitrate", selection: $viewModel.selectedBitrateMode) {
                            ForEach(BitrateMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                    }

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
                    Text(viewModel.lastOutputPath)
                        .font(.caption)
                        .textSelection(.enabled)
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
    }
}
