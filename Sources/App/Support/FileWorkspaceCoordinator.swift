import Foundation
#if canImport(AppKit)
import AppKit
#endif

protocol FileWorkspaceOpening {
    @MainActor
    func open(_ url: URL)
    @MainActor
    func reveal(_ url: URL)
}

struct AppKitWorkspaceCoordinator: FileWorkspaceOpening {
    @MainActor
    func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    @MainActor
    func reveal(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}
