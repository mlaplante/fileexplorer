import SwiftUI
import FileExplorerCore

@main
struct FileExplorerApp: App {
    private let session = SessionState(
        url: FileManager.default.homeDirectoryForCurrentUser)
    private let palette = PaletteModel()

    init() {
        // When launched from `swift run` (no bundle), become a regular
        // foreground app so the window appears and takes focus.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        Window("FileExplorer", id: "main") {
            ZStack(alignment: .top) {
                NavigationSplitView {
                    SidebarView(session: session)
                        .navigationSplitViewColumnWidth(min: 160, ideal: 200)
                } detail: {
                    TabContentView(session: session)
                        .navigationTitle(session.activePane.currentURL.lastPathComponent)
                        .toolbar {
                            ToolbarItemGroup(placement: .navigation) {
                                Button {
                                    Task { await session.activePane.goBack() }
                                } label: { Image(systemName: "chevron.left") }
                                .disabled(!session.activePane.canGoBack)
                                .help("Back")

                                Button {
                                    Task { await session.activePane.goForward() }
                                } label: { Image(systemName: "chevron.right") }
                                .disabled(!session.activePane.canGoForward)
                                .help("Forward")

                                Button {
                                    Task { await session.activePane.goUp() }
                                } label: { Image(systemName: "chevron.up") }
                                .disabled(!session.activePane.canGoUp)
                                .help("Enclosing Folder")
                            }
                        }
                }

                if palette.isPresented {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                        .onTapGesture { palette.dismiss() }
                    PaletteOverlayView(palette: palette) { item in
                        PaletteCoordinator.confirm(item, palette: palette,
                                                   session: session)
                    }
                    .padding(.top, 60)
                }
            }
            .frame(minWidth: 760, minHeight: 400)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { session.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { session.closeTab(at: session.activeTabIndex) }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(session.tabs.count == 1)
            }
            CommandMenu("Go") {
                Button("Back") { Task { await session.activePane.goBack() } }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!session.activePane.canGoBack)
                Button("Forward") { Task { await session.activePane.goForward() } }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!session.activePane.canGoForward)
                Button("Enclosing Folder") { Task { await session.activePane.goUp() } }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!session.activePane.canGoUp)
                Divider()
                Button("Home") {
                    Task {
                        await session.activePane.navigate(
                            to: FileManager.default.homeDirectoryForCurrentUser)
                    }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("Go to Folder…") {
                    PaletteCoordinator.openFolders(palette, session: session)
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("Find File…") {
                    PaletteCoordinator.openFiles(palette, session: session)
                }
                .keyboardShortcut("p", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Hidden Files", isOn: Binding(
                    get: { session.activePane.showHidden },
                    set: { newValue in
                        session.activePane.showHidden = newValue
                        Task { await session.activePane.reload() }
                    }))
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Toggle Dual Pane") { session.activeTab.toggleDual() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Quick Look") {
                    QuickLookController.shared.toggle(for: session.activePane)
                }
                .keyboardShortcut("y", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Command Palette…") {
                    PaletteCoordinator.openCommands(palette, session: session)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandGroup(before: .windowList) {
                ForEach(1...9, id: \.self) { number in
                    Button("Tab \(number)") { session.selectTab(number - 1) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(number)")), modifiers: .command)
                        .disabled(session.tabs.count < number)
                }
            }
        }
    }
}
