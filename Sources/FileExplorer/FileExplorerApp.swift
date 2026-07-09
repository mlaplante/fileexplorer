import SwiftUI
import FileExplorerCore

@main
struct FileExplorerApp: App {
    private let session: SessionState
    private let autosaver: SessionAutosaver
    private let palette = PaletteModel()
    private let renameModel = RenameSheetModel()
    private let batchRenameModel = BatchRenameModel()
    private let usageModel = UsageSheetModel()
    private let duplicatesModel = DuplicatesSheetModel()
    private let syncPreviewModel = SyncPreviewModel()
    private let archiveBrowser = ArchiveBrowserModel()
    private let archiveSheetModel = ArchiveBrowserSheetModel()
    private let conflictResolutionModel = ConflictResolutionModel()
    private let operationQueue = OperationQueueModel()
    private let workspaceProfileModel = WorkspaceProfileModel()
    private let connectServerModel = ConnectServerModel()
    private let locationsModel = LocationsModel()
    private let settings: SettingsModel
    private let trashRegistry: TrashRegistryModel
    private let infoModel = GetInfoModel()
    private let updateModel = UpdateModel()
    private let shortcutRecorder = ShortcutRecorderModel()
    private let scriptRunner = ScriptRunner()
    private let scriptsModel = ScriptsModel()

