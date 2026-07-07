import SwiftUI
import FileExplorerCore

@main
struct FileExplorerApp: App {
    private let appState = AppState()

    init() {
        // When launched from `swift run` (no bundle), become a regular
        // foreground app so the window appears and takes focus.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            PaneView(pane: appState.pane)
                .frame(minWidth: 600, minHeight: 400)
                .navigationTitle(appState.pane.currentURL.lastPathComponent)
        }
    }
}
