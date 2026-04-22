import SwiftUI

struct MainWindowStatusPane: View {
    @ObservedObject var viewModel: MainWindowViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Version \(AppMetadata.versionBuildValue)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if viewModel.canRevealLastRenderedOutput {
                        Button("Reveal Last Export") {
                            viewModel.revealLastRenderedOutput()
                        }
                    }
                }

                ProgressView(value: viewModel.progress)

                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !viewModel.lastOutputPath.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        MainWindowStatusLine(title: "Output", value: viewModel.lastOutputPath)

                        Button("Reveal Folder") {
                            viewModel.openRenderedOutputFolder()
                        }
                    }
                }

                if !viewModel.lastDiagnosticsPath.isEmpty {
                    MainWindowStatusLine(title: "Diagnostics", value: viewModel.lastDiagnosticsPath)
                }

                if !viewModel.lastBackendSummary.isEmpty {
                    MainWindowStatusLine(title: "Backend", value: viewModel.lastBackendSummary)
                }

                Divider()

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
                    .tint(MainWindowTheme.accentPeach)
                    .disabled(!viewModel.canStartRender)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            MainWindowSectionLabel(title: "Status", accent: MainWindowTheme.accentTeal)
        }
    }
}
