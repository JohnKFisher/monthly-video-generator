import SwiftUI

struct MainWindowCommands: Commands {
    @ObservedObject var viewModel: MainWindowViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppMetadata.appName)") {
                openWindow(id: AppSceneID.aboutWindow)
            }
        }

        CommandGroup(after: .newItem) {
            Button("Choose Source Folder…") {
                viewModel.chooseInputFolder()
            }
            .keyboardShortcut("o")
            .disabled(!viewModel.canChooseInputFolder)

            Button("Choose Output Folder…") {
                viewModel.chooseOutputFolder()
            }
            .keyboardShortcut("O", modifiers: [.command, .shift])
            .disabled(!viewModel.canChooseOutputFolder)

            Divider()

            Button("Reveal Output Folder") {
                viewModel.openConfiguredOutputFolder()
            }
            .disabled(!viewModel.canOpenConfiguredOutputFolder)

            Button("Reveal Last Export") {
                viewModel.revealLastRenderedOutput()
            }
            .keyboardShortcut("R", modifiers: [.command, .shift])
            .disabled(!viewModel.canRevealLastRenderedOutput)
        }

        CommandMenu("Render") {
            Button("Generate Video") {
                viewModel.startRender()
            }
            .keyboardShortcut("r")
            .disabled(!viewModel.canStartRender)

            Button("Cancel Render") {
                viewModel.cancelRender()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!viewModel.isRendering)

            Button(viewModel.addCurrentSettingsToQueueLabel) {
                viewModel.addCurrentSettingsToQueue()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!viewModel.canAddCurrentSettingsToQueue)

            if viewModel.showsSelectedYearQueueAction {
                Button("Add Full Year") {
                    viewModel.addSelectedYearToQueue()
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(!viewModel.canAddSelectedYearToQueue)
            }

            Button("Start Queue") {
                viewModel.startQueue()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift, .option])
            .disabled(!viewModel.canStartQueue)

            Button("Clear Queue") {
                viewModel.clearQueuedRenderJobs()
            }
            .disabled(!viewModel.canClearQueue)

            Divider()

            Button("Reset Style & Export to Plex Defaults") {
                viewModel.resetStyleAndExportSettingsToPlexDefaults()
            }
            .disabled(!viewModel.canResetExportSettings)
        }

        CommandGroup(after: .help) {
            if let repositoryURL = AppMetadata.repositoryURL {
                Button("Monthly Video Generator on GitHub") {
                    openURL(repositoryURL)
                }
            }
        }
    }
}
