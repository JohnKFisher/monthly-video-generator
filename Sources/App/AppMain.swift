import SwiftUI

@main
struct MonthlyVideoGeneratorApp: App {
    @StateObject private var shellPreferences: AppShellPreferencesStore
    @StateObject private var mainWindowViewModel: MainWindowViewModel

    init() {
        let shellPreferences = AppShellPreferencesStore()
        _shellPreferences = StateObject(wrappedValue: shellPreferences)
        _mainWindowViewModel = StateObject(
            wrappedValue: MainWindowViewModel(shellPreferences: shellPreferences)
        )
    }

    var body: some Scene {
        WindowGroup(AppMetadata.appName, id: AppSceneID.mainWindow) {
            MainWindowView(viewModel: mainWindowViewModel)
        }
        .defaultSize(width: 1240, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            MainWindowCommands(viewModel: mainWindowViewModel)
        }

        Window("About \(AppMetadata.appName)", id: AppSceneID.aboutWindow) {
            AboutWindowView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            AppSettingsView(
                shellPreferences: shellPreferences,
                viewModel: mainWindowViewModel
            )
        }
    }
}
