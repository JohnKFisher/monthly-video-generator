import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: MainWindowViewModel

    @SceneStorage("MainWindowView.isNotesExpanded")
    private var isNotesExpanded = false

    @SceneStorage("MainWindowView.hasAppliedSceneDefaults")
    private var hasAppliedSceneDefaults = false

    private let sectionSpacing: CGFloat = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sectionSpacing) {
                MainWindowLightTablePane(viewModel: viewModel)

                if viewModel.usesFocusedRunLayout {
                    MainWindowQueuePane(viewModel: viewModel)
                } else {
                    if viewModel.hasQueuedJobs {
                        MainWindowQueuePane(viewModel: viewModel)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: sectionSpacing) {
                            workflowPane
                            exportPane
                        }

                        VStack(alignment: .leading, spacing: sectionSpacing) {
                            workflowPane
                            exportPane
                        }
                    }

                    if !viewModel.hasQueuedJobs {
                        MainWindowQueuePane(viewModel: viewModel)
                    }
                }

                MainWindowWarningsPane(
                    viewModel: viewModel,
                    isExpanded: $isNotesExpanded
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 1060, minHeight: 700)
        .tint(MainWindowTheme.accentTeal)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Source", selection: $viewModel.sourceMode) {
                    ForEach(MainWindowViewModel.SourceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    viewModel.chooseInputFolder()
                } label: {
                    Label("Choose Source Folder", systemImage: "folder.badge.plus")
                }
                .disabled(!viewModel.canChooseInputFolder)

                Button {
                    viewModel.chooseOutputFolder()
                } label: {
                    Label("Choose Output Folder", systemImage: "folder")
                }
                .disabled(!viewModel.canChooseOutputFolder)

                Button {
                    viewModel.openConfiguredOutputFolder()
                } label: {
                    Label("Reveal Output Folder", systemImage: "folder.fill")
                }
                .disabled(!viewModel.canOpenConfiguredOutputFolder)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewModel.cancelRender()
                } label: {
                    Label("Cancel Render", systemImage: "xmark.circle")
                }
                .disabled(!viewModel.isRendering)

                Button {
                    viewModel.startRender()
                } label: {
                    Label("Generate Video", systemImage: "play.circle.fill")
                }
                .disabled(!viewModel.canStartRender)
            }
        }
        .onAppear {
            applySceneDefaultsIfNeeded()
        }
        .alert(viewModel.renderCompleteAlertTitle, isPresented: $viewModel.showRenderCompleteAlert) {
            Button("Reveal Last Export") {
                viewModel.revealLastRenderedOutput()
            }
            .disabled(!viewModel.canRevealLastRenderedOutput)

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

    private func applySceneDefaultsIfNeeded() {
        guard !hasAppliedSceneDefaults else {
            return
        }

        isNotesExpanded = false
        hasAppliedSceneDefaults = true
    }

    private var workflowPane: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            MainWindowInputPane(viewModel: viewModel)
            MainWindowStylePane(viewModel: viewModel)
            MainWindowSettingsSummaryPane(viewModel: viewModel)
        }
        .frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
    }

    private var exportPane: some View {
        MainWindowExportPane(viewModel: viewModel)
            .frame(minWidth: 520, maxWidth: .infinity, alignment: .topLeading)
    }
}