    init() {
        let persister = SessionPersister(
            directory: SessionPersister.defaultDirectory)
        let settings = SettingsModel(persister: persister)
        self.settings = settings
        self.trashRegistry = TrashRegistryModel(directory: persister.directory)
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
        archiveBrowser.willRemoveTempRoot = { root in
            QuickLookController.shared.dismissIfShowing(under: root)
        }

        // When launched from `swift run` (no bundle), become a regular
        // foreground app so the window appears and takes focus.
        // Locals, not properties: an escaping closure in a struct's init
        // can't capture mutating self.
        let updateModel = self.updateModel
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            updateModel.checkIfDue(settings: settings)
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
                    SidebarView(session: session, locationsModel: locationsModel,
                                settings: settings)
                        .navigationSplitViewColumnWidth(min: 160, ideal: 200)
                } detail: {
                    TabContentView(session: session, renameModel: renameModel,
                                   batchRenameModel: batchRenameModel,
                                   usageModel: usageModel,
                                   duplicatesModel: duplicatesModel,
                                   syncPreview: syncPreviewModel, settings: settings,
                                   trashRegistry: trashRegistry,
                                   conflictResolution: conflictResolutionModel,
                                   operationQueue: operationQueue,
                                   scriptRunner: scriptRunner,
                                   scriptsModel: scriptsModel,
                                   archiveBrowser: archiveBrowser)
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
                                                   session: session,
                                                   settings: settings,
                                                   usageModel: usageModel,
                                                   duplicatesModel: duplicatesModel,
                                                   scriptRunner: scriptRunner,
                                                   scriptsModel: scriptsModel,
                                                   archiveBrowser: archiveBrowser)
                    }
                    .padding(.top, 60)
                }

                if let version = updateModel.availableVersion {
                    HStack(spacing: 8) {
                        Text("FileExplorer \(version) is available.")
                        Button("View Release") { updateModel.openReleasePage() }
                        Button("Dismiss") { updateModel.dismiss() }
                    }
                    .font(.callout)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        OperationQueueOverlay(model: operationQueue)
                    }
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
                    let metadata = batchRenameModel.metadata
                    Task { await pane.batchRename(targets, rules: rules,
                                                  metadata: metadata) }
                }
            }
            .sheet(isPresented: Binding(
                get: { syncPreviewModel.isPresented },
                set: { if !$0 { syncPreviewModel.dismiss() } })) {
                SyncPreviewSheet(model: syncPreviewModel)
            }
            .sheet(isPresented: Binding(
                get: { archiveBrowser.isPresented },
                set: { if !$0 {
                    archiveBrowser.close()
                    archiveSheetModel.reset()
                } })) {
                ArchiveBrowserSheet(browser: archiveBrowser,
                                    sheet: archiveSheetModel) { archive in
                    Task { await session.activePane.extractSelected([archive]) }
                }
            }
            .sheet(isPresented: Binding(
                get: { usageModel.isPresented },
                set: { if !$0 { usageModel.dismiss() } })) {
                UsageSheet(model: usageModel)
            }
            .sheet(isPresented: Binding(
                get: { duplicatesModel.isPresented },
                set: { if !$0 { duplicatesModel.dismiss() } })) {
                DuplicatesSheet(model: duplicatesModel)
            }
            .sheet(isPresented: Binding(
                get: { conflictResolutionModel.isPresented },
                set: { if !$0 { conflictResolutionModel.dismiss() } })) {
                ConflictResolutionSheet(model: conflictResolutionModel)
            }
            .sheet(isPresented: Binding(
                get: { workspaceProfileModel.isPresented },
                set: { if !$0 { workspaceProfileModel.dismiss() } })) {
                WorkspaceProfileSheet(model: workspaceProfileModel) { name in
                    settings.saveWorkspaceProfile(name: name,
                                                  snapshot: session.snapshot())
                }
            }
            .sheet(isPresented: Binding(
                get: { connectServerModel.isPresented },
                set: { if !$0 { connectServerModel.dismiss() } })) {
                ConnectServerSheet(model: connectServerModel) { url in
                    NSWorkspace.shared.open(url)
                }
            }
            .alert(item: Binding(
                get: { scriptRunner.pendingAlert },
                set: { if $0 == nil { scriptRunner.pendingAlert = nil } })) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message),
                      dismissButton: .default(Text("OK")))
            }
            .alert("Archive Error", isPresented: Binding(
                get: { archiveBrowser.errorMessage != nil && !archiveBrowser.isPresented },
                set: { if !$0 { archiveBrowser.clearError() } })) {
                Button("OK") { archiveBrowser.clearError() }
            } message: {
                Text(archiveBrowser.errorMessage ?? "")
            }
        }
        .commands {
            GetInfoCommands(settings: settings)
            // Grouped so the top-level CommandsBuilder stays within the
            // 10-argument buildBlock cap of older SDKs (CI's Xcode rejects
            // an 11th entry with "extra argument in call").
            Group {
                CommandMenu("Network") {
                    Button("Connect to Server…") {
                        connectServerModel.present()
                    }
                    .keyboardShortcut("k", modifiers: .command)
                }
                CommandMenu("Workspace") {
                    Button("Save Workspace…") {
                        let formatter = DateFormatter()
                        formatter.dateStyle = .short
                        formatter.timeStyle = .short
                        workspaceProfileModel.present(
                            defaultName: "Workspace \(formatter.string(from: Date()))")
                    }
                    if !settings.settings.workspaceProfiles.isEmpty {
                        Divider()
                        ForEach(settings.settings.workspaceProfiles) { profile in
                            Button("Restore \(profile.name)") {
                                session.restoreWorkspace(
                                    profile,
                                    fallback: FileManager.default.homeDirectoryForCurrentUser)
                            }
                        }
                        Divider()
                        ForEach(settings.settings.workspaceProfiles) { profile in
                            Button("Delete \(profile.name)") {
                                settings.deleteWorkspaceProfile(name: profile.name)
                            }
                        }
                    }
                }
                CommandMenu("Smart Folders") {
                    Button("Save Current Filter as Smart Folder…") {
                        let pane = session.activePane
                        pane.saveSmartFolderNameDraft = pane.currentURL.lastPathComponent
                        pane.showsSaveSmartFolderPopover = true
                    }
                    .disabled(!session.activePane.filter.isActive)
                    if !settings.settings.smartFolders.isEmpty {
                        Divider()
                        ForEach(settings.settings.smartFolders) { smartFolder in
                            Button("Open \(smartFolder.name)") {
                                Task {
                                    await session.activePane.applySmartFolder(smartFolder)
                                }
                            }
                        }
                        Divider()
                        ForEach(settings.settings.smartFolders) { smartFolder in
                            Button("Delete \(smartFolder.name)") {
                                settings.deleteSmartFolder(name: smartFolder.name)
                            }
                        }
                    }
                }
                CommandMenu("Tools") {
                    Button("Analyze Disk Usage…") {
                        usageModel.present(root: session.activePane.currentURL,
                                           pane: session.activePane)
                    }
                    Button("Find Duplicates…") {
                        duplicatesModel.present(root: session.activePane.currentURL,
                                                pane: session.activePane)
                    }
                    Divider()
                    Button("Browse Archive…") {
                        if let archive = WorkflowActions.singleSelectedArchive(in: session.activePane) {
                            archiveBrowser.open(archive: archive)
                        }
                    }
                    .disabled(WorkflowActions.singleSelectedArchive(in: session.activePane) == nil)
                }
            }
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
                    let plan = OperationConflictPlanner.plan(
                        operation: .move,
                        sources: urls,
                        into: pane.currentURL)
                    if plan.hasConflicts {
                        conflictResolutionModel.present(plan: plan,
                                                        title: "Move",
                                                        pane: pane)
                    } else {
                        Task {
                            await pane.executeResolvedPlan(plan,
                                                           actionName: "Move")
                        }
                    }
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
                Button("Open in Terminal") {
                    WorkflowActions.openInTerminal(pane: session.activePane,
                                                   settings: settings,
                                                   scriptRunner: scriptRunner)
                }
                .keyboardShortcut(settings.chord(for: .openInTerminal).keyboardShortcut)
                .disabled(settings.settings.terminalAppPath == nil)
                Button("Open in Editor") {
                    WorkflowActions.openInEditor(pane: session.activePane,
                                                 settings: settings,
                                                 scriptRunner: scriptRunner)
                }
                .keyboardShortcut(settings.chord(for: .openInEditor).keyboardShortcut)
                .disabled(settings.settings.editorAppPath == nil)
                Menu("Scripts") {
                    if scriptsModel.scripts.isEmpty {
                        Text("No scripts installed")
                    } else {
                        ForEach(scriptsModel.scripts, id: \.self) { script in
                            Button(script.lastPathComponent) {
                                WorkflowActions.runScript(script,
                                                          pane: session.activePane,
                                                          scriptRunner: scriptRunner)
                            }
                        }
                    }
                    Divider()
                    Button("Open Scripts Folder") {
                        WorkflowActions.openScriptsFolder(
                            in: session.activePane,
                            scriptsModel: scriptsModel,
                            scriptRunner: scriptRunner)
                    }
                }
                Divider()
                Button("New Folder") {
                    Task { await session.activePane.createNewFolder() }
                }
                .keyboardShortcut(settings.chord(for: .newFolder).keyboardShortcut)
                Button("New File") {
                    Task { await session.activePane.createNewFile() }
                }
                .keyboardShortcut(settings.chord(for: .newFile).keyboardShortcut)
                Button("Duplicate") {
                    let targets = Array(session.activePane.selection)
                    guard !targets.isEmpty else { return }
                    Task { await session.activePane.duplicateSelected(targets) }
                }
                .keyboardShortcut(settings.chord(for: .duplicate).keyboardShortcut)
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
                .keyboardShortcut(settings.chord(for: .goHome).keyboardShortcut)
                Divider()
                Button("Go to Folder…") {
                    PaletteCoordinator.openFolders(palette, session: session)
                }
                .keyboardShortcut(settings.chord(for: .gotoFolder).keyboardShortcut)
                Button("Find File…") {
                    PaletteCoordinator.openFiles(palette, session: session)
                }
                .keyboardShortcut(settings.chord(for: .findFile).keyboardShortcut)
                Button("Search File Contents…") {
                    PaletteCoordinator.openContents(palette, session: session)
                }
                .keyboardShortcut(settings.chord(for: .contentSearch).keyboardShortcut)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Hidden Files", isOn: Binding(
                    get: { session.activePane.showHidden },
                    set: { session.activePane.showHidden = $0 }))
                    .keyboardShortcut(settings.chord(for: .toggleHidden).keyboardShortcut)
                Button("Toggle Dual Pane") { session.activeTab.toggleDual() }
                    .keyboardShortcut(settings.chord(for: .dualPane).keyboardShortcut)
                Button("Compare Panes") {
                    Task { await session.activeTab.runCompare() }
                }
                .keyboardShortcut(settings.chord(for: .comparePanes).keyboardShortcut)
                .disabled(!session.activeTab.isDual)
                Picker("View", selection: Binding(
                    get: { session.activePane.viewMode },
                    set: { session.activePane.viewMode = $0 })) {
                    Text("as List").tag(PaneState.ViewMode.list)
                        .keyboardShortcut("1", modifiers: [.command, .option])
                    Text("as Icons").tag(PaneState.ViewMode.icons)
                        .keyboardShortcut("2", modifiers: [.command, .option])
                    Text("as Columns").tag(PaneState.ViewMode.columns)
                        .keyboardShortcut("3", modifiers: [.command, .option])
                }
                .pickerStyle(.inline)
                Menu("Sort By") {
                    ForEach(SortMenu.Axis.allCases, id: \.self) { axis in
                        Toggle(axis.title, isOn: Binding(
                            get: {
                                SortMenu.axis(of: session.activePane.sortOrder) == axis
                            },
                            set: { isOn in
                                guard isOn else { return }
                                let pane = session.activePane
                                pane.sortOrder = SortMenu.toggledOrder(
                                    current: pane.sortOrder, selecting: axis)
                            }))
                    }
                }
                Menu("Group By") {
                    ForEach(Grouper.Axis.allCases, id: \.self) { axis in
                        Toggle(axis.title, isOn: Binding(
                            get: { session.activePane.groupBy == axis },
                            set: { isOn in
                                guard isOn else { return }
                                session.activePane.groupBy = axis
                            }))
                    }
                }
                Button("Quick Look") {
                    QuickLookController.shared.toggle(for: session.activePane)
                }
                .keyboardShortcut(settings.chord(for: .quickLook).keyboardShortcut)
                Button("Preview Pane") {
                    session.activeTab.showsPreviewPane.toggle()
                }
                .keyboardShortcut(settings.chord(for: .previewPane).keyboardShortcut)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Command Palette…") {
                    PaletteCoordinator.openCommands(palette, session: session,
                                                    settings: settings,
                                                    usageModel: usageModel,
                                                    duplicatesModel: duplicatesModel,
                                                    scriptRunner: scriptRunner,
                                                    scriptsModel: scriptsModel,
                                                    archiveBrowser: archiveBrowser)
                }
                .keyboardShortcut(settings.chord(for: .commandPalette).keyboardShortcut)
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
        Settings {
            SettingsRootView(settings: settings, updateModel: updateModel,
                             recorder: shortcutRecorder)
        }
    }

}

/// ⌘I lives in its own Commands type because @Environment(\.openWindow)
/// is available to Commands conformances but not to the App struct itself.
struct GetInfoCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var settings: SettingsModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Get Info") { openWindow(id: "info") }
                .keyboardShortcut(settings.chord(for: .getInfo).keyboardShortcut)
        }
    }
}
