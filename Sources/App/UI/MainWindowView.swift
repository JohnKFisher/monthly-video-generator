import SwiftUI

struct MainWindowView: View {
    @ObservedObject var viewModel: MainWindowViewModel

    @AppStorage(AppShellPreferenceKeys.showRenderQueueByDefault)
    private var showRenderQueueByDefault = true

    @SceneStorage("MainWindowView.isRenderQueueExpanded")
    private var isRenderQueueExpanded = false

    @SceneStorage("MainWindowView.isNotesExpanded")
    private var isNotesExpanded = false

    @SceneStorage("MainWindowView.hasAppliedSceneDefaults")
    private var hasAppliedSceneDefaults = false

    private let sectionSpacing: CGFloat = 10

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    MainWindowInputPane(viewModel: viewModel)
                    MainWindowStylePane(viewModel: viewModel)
                    MainWindowSettingsSummaryPane(viewModel: viewModel)
                    MainWindowExportPane(viewModel: viewModel)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    MainWindowStatusPane(viewModel: viewModel)
                    MainWindowQueuePane(
                        viewModel: viewModel,
                        isRenderQueueExpanded: $isRenderQueueExpanded
                    )
                    MainWindowWarningsPane(
                        viewModel: viewModel,
                        isExpanded: $isNotesExpanded
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 340, idealWidth: 420, maxWidth: 500)
        }
        .frame(minWidth: 1020, minHeight: 660)
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

        isRenderQueueExpanded = showRenderQueueByDefault
        isNotesExpanded = false
        hasAppliedSceneDefaults = true
    }
}
