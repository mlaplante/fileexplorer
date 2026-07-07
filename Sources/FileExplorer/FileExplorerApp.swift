import SwiftUI

@main
struct FileExplorerApp: App {
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
            Text("FileExplorer")
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}
