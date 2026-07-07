import SwiftUI
import FileExplorerCore

@main
struct FileExplorerApp: App {
    private let session: SessionState = {
        let arguments = CommandLine.arguments.dropFirst()
        if let path = arguments.first {
            var isDirectory: ObjCBool = false
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded,
                                              isDirectory: &isDirectory),
               isDirectory.boolValue {
                return SessionState(url: URL(fileURLWithPath: expanded))
            }
        }
        return SessionState(
            url: FileManager.default.homeDirectoryForCurrentUser)
    }()
    private let palette = PaletteModel()
    private let renameModel = RenameSheetModel()
    private let batchRenameModel = BatchRenameModel()

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
                    TabContentView(session: session, renameModel: renameModel,
                                   batchRenameModel: batchRenameModel)
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
            .sheet(isPresented: Binding(
                get: { renameModel.isPresented },
                set: { if !$0 { renameModel.dismiss() } })) {
                RenameSheet(model: renameModel) { url, newName in
                    Task { await session.activePane.renameSelected(url, to: newName) }
                }
            }
            .sheet(isPresented: Binding(
                get: { batchRenameModel.isPresented },
                set: { if !$0 { batchRenameModel.dismiss() } })) {
                BatchRenameSheet(model: batchRenameModel) { targets, rules in
                    Task { await session.activePane.batchRename(targets, rules: rules) }
                }
            }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open") {
                    Task {
                        await session.activePane.openSelection {
                            NSWorkspace.shared.open($0)
                        }
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(session.activePane.selection.isEmpty)
                Button("New Folder") {
                    Task { await session.activePane.createNewFolder() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Rename…") {
                    if let url = session.activePane.selection.first,
                       session.activePane.selection.count == 1 {
                        renameModel.present(for: url)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(session.activePane.selection.count != 1)
                Button("Move to Trash") {
                    let targets = Array(session.activePane.selection)
                    guard !targets.isEmpty else { return }
                    Task { await session.activePane.trashSelected(targets) }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                Divider()
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
                Picker("View", selection: Binding(
                    get: { session.activePane.viewMode },
                    set: { session.activePane.viewMode = $0 })) {
                    Text("as List").tag(PaneState.ViewMode.list)
                        .keyboardShortcut("1", modifiers: [.command, .option])
                    Text("as Icons").tag(PaneState.ViewMode.icons)
                        .keyboardShortcut("2", modifiers: [.command, .option])
                }
                .pickerStyle(.inline)
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
