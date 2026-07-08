import SwiftUI
import FileExplorerCore

@main
struct FileExplorerApp: App {
    private let session: SessionState
    private let autosaver: SessionAutosaver
    private let palette = PaletteModel()
    private let renameModel = RenameSheetModel()
    private let batchRenameModel = BatchRenameModel()
    private let volumesModel = VolumesModel()
    private let settings: SettingsModel
    private let infoModel = GetInfoModel()

    init() {
        let persister = SessionPersister(
            directory: SessionPersister.defaultDirectory)
        let settings = SettingsModel(persister: persister)
        self.settings = settings
        let home = FileManager.default.homeDirectoryForCurrentUser
        let session: SessionState
        if let snapshot = persister.loadSession() {
            session = SessionState(snapshot: snapshot, fallback: home)
        } else {
            session = SessionState(url: home)
        }
        // Launch-path argument still wins: restore the session, then point
        // the active pane at the requested folder (terminal `fe .` helper).
        if let launchURL = Self.launchFolderURL() {
            Task { await session.activePane.navigate(to: launchURL) }
        }
        self.session = session
        let autosaver = SessionAutosaver(session: session, persister: persister)
        autosaver.start()
        self.autosaver = autosaver

        // When launched from `swift run` (no bundle), become a regular
        // foreground app so the window appears and takes focus.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private static func launchFolderURL() -> URL? {
        guard let path = CommandLine.arguments.dropFirst().first else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    var body: some Scene {
        Window("FileExplorer", id: "main") {
            ZStack(alignment: .top) {
                NavigationSplitView {
                    SidebarView(session: session, volumesModel: volumesModel)
                        .navigationSplitViewColumnWidth(min: 160, ideal: 200)
                } detail: {
                    TabContentView(session: session, renameModel: renameModel,
                                   batchRenameModel: batchRenameModel, settings: settings)
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
                    let pane = renameModel.pane ?? session.activePane
                    Task { await pane.renameSelected(url, to: newName) }
                }
            }
            .sheet(isPresented: Binding(
                get: { batchRenameModel.isPresented },
                set: { if !$0 { batchRenameModel.dismiss() } })) {
                BatchRenameSheet(model: batchRenameModel) { targets, rules in
                    let pane = batchRenameModel.pane ?? session.activePane
                    Task { await pane.batchRename(targets, rules: rules) }
                }
            }
        }
        .commands {
            GetInfoCommands()
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    PasteboardOps.forwardToFieldEditor(#selector(NSText.cut(_:)))
                }
                .keyboardShortcut("x", modifiers: .command)
                Button("Copy") {
                    if PasteboardOps.textEditingIsActive {
                        PasteboardOps.forwardToFieldEditor(#selector(NSText.copy(_:)))
                    } else {
                        // Empty selection is a no-op — never wipe whatever
                        // the user already has on the clipboard.
                        let targets = Array(session.activePane.selection)
                        guard !targets.isEmpty else { return }
                        PasteboardOps.copyToPasteboard(targets)
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Paste") {
                    if PasteboardOps.textEditingIsActive {
                        PasteboardOps.forwardToFieldEditor(#selector(NSText.paste(_:)))
                    } else {
                        let urls = PasteboardOps.readFileURLs()
                        guard !urls.isEmpty else { return }
                        Task { await session.activePane.pasteCopy(urls) }
                    }
                }
                .keyboardShortcut("v", modifiers: .command)
                Button("Move Item Here") {
                    let urls = PasteboardOps.readFileURLs()
                    guard !urls.isEmpty else { return }
                    let pane = session.activePane
                    Task { await pane.moveSelected(urls, into: pane.currentURL) }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                Button("Select All") {
                    if PasteboardOps.textEditingIsActive {
                        PasteboardOps.forwardToFieldEditor(
                            #selector(NSText.selectAll(_:)))
                    } else {
                        session.activePane.selection =
                            Set(session.activePane.visibleEntries.map(\.url))
                    }
                }
                .keyboardShortcut("a", modifiers: .command)
            }
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
                Button("New File") {
                    Task { await session.activePane.createNewFile() }
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Duplicate") {
                    let targets = Array(session.activePane.selection)
                    guard !targets.isEmpty else { return }
                    Task { await session.activePane.duplicateSelected(targets) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session.activePane.selection.isEmpty)
                Button("Rename…") {
                    if let url = session.activePane.selection.first,
                       session.activePane.selection.count == 1 {
                        renameModel.present(for: url, in: session.activePane)
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
                Button("Close Tab") {
                    if session.tabs.count == 1 {
                        NSApp.mainWindow?.performClose(nil)
                    } else {
                        session.closeTab(at: session.activeTabIndex)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
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
                    set: { session.activePane.showHidden = $0 }))
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
        Window("Info", id: "info") {
            GetInfoView(session: session, model: infoModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.trailing)
    }
}

/// ⌘I lives in its own Commands type because @Environment(\.openWindow)
/// is available to Commands conformances but not to the App struct itself.
struct GetInfoCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Get Info") { openWindow(id: "info") }
                .keyboardShortcut("i", modifiers: .command)
        }
    }
}
