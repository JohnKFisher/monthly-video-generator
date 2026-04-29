import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var shellPreferences: AppShellPreferencesStore
    @ObservedObject var viewModel: MainWindowViewModel
    private let folderSelector: FolderSelecting

    init(
        shellPreferences: AppShellPreferencesStore,
        viewModel: MainWindowViewModel,
        folderSelector: FolderSelecting = OpenPanelFolderSelector()
    ) {
        self.shellPreferences = shellPreferences
        self.viewModel = viewModel
        self.folderSelector = folderSelector
    }

    var body: some View {
        TabView {
            styleTab
                .tabItem {
                    Label("Style", systemImage: "paintpalette")
                }

            exportTab
                .tabItem {
                    Label("Export", systemImage: "film")
                }

            generalTab
                .tabItem {
                    Label("App", systemImage: "gearshape")
                }
        }
        .frame(width: 600, height: 420)
    }

    private var styleTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSection("Opening Title") {
                Toggle("Include opening title card", isOn: $viewModel.includeOpeningTitle)

                MainWindowSliderRow(
                    title: "Title card duration",
                    value: $viewModel.titleDurationSeconds,
                    range: 1...20,
                    step: 0.25,
                    displayValue: String(format: "%.2fs", viewModel.titleDurationSeconds)
                )
                .disabled(!viewModel.includeOpeningTitle)

                Toggle("Show capture date", isOn: $viewModel.showCaptureDateOverlay)

                Text("Defaults are optimized for Plex + Infuse on Apple TV 4K.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsSection("Timing") {
                MainWindowSliderRow(
                    title: "Crossfade",
                    value: $viewModel.crossfadeDurationSeconds,
                    range: 0...2,
                    step: 0.05,
                    displayValue: String(format: "%.2fs", viewModel.crossfadeDurationSeconds)
                )

                MainWindowSliderRow(
                    title: "Still image duration",
                    value: $viewModel.stillImageDurationSeconds,
                    range: 1...10,
                    step: 0.25,
                    displayValue: String(format: "%.2fs", viewModel.stillImageDurationSeconds)
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var exportTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Advanced Export")
                    .font(.headline)

                MainWindowAdvancedExportSettingsView(viewModel: viewModel)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSection("Default Output Folder") {
                Text(shellPreferences.defaultOutputDirectoryURL.path)
                    .font(.callout)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Choose Default Output Folder…") {
                        chooseDefaultOutputFolder()
                    }

                    Button("Reset Default Folder") {
                        shellPreferences.resetDefaultOutputDirectory()
                    }
                }

                Text("This folder becomes the launch default and is updated when you choose a new output folder in the main window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsSection("Window Defaults") {
                Text("The job drawer is always visible on the main screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Notes & Warnings stay minimized until opened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseDefaultOutputFolder() {
        let selectedURL = folderSelector.chooseFolder(
            title: "Select Default Output Folder",
            prompt: "Choose",
            initialDirectoryURL: shellPreferences.defaultOutputDirectoryURL
        )
        guard let selectedURL else {
            return
        }

        shellPreferences.setDefaultOutputDirectory(selectedURL)
    }
}
