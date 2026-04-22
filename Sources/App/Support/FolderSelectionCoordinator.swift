import Foundation
#if canImport(AppKit)
import AppKit
#endif

protocol FolderSelecting {
    @MainActor
    func chooseFolder(
        title: String,
        prompt: String,
        initialDirectoryURL: URL?
    ) -> URL?
}

struct OpenPanelFolderSelector: FolderSelecting {
    @MainActor
    func chooseFolder(
        title: String,
        prompt: String,
        initialDirectoryURL: URL?
    ) -> URL? {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.title = title
        panel.directoryURL = initialDirectoryURL

        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url
        #else
        return nil
        #endif
    }
}
