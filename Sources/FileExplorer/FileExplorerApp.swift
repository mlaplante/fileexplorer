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
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            Task { await appState.pane.goBack() }
                        } label: { Image(systemName: "chevron.left") }
                        .disabled(!appState.pane.canGoBack)
                        .help("Back")

                        Button {
                            Task { await appState.pane.goForward() }
                        } label: { Image(systemName: "chevron.right") }
                        .disabled(!appState.pane.canGoForward)
                        .help("Forward")

                        Button {
                            Task { await appState.pane.goUp() }
                        } label: { Image(systemName: "chevron.up") }
                        .disabled(!appState.pane.canGoUp)
                        .help("Enclosing Folder")
                    }
                }
        }
        .commands {
            CommandMenu("Go") {
                Button("Back") { Task { await appState.pane.goBack() } }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!appState.pane.canGoBack)
                Button("Forward") { Task { await appState.pane.goForward() } }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!appState.pane.canGoForward)
                Button("Enclosing Folder") { Task { await appState.pane.goUp() } }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!appState.pane.canGoUp)
                Divider()
                Button("Home") {
                    Task {
                        await appState.pane.navigate(
                            to: FileManager.default.homeDirectoryForCurrentUser)
                    }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
    }
}
