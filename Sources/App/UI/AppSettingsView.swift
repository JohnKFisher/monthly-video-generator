import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var shellPreferences: AppShellPreferencesStore
    private let folderSelector: FolderSelecting

    @AppStorage(AppShellPreferenceKeys.showAdvancedExportSettingsByDefault)
    private var showAdvancedExportSettingsByDefault = false

    @AppStorage(AppShellPreferenceKeys.showRenderQueueByDefault)
    private var showRenderQueueByDefault = true

    @AppStorage(AppShellPreferenceKeys.showWarningsExpandedByDefault)
    private var showWarningsExpandedByDefault = true

    init(
        shellPreferences: AppShellPreferencesStore,
        folderSelector: FolderSelecting = OpenPanelFolderSelector()
    ) {
        self.shellPreferences = shellPreferences
        self.folderSelector = folderSelector
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
        }
        .frame(width: 520, height: 320)
        .scenePadding()
    }

    private var generalTab: some View {
        Form {
            Section("Default Output Folder") {
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

            Section("Window Defaults") {
                Toggle("Expand Advanced Export Settings by default", isOn: $showAdvancedExportSettingsByDefault)
                Toggle("Show Render Queue by default", isOn: $showRenderQueueByDefault)
                Toggle("Expand Notes & Warnings by default", isOn: $showWarningsExpandedByDefault)
            }
        }
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
